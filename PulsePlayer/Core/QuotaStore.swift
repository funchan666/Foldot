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

enum PracticeWatchAccess: String {
    case replay = "Replay without using another view."
    case plus = "This video is included with Plus."
    case unlimited = "Unlimited viewing until the next reset."
    case oneView = "Playing this video uses one view."
    case pending = "This video is already opening."
    case exhausted = "No views left for new videos today."
    case checking = "Checking your viewing allowance…"
    case unavailable = "Your viewing allowance is unavailable."

    var newReservationCost: Int? {
        switch self {
        case .plus, .unlimited: 0
        case .oneView: 1
        default: nil
        }
    }

    var canOpen: Bool { self == .replay || self == .pending || newReservationCost != nil }
}

struct DailyUsage: Codable, Equatable {
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

    func completedAds(_ kind: AllowanceKind) -> Int {
        kind == .watch ? completedRewardIDs.count : completedDownloadRewardIDs?.count ?? 0
    }

    func totalAllowance(for kind: AllowanceKind) -> Int {
        switch kind {
        case .watch: (watchBaseForDay ?? 0) + extraWatches
        case .download: (downloadBaseForDay ?? 0) + (extraDownloads ?? 0)
        }
    }

    func remaining(_ kind: AllowanceKind) -> Int {
        let spent = kind == .watch ? (watchSpend ?? watched.count) + reservedWatchSpend : downloadsUsed ?? 0
        return max(0, totalAllowance(for: kind) - spent)
    }

    func access(to videoID: String, premium: Bool) -> PracticeWatchAccess {
        if watched.contains(videoID) { return .replay }
        if pendingWatches?[videoID] != nil { return .pending }
        if premium { return .plus }
        if completedAds(.watch) >= QuotaStore.unlimitedRewardCount { return .unlimited }
        return remaining(.watch) > 0 ? .oneView : .exhausted
    }

    func allowsDownload(_ id: String, premium: Bool) -> Bool {
        premium || completedAds(.download) >= QuotaStore.unlimitedRewardCount
            || downloaded?.contains(id) == true || remaining(.download) > 0
    }
}

