import Foundation
import Combine

enum FoldPracticeID: Codable, Hashable {
    case movie(UUID)
    case lesson(environment: String, owner: String, clipID: String)
}

struct FoldPracticeStep: Codable, Identifiable, Hashable {
    let id: UUID
    let start: Double
    let addedAt: Date
    var end: Double?
    var name: String?
    var lessonTitleKey: String?

    func displayName(language: AppLanguage = .current) -> String? {
        name?.nilIfBlank ?? lessonTitleKey.map { L10n.text($0, language: language) }
    }
}

struct FoldPracticeEntry: Codable, Identifiable, Hashable {
    let id: FoldPracticeID
    var clip: LessonClip
    var steps: [FoldPracticeStep]
    var selectedID: UUID
    var updatedAt: Date
    var finishedAt: Date?
    var duration: Double?
    var removedFromContinueWatching: Bool?

    var currentStepNumber: Int { (steps.firstIndex(where: { $0.id == selectedID }) ?? 0) + 1 }
    var currentStep: FoldPracticeStep? { steps.first { $0.id == selectedID } }
    var resumeSeconds: Double { currentStep?.start ?? 0 }

    func loopRange(for step: FoldPracticeStep, duration: Double) -> ClosedRange<Double>? {
        guard duration.isFinite, duration > 0 else { return nil }
        let next = steps.first { $0.start > step.start }?.start ?? duration
        let end = min(step.end ?? next, next, duration)
        return end - step.start >= FoldPracticeStore.minimumSpan ? step.start...end : nil
    }

    @MainActor func route(library: LibraryStore, offline: OfflineStore) -> PlayerRoute? {
        let source: LessonClip
        switch id {
        case .movie(let id):
            guard let movie = library.movies.first(where: { $0.id == id }) else { return nil }
            return .localMovies([movie], selected: movie, library: library)
        case .lesson(_, let owner, _):
            if !clip.playbackURL.isFileURL {
                source = clip
            } else if let cached = offline.cached(clip.id), owner == cached.owner {
                source = cached.clip
            } else {
                return nil
            }
        }
        return PlayerRoute(clips: [source], startID: source.id)
    }
}

@MainActor
final class FoldPracticeStore: ObservableObject {
    static let shared = FoldPracticeStore()
    nonisolated static let minimumSpan = 0.5
    @Published private(set) var error: String?
    @Published private var records: [FoldPracticeID: FoldPracticeEntry] = [:]
    private let file: URL
    private let environment: String
    private var loaded = false
    var needsLoadRetry: Bool { !loaded && error != nil }


    private init() {
        let config = PulsePlayerConfiguration.current
        environment = [config.apiBaseURL?.absoluteString ?? "", config.servicePackageName].joined(separator: "|")
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FoldotPractice", isDirectory: true)
        file = directory.appendingPathComponent("folds-v1.json")
        do { try read() } catch { self.error = "Your fold notes could not be opened. Try again." }
    }

    func identity(for clip: LessonClip, owner: String?) -> FoldPracticeID? {
        if let id = clip.localMovieID { return .movie(id) }
        guard let owner, !owner.isEmpty else { return nil }
        return .lesson(environment: environment, owner: owner, clipID: clip.id)
    }

    func entry(for id: FoldPracticeID?) -> FoldPracticeEntry? {
        id.flatMap { records[$0] }
    }

    func recent(owner: String?, library: LibraryStore, offline: OfflineStore) -> [FoldPracticeEntry] {
        records.values.compactMap { entry -> FoldPracticeEntry? in
            switch entry.id {
            case .movie(let id):
                guard let movie = library.movies.first(where: { $0.id == id }), !movie.isAudio,
                      FileManager.default.isReadableFile(atPath: library.url(for: movie).path) else { return nil }
                var updated = entry
                updated.clip.title = movie.displayFilename
                return updated
            case .lesson(let environment, let recordOwner, _):
                return environment == self.environment && recordOwner == owner ? entry : nil
            }
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func mark(_ clip: LessonClip, id: FoldPracticeID, seconds: Double, duration: Double) throws {
        try ensureReadable()
        guard seconds.isFinite, seconds >= 0, duration.isFinite, duration - seconds >= Self.minimumSpan else {
            throw PulsePlayerError.service("Move the playhead before the end of the video.")
        }
        var entry = records[id] ?? FoldPracticeEntry(id: id, clip: clip, steps: [], selectedID: UUID(), updatedAt: .now)
        guard !entry.steps.contains(where: { abs($0.start - seconds) < Self.minimumSpan }) else {
            throw PulsePlayerError.service("A fold is already marked here.")
        }
        let step = FoldPracticeStep(id: UUID(), start: seconds, addedAt: .now)
        entry.clip = clip
        entry.duration = duration
        entry.steps.append(step)
        entry.steps.sort { $0.start < $1.start }
        entry.selectedID = step.id
        entry.removedFromContinueWatching = nil
        entry.finishedAt = nil
        try commit(entry)
    }

    func select(_ step: FoldPracticeStep, in id: FoldPracticeID, reopen: Bool = true) throws {
        guard var entry = records[id], entry.steps.contains(where: { $0.id == step.id }) else { return }
        guard step.id != entry.selectedID || (reopen && entry.finishedAt != nil) else { return }
        entry.selectedID = step.id
        if reopen { entry.finishedAt = nil }
        try commit(entry)
    }

    func updateEnd(in id: FoldPracticeID, at seconds: Double, duration: Double) throws {
        guard var entry = records[id], let step = entry.currentStep,
              let index = entry.steps.firstIndex(where: { $0.id == step.id }) else { return }
        let limit = entry.steps.dropFirst(index + 1).first?.start ?? duration
        guard seconds.isFinite, duration.isFinite, seconds - step.start >= Self.minimumSpan,
              seconds <= min(limit, duration) + 0.002 else {
            throw PulsePlayerError.service("Place the playhead after this fold starts and before the next fold.")
        }
        entry.steps[index].end = min(seconds, limit, duration)
        entry.finishedAt = nil
        try commit(entry)
    }

    func renameCurrent(in id: FoldPracticeID, name: String) throws {
        guard var entry = records[id], let index = entry.steps.firstIndex(where: { $0.id == entry.selectedID }) else { return }
        entry.steps[index].name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)).nilIfBlank
        try commit(entry)
    }

