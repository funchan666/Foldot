import Foundation
import Combine

enum AllowanceKind: String, Codable, CaseIterable, Identifiable {
    case watch, download
    var id: String { rawValue }
}

struct WatchReservation {
    let owner: String
    let day: Date
    let videoID: String
    let attemptID: UUID
}

enum WatchAdmission {
    case alreadyWatched
    case reserved(WatchReservation)
}

struct DailyUsage: Codable {
    var day: Date
    var watched: Set<String> = []
    // Legacy keys remain decodable. Favorites no longer consume any allowance.
    var favoritesUsed = 0
    var completedRewardIDs: Set<UUID> = []
    var extraWatches = 0
    var extraFavorites = 0
    var luckyRewardIDs: Set<UUID>?
    var lastLuckyReward: Date?
    var schemaVersion: Int?
    var watchSpend: Int?
    var pendingWatches: [String: Int]?
    var downloaded: Set<String>?
    var downloadsUsed: Int?
    var completedDownloadRewardIDs: Set<UUID>?
    var extraDownloads: Int?
    // Today's admitted base is independent of live per-ad reward configuration.
    var watchBaseForDay: Int?
    var downloadBaseForDay: Int?
    var nextWatchBase: Int?
    var nextDownloadBase: Int?

    var reservedWatchSpend: Int { pendingWatches?.values.reduce(0, +) ?? 0 }
}