@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var usage: DailyUsage?
    @Published var error: String?
    private var userID: String?
    private var policy: CommerceConfiguration?
    private var remote: QuotaConfiguration?
    private var storageOK = true
    private var needsUsageSave = false
    private var watchAttempts: [String: Set<UUID>] = [:]
    var unlimited: Bool { isUnlimited(.watch) }
    var downloadsUnlimited: Bool { isUnlimited(.download) }
    var watchesLeft: Int { remaining(.watch) }
    var downloadsLeft: Int { remaining(.download) }
    private var downloadReward: Int { max(0, remote?.downloadRewardCount ?? policy?.favoriteReward ?? 0) }
    nonisolated static let unlimitedRewardCount = 4
    func isUnlimited(_ kind: AllowanceKind) -> Bool { completedAds(kind) >= Self.unlimitedRewardCount }
    func completedAds(_ kind: AllowanceKind) -> Int { usage(on: boundary())?.completedAds(kind) ?? 0 }
    func remaining(_ kind: AllowanceKind) -> Int { usage(on: boundary())?.remaining(kind) ?? 0 }
    func totalAllowance(for kind: AllowanceKind) -> Int { usage(on: boundary())?.totalAllowance(for: kind) ?? 0 }
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
            if !storageOK {
                storageOK = true
                needsUsageSave = true
            }
            resetIfNeeded()
            updateDailyBases()
            return
        }
        self.userID = userID
        watchAttempts.removeAll()
        usage = nil
        storageOK = true
        needsUsageSave = false
        error = nil
        guard userID != nil else { return }
        do {
            if let data = try SecureStorage.read(key) {
                var saved = try JSONDecoder().decode(DailyUsage.self, from: data)
                // A load cannot still be in progress after restoring an account from disk.
                let abandonedWatches = saved.pendingWatches?.isEmpty == false
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
                } else if abandonedWatches { try commit(saved) }
                else { usage = saved }
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
    func resetIfNeeded() { resetIfNeeded(at: boundary()) }

    private func resetIfNeeded(at day: Date) {
        guard storageOK, userID != nil, let usage else { return }
        if day > usage.day {
            do {
                try commit(freshDay(startingAt: day, downloaded: usage.downloaded ?? []))
                watchAttempts.removeAll()
            }
            catch { storageOK = false; self.error = error.localizedDescription }
        }
    }

    // Project tomorrow's ledger for a visible row that stays onscreen through 05:00 UTC.
    // Only a business action or the foreground reset persists the new day.
    private func usage(on day: Date) -> DailyUsage? {
        guard let usage else { return nil }
        if day > usage.day { return freshDay(startingAt: day, downloaded: usage.downloaded ?? []) }
        return usage
    }

    func watchAccess(to id: String, premium: Bool, owner: String?, at now: Date = .now) -> PracticeWatchAccess {
        guard let owner, owner == userID else { return .checking }
        guard storageOK else { return .unavailable }
        guard let day = usage(on: Self.boundary(at: now)) else { return .checking }
        return day.access(to: id, premium: premium)
    }

    func mayWatch(_ id: String, premium: Bool) -> Bool {
        watchAccess(to: id, premium: premium, owner: userID).canOpen
    }
    func recordWatch(_ id: String, premium: Bool, owner: String? = nil) -> Bool {
        guard let owner = owner ?? userID, let admission = reserveWatch(id, premium: premium, owner: owner) else { return false }
        if case .reserved(let reservation) = admission { settleWatch(reservation, played: true) }
        return true
    }
    func reserveWatch(_ id: String, premium: Bool, owner: String) -> WatchAdmission? {
        guard owner == userID else { return nil }
        let now = Date()
        resetIfNeeded(at: Self.boundary(at: now))
        let access = watchAccess(to: id, premium: premium, owner: owner, at: now)
        guard access.canOpen, var next = usage else { return nil }
        if access == .replay { return .alreadyWatched }
        if let cost = access.newReservationCost {
            if next.pendingWatches == nil { next.pendingWatches = [:] }
            next.pendingWatches?[id] = cost
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
            needsUsageSave = true
            applyUsage(next)
            self.error = error.localizedDescription
        }
    }
    func mayDownload(_ id: String, premium: Bool) -> Bool {
        guard storageOK, userID != nil, let day = usage(on: boundary()) else { return false }
        return day.allowsDownload(id, premium: premium)
    }
    // Called only after a complete, durable offline file exists. The lifetime ID set
    // also makes recovery after an interrupted index write and re-download idempotent.
    func recordDownload(_ id: String, owner: String, premium: Bool) throws {
        guard owner == userID else { throw PulsePlayerError.storage }
        resetIfNeeded()
        guard storageOK, var next = usage, next.allowsDownload(id, premium: premium) else { throw PulsePlayerError.storage }
        guard next.downloaded?.contains(id) != true else { return }
        next.downloaded = (next.downloaded ?? []).union([id])
        if !premium && next.completedAds(.download) < Self.unlimitedRewardCount {
            next.downloadsUsed = (next.downloadsUsed ?? 0) + 1
        }
        try commit(next)
    }
    func canRequestReward(for kind: AllowanceKind, premium: Bool) -> Bool {
        guard !premium, storageOK, userID != nil, policy != nil, let day = usage(on: boundary()) else { return false }
        return day.completedAds(kind) < Self.unlimitedRewardCount && day.remaining(kind) == 0
    }
    func reward(_ id: UUID, owner: String, kind: AllowanceKind) throws {
        guard owner == userID, storageOK else { throw PulsePlayerError.storage }
        resetIfNeeded()
        guard storageOK else { throw PulsePlayerError.storage }
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
        guard storageOK else { throw PulsePlayerError.storage }
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
    private func freshDay(startingAt day: Date? = nil, downloaded: Set<String> = []) -> DailyUsage {
        var value = DailyUsage(day: day ?? boundary())
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
        guard needsUsageSave || value != usage else { return }
        try SecureStorage.write(JSONEncoder().encode(value), key: key)
        needsUsageSave = false
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