    func undoLastMark(in id: FoldPracticeID) throws {
        guard let last = records[id]?.steps.max(by: { $0.addedAt < $1.addedAt }) else { return }
        try removeMark(last.id, in: id, reopen: true)
    }

    func removeMark(_ stepID: UUID, in id: FoldPracticeID, reopen: Bool = false) throws {
        guard var entry = records[id], let index = entry.steps.firstIndex(where: { $0.id == stepID }) else { return }
        entry.steps.remove(at: index)
        if entry.selectedID == stepID, !entry.steps.isEmpty {
            entry.selectedID = entry.steps[max(0, index - 1)].id
        }
        if reopen { entry.finishedAt = nil }
        try commit(entry)
    }

    func clearMarks(in id: FoldPracticeID) throws {
        guard var entry = records[id] else { return }
        entry.steps.removeAll()
        try commit(entry)
    }

    func setFinished(_ finished: Bool, in id: FoldPracticeID) throws {
        guard var entry = records[id], finished != (entry.finishedAt != nil) else { return }
        entry.finishedAt = finished ? .now : nil
        try commit(entry)
    }

    func removeFromContinueWatching(_ id: FoldPracticeID) throws {
        guard var entry = records[id] else { return }
        entry.removedFromContinueWatching = true
        try commit(entry, updateTimestamp: false)
    }

    func markOpened(_ id: FoldPracticeID) {
        guard var entry = records[id], entry.finishedAt == nil || entry.removedFromContinueWatching == true else { return }
        entry.removedFromContinueWatching = nil
        do { try commit(entry) } catch { self.error = error.localizedDescription }
    }

    func refreshSource(_ clip: LessonClip, in id: FoldPracticeID) {
        guard var entry = records[id], !clip.playbackURL.isFileURL, clip.id == entry.clip.id,
              clip.playbackURL != entry.clip.playbackURL else { return }
        entry.clip = clip
        do { try commit(entry) } catch { self.error = error.localizedDescription }
    }

    func follow(_ position: Double, in id: FoldPracticeID) {
        guard error == nil, let entry = records[id],
              let reached = entry.steps.last(where: { $0.start <= position + 1 / 600.0 }),
              reached.id != entry.selectedID else { return }
        do { try select(reached, in: id, reopen: false) } catch { self.error = error.localizedDescription }
    }

    func retryLoading() {
        guard !loaded else { return }
        do { try read() } catch { self.error = "Your fold notes could not be opened. Try again." }
    }

    private func ensureReadable() throws {
        guard !loaded else { return }
        do { try read() } catch { throw PulsePlayerError.service("Your fold notes could not be opened. Try again.") }
    }

    private func read() throws {
        do {
            let data = try Data(contentsOf: file)
            var saved = try JSONDecoder().decode([FoldPracticeID: FoldPracticeEntry].self, from: data)
            if saved.removeValue(forKey: .movie(LibraryStore.retiredSampleID)) != nil {
                try JSONEncoder().encode(saved).write(to: file, options: .atomic)
            }
            records = saved
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            records = [:]
        }
        loaded = true
        error = nil
    }

    private func commit(_ record: FoldPracticeEntry, updateTimestamp: Bool = true) throws {
        try ensureReadable()
        var updated = record
        if updateTimestamp { updated.updatedAt = .now }
        var next = records
        next[record.id] = updated.steps.isEmpty ? nil : updated
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
        } catch {
            throw PulsePlayerError.service("Your fold notes could not be saved. Try again.")
        }
        records = next
        error = nil
    }
}