@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var usage: DailyUsage?
    @Published var error: String?
    private var userID: String?
    private var policy: CommerceConfiguration?
    private var remote: QuotaConfiguration?
    private var storageOK = true
    private var watchAttempts: [String: Set<UUID>] = [:]
    var unlimited: Bool { isUnlimited(.watch) }
    var downloadsUnlimited: Bool { isUnlimited(.download) }
    var watchesLeft: Int {
        let spent = usage?.watchSpend ?? usage?.watched.count ?? 0
        return max(0, totalAllowance(for: .watch) - spent - (usage?.reservedWatchSpend ?? 0))
    }
    var downloadsLeft: Int { max(0, totalAllowance(for: .download) - (usage?.downloadsUsed ?? 0)) }
    private var downloadReward: Int { max(0, remote?.downloadRewardCount ?? policy?.favoriteReward ?? 0) }
    func isUnlimited(_ kind: AllowanceKind) -> Bool { completedAds(kind) >= 4 }
    func completedAds(_ kind: AllowanceKind) -> Int {
        kind == .watch ? (usage?.completedRewardIDs.count ?? 0) : (usage?.completedDownloadRewardIDs?.count ?? 0)
    }
    func remaining(_ kind: AllowanceKind) -> Int { kind == .watch ? watchesLeft : downloadsLeft }
    func totalAllowance(for kind: AllowanceKind) -> Int {
        switch kind {
        case .watch: (usage?.watchBaseForDay ?? 0) + (usage?.extraWatches ?? 0)
        case .download: (usage?.downloadBaseForDay ?? 0) + (usage?.extraDownloads ?? 0)
        }
    }
    func rewardCount(for kind: AllowanceKind) -> Int {
        kind == .watch ? nextWatchReward : downloadReward
    }
    private var nextWatchReward: Int {
        let index = min(completedAds(.watch), 2)
        let values = [remote?.firstAdRewardWatchCount, remote?.secondAdRewardWatchCount, remote?.thirdAdRewardWatchCount]
        return max(0, values[index] ?? policy?.watchRewards[safe: index] ?? 0)
    }
    func configure(userID: String?, policy: CommerceConfiguration?, remote: QuotaConfiguration?) {
        objectWillChange.send()
        self.policy = policy
        self.remote = remote
        guard self.userID != userID || usage == nil else {
            resetIfNeeded()
            updateDailyBases()
            return
        }
        self.userID = userID
        watchAttempts.removeAll()
        usage = nil
        storageOK = true
        error = nil
        guard userID != nil else { return }
        do {
            if let data = try SecureStorage.read(key) {
                var saved = try JSONDecoder().decode(DailyUsage.self, from: data)
                // A load cannot still be in progress after restoring an account from disk.
                saved.pendingWatches = nil
                if saved.schemaVersion != 2 {
                    // Preserve existing viewing spend/rewards during the one-time UTC migration.
                    // The old favorite ledger never represented a downloaded file.
                    saved.day = boundary()
                    saved.schemaVersion = 2
                    saved.watchSpend = saved.watched.count
                    saved.downloaded = []
                    saved.downloadsUsed = 0
                    saved.completedDownloadRewardIDs = []
                    saved.extraDownloads = 0
                    try commit(saved)
                } else { usage = saved }
            } else { try commit(freshDay()) }
            resetIfNeeded()
            updateDailyBases()
        } catch { storageOK = false; self.error = "Daily allowance could not be read. Please try again later." }
    }
    private func updateDailyBases() {
        guard storageOK, var next = usage else { return }
        // A startup refresh may temporarily have no remote configuration. Keep the
        // last persisted next-day values until a real configuration arrives.
        let watchBase = max(0, remote?.dailyWatchLimit ?? (remote == nil ? next.nextWatchBase : nil) ?? policy?.dailyWatchLimit ?? 0)
        let downloadBase = max(0, remote?.dailyDownloadLimit ?? (remote == nil ? next.nextDownloadBase : nil) ?? policy?.dailyFavoriteLimit ?? 0)
        next.nextWatchBase = watchBase
        next.nextDownloadBase = downloadBase
        if next.watchBaseForDay == nil || ((next.watchSpend ?? next.watched.count) == 0 && next.reservedWatchSpend == 0) {
            next.watchBaseForDay = watchBase
        }
        if next.downloadBaseForDay == nil || (next.downloadsUsed ?? 0) == 0 { next.downloadBaseForDay = downloadBase }
        do { try commit(next) }
        catch { storageOK = false; self.error = "Daily allowance could not be read. Please try again later." }
    }
    func resetIfNeeded() {
        guard storageOK, userID != nil, let usage else { return }
        if boundary() > usage.day {
            do {
                try commit(freshDay(downloaded: usage.downloaded ?? []))
                watchAttempts.removeAll()
            }
            catch { storageOK = false; self.error = error.localizedDescription }
        }
    }
    func mayWatch(_ id: String, premium: Bool) -> Bool {
        resetIfNeeded()
        return premium || (storageOK && userID != nil && (unlimited || usage?.watched.contains(id) == true
            || usage?.pendingWatches?[id] != nil || watchesLeft > 0))
    }
    func recordWatch(_ id: String, premium: Bool, owner: String? = nil) -> Bool {
        guard let owner = owner ?? userID, let admission = reserveWatch(id, premium: premium, owner: owner) else { return false }
        if case .reserved(let reservation) = admission { settleWatch(reservation, played: true) }
        return true
    }
    func reserveWatch(_ id: String, premium: Bool, owner: String) -> WatchAdmission? {
        guard owner == userID, mayWatch(id, premium: premium), var next = usage else { return nil }
        if next.watched.contains(id) { return .alreadyWatched }
        if next.pendingWatches?[id] == nil {
            var pending = next.pendingWatches ?? [:]
            pending[id] = premium || unlimited ? 0 : 1
            next.pendingWatches = pending
            do { try commit(next) }
            catch { self.error = error.localizedDescription; return nil }
        }
        let attemptID = UUID()
        watchAttempts[id, default: []].insert(attemptID)
        return .reserved(WatchReservation(owner: owner, day: next.day, videoID: id, attemptID: attemptID))
    }
    func settleWatch(_ reservation: WatchReservation, played: Bool) {
        let id = reservation.videoID
        guard reservation.owner == userID, var next = usage, next.day == reservation.day,
              let cost = next.pendingWatches?[id], var attempts = watchAttempts[id],
              attempts.remove(reservation.attemptID) != nil else { return }
        if !played, !attempts.isEmpty {
            watchAttempts[id] = attempts
            return
        }
        watchAttempts[id] = nil
        next.pendingWatches?[id] = nil
        if played {
            next.watchSpend = (next.watchSpend ?? next.watched.count) + cost
            next.watched.insert(id)
        }
        do { try commit(next) }
        catch {
            // Keep the known playback result. The next write saves it with the rest of the ledger.
            applyUsage(next)
            self.error = error.localizedDescription
        }
    }
    func mayDownload(_ id: String, premium: Bool) -> Bool {
        resetIfNeeded()
        return storageOK && userID != nil && (premium || downloadsUnlimited || usage?.downloaded?.contains(id) == true || downloadsLeft > 0)
    }
    // Called only after a complete, durable offline file exists. The lifetime ID set
    // also makes recovery after an interrupted index write and re-download idempotent.
    func recordDownload(_ id: String, owner: String, premium: Bool) throws {
        guard owner == userID, mayDownload(id, premium: premium), var next = usage else { throw PulsePlayerError.storage }
        guard next.downloaded?.contains(id) != true else { return }
        next.downloaded = (next.downloaded ?? []).union([id])
        if !premium && !downloadsUnlimited { next.downloadsUsed = (next.downloadsUsed ?? 0) + 1 }
        try commit(next)
    }
    func canRequestReward(for kind: AllowanceKind, premium: Bool) -> Bool {
        return !premium && storageOK && userID != nil && policy != nil && !isUnlimited(kind) && remaining(kind) == 0
    }
    func reward(_ id: UUID, owner: String, kind: AllowanceKind) throws {
        guard owner == userID, storageOK else { throw PulsePlayerError.storage }
        resetIfNeeded()
        guard var next = usage, policy != nil else { throw PulsePlayerError.configuration }
        if kind == .watch {
            guard !next.completedRewardIDs.contains(id) else { return }
            next.extraWatches += rewardCount(for: kind)
            next.completedRewardIDs.insert(id)
        } else {
            guard next.completedDownloadRewardIDs?.contains(id) != true else { return }
            next.extraDownloads = (next.extraDownloads ?? 0) + rewardCount(for: kind)
            next.completedDownloadRewardIDs = (next.completedDownloadRewardIDs ?? []).union([id])
        }
        try commit(next)
    }
    func rewardNoFill(_ id: UUID, owner: String, kind: AllowanceKind) throws -> String? {
        guard owner == userID, storageOK else { throw PulsePlayerError.storage }
        resetIfNeeded()
        guard var next = usage, policy != nil else { throw PulsePlayerError.configuration }
        guard !isUnlimited(kind), remaining(kind) == 0, next.luckyRewardIDs?.contains(id) != true else { return nil }
        let count = rewardCount(for: kind)
        guard count > 0 else { return nil }
        // No cooldown; no-fill gifts never advance either completed-ad counter.
        // At stage four nextWatchReward remains the third-stage amount.
        if kind == .watch { next.extraWatches += count }
        else { next.extraDownloads = (next.extraDownloads ?? 0) + count }
        next.luckyRewardIDs = (next.luckyRewardIDs ?? []).union([id])
        try commit(next)
        return kind == .watch ? "More views added. Your ad progress stays the same." : "More downloads added. Your ad progress stays the same."
    }
    private var key: String { "quota.\(userID ?? "none")" }
    private func freshDay(downloaded: Set<String> = []) -> DailyUsage {
        var value = DailyUsage(day: boundary())
        value.schemaVersion = 2
        value.watchSpend = 0
        value.downloaded = downloaded
        value.downloadsUsed = 0
        value.completedDownloadRewardIDs = []
        value.extraDownloads = 0
        value.watchBaseForDay = max(0, remote?.dailyWatchLimit ?? usage?.nextWatchBase ?? policy?.dailyWatchLimit ?? 0)
        value.downloadBaseForDay = max(0, remote?.dailyDownloadLimit ?? usage?.nextDownloadBase ?? policy?.dailyFavoriteLimit ?? 0)
        value.nextWatchBase = value.watchBaseForDay
        value.nextDownloadBase = value.downloadBaseForDay
        return value
    }
    static func nextReset(after now: Date = Date()) -> Date {
        boundary(at: now).addingTimeInterval(86_400)
    }
    private func boundary() -> Date { Self.boundary(at: Date()) }
    private static func boundary(at now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let five = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: now)!
        return now >= five ? five : calendar.date(byAdding: .day, value: -1, to: five)!
    }
    private func commit(_ value: DailyUsage) throws {
        try SecureStorage.write(JSONEncoder().encode(value), key: key)
        applyUsage(value)
        if storageOK, error != nil { error = nil }
    }
    private func applyUsage(_ value: DailyUsage) {
        usage = value
    }
}
extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
