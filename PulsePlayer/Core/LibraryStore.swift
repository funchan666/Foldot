import Foundation
import AVFoundation
import Combine
import CoreTransferable
import UniformTypeIdentifiers

struct LocalVideoFolder: Codable, Identifiable {
    let id: UUID
    var name: String
}

enum LibraryList: Equatable {
    case imports, exports, offline, favorites, folder(UUID)

    var filter: String {
        switch self {
        case .imports: "Imports"
        case .exports: "Exports"
        case .offline: "Downloads"
        case .favorites: "Saved"
        case .folder: "Folders"
        }
    }

    var folderID: UUID? {
        if case .folder(let id) = self { return id }
        return nil
    }
}

struct LibraryListRequest: Equatable {
    let id = UUID()
    let list: LibraryList
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot = LessonLibrarySnapshot()
    @Published var error: String?
    @Published private(set) var listRequest: LibraryListRequest?
    func openList(_ list: LibraryList) { listRequest = LibraryListRequest(list: list) }
    func openDownloads() { openList(.offline) }
    private let root: URL
    private let snapshotURL: URL
    private var readable = true

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("FoldotMedia", isDirectory: true)
        snapshotURL = root.appendingPathComponent("library.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                let saved = try JSONDecoder().decode(LessonLibrarySnapshot.self, from: Data(contentsOf: snapshotURL))
                var library = saved
                let sample = Self.retiredSampleID
                library.movies.removeAll { $0.id == sample }
                library.favorites.removeAll { $0.localMovieID == sample }
                library.watchedVideos?.removeAll { $0.clip.localMovieID == sample }
                snapshot = library
                if library.movies.count != saved.movies.count || library.favorites.count != saved.favorites.count ||
                    library.watchedVideos?.count != saved.watchedVideos?.count {
                    save(library)
                }
            }
        } catch {
            readable = false
            self.error = "Your local library could not be read. Existing files have been preserved."
        }
    }
    var movies: [PracticeRecording] { snapshot.movies }
    var importedMovies: [PracticeRecording] { movies.filter { !$0.isExport } }
    var favorites: [LessonClip] { snapshot.favorites }
    var favoriteMovies: [PracticeRecording] { movies.filter { $0.isFavorited == true && !$0.isAudio } }
    var folders: [LocalVideoFolder] { snapshot.folders ?? [] }
    var history: [LessonLinkVisit] { snapshot.history }
    // Only this local identity belonged to the retired built-in video. Imports and exports have independent IDs.
    nonisolated static let retiredSampleID = UUID(uuidString: "96537A05-C53E-4705-A91E-85422DABEAA6")!

    func url(for movie: PracticeRecording) -> URL { root.appendingPathComponent(movie.filename) }

    func movies(in folder: LocalVideoFolder) -> [PracticeRecording] {
        movies.filter { $0.folderID == folder.id }
    }

    func createFolder(_ name: String, moving movieID: UUID? = nil) throws -> LocalVideoFolder {
        let folder = LocalVideoFolder(id: UUID(), name: try validatedFolderName(name))
        var next = snapshot
        if let movieID {
            guard let index = movies.firstIndex(where: { $0.id == movieID && !$0.isAudio }) else { throw PulsePlayerError.storage }
            next.movies[index].folderID = folder.id
        }
        next.folders = folders + [folder]
        try persist(next)
        return folder
    }

    func renameFolder(_ id: UUID, name: String) throws {
        var updated = folders
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw PulsePlayerError.storage }
        updated[index].name = try validatedFolderName(name, excluding: id)
        var next = snapshot
        next.folders = updated
        try persist(next)
    }

    func deleteFolder(_ id: UUID) throws {
        var next = snapshot
        next.folders = folders.filter { $0.id != id }
        for index in next.movies.indices where next.movies[index].folderID == id {
            next.movies[index].folderID = nil
        }
        try persist(next)
    }

    func moveMovie(_ id: UUID, to folderID: UUID?) throws {
        guard let index = movies.firstIndex(where: { $0.id == id && !$0.isAudio }) else { throw PulsePlayerError.storage }
        if let folderID, !folders.contains(where: { $0.id == folderID }) { throw PulsePlayerError.storage }
        guard movies[index].folderID != folderID else { return }
        var next = snapshot
        next.movies[index].folderID = folderID
        try persist(next)
    }

    private func validatedFolderName(_ input: String, excluding id: UUID? = nil) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PulsePlayerError.service("Enter a folder name.") }
        guard name.count <= 80 else { throw PulsePlayerError.service("Folder names can have up to 80 characters.") }
        guard !folders.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw PulsePlayerError.service("A folder with that name already exists.")
        }
        return name
    }

    func watchedVideos(for owner: String?) -> [WatchedVideo] {
        guard let owner else { return [] }
        return snapshot.watchedVideos?.filter { $0.owner == owner } ?? []
    }

    func recordWatch(_ clip: LessonClip, owner: String) {
        guard !clip.playbackURL.isFileURL else { return }
        var next = snapshot
        var history = next.watchedVideos ?? []
        var clip = clip
        if clip.sourceChannel == nil {
            clip.sourceChannel = history.first { $0.owner == owner && $0.id == clip.id }?.clip.sourceChannel
        }
        history.removeAll { $0.owner == owner && $0.id == clip.id }
        history.insert(WatchedVideo(clip: clip, date: Date(), owner: owner), at: 0)
        next.watchedVideos = Array(history.prefix(100))
        save(next)
    }

    func removeWatch(_ visit: WatchedVideo) {
        var next = snapshot
        next.watchedVideos?.removeAll { $0.owner == visit.owner && $0.id == visit.id }
        save(next)
    }

    func markOpened(_ movie: PracticeRecording) {
        guard let index = snapshot.movies.firstIndex(where: { $0.id == movie.id }) else { return }
        var next = snapshot
        next.movies[index].lastOpenedAt = Date()
        save(next)
    }

    @discardableResult
    func addRange(_ range: ClosedRange<Double>, name: String, to movieID: UUID) throws -> VideoRangeMark {
        guard let index = movies.firstIndex(where: { $0.id == movieID && !$0.isAudio }) else { throw PulsePlayerError.storage }
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let mark = VideoRangeMark(id: UUID(), name: title, start: range.lowerBound, end: range.upperBound)
        guard mark.timeRange != nil else { throw PulsePlayerError.service("Choose a start and end for the range.") }
        var next = snapshot
        var ranges = next.movies[index].rangeMarks ?? []
        if let existing = ranges.first(where: { $0.start == mark.start && $0.end == mark.end && $0.name == mark.name }) {
            return existing
        }
        ranges.insert(mark, at: 0)
        next.movies[index].rangeMarks = ranges
        try persist(next)
        return mark
    }

    func removeRange(_ mark: VideoRangeMark, from movieID: UUID) throws {
        guard let index = movies.firstIndex(where: { $0.id == movieID }) else { throw PulsePlayerError.storage }
        var next = snapshot
        next.movies[index].rangeMarks?.removeAll { $0.id == mark.id }
        try persist(next)
    }
    // Internal IDs stay stable; only the user-facing shared copy gets a readable name.
    func shareFile(for movie: PracticeRecording, beforeSharing: (@MainActor () throws -> Void)? = nil) async throws -> URL {
        guard !movie.isExport || beforeSharing != nil else {
            throw PulsePlayerError.service("An active Plus subscription is required to export.")
        }
        try beforeSharing?()
        let source = url(for: movie)
        let title = movie.title
        let task = Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("PulsePlayerSharedVideos", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            // Expired staged copies are disposable; never touch the media library.
            for old in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                if let created = try? old.resourceValues(forKeys: [.creationDateKey]).creationDate,
                   created < Date().addingTimeInterval(-7 * 86_400) { try? fm.removeItem(at: old) }
            }
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
            var name = title.components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if ["mp4", "mov", "m4v", "m4a"].contains((name as NSString).pathExtension.lowercased()) {
                name = (name as NSString).deletingPathExtension
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            while name.utf8.count > 160 { name.removeLast() }
            if name.isEmpty { name = L10n.text("PulsePlayer video") }
            let destination = directory.appendingPathComponent(name).appendingPathExtension(source.pathExtension)
            do {
                try Task.checkCancellation()
                try fm.copyItem(at: source, to: destination)
                try Task.checkCancellation()
                return destination
            } catch { try? fm.removeItem(at: directory); throw error }
        }
        let destination = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        do {
            try Task.checkCancellation()
            try beforeSharing?()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
    }
    func isSaved(_ clip: LessonClip) -> Bool { favorites.contains { $0.id == clip.id } }
    @discardableResult func toggle(_ clip: LessonClip) -> Bool {
        var next = snapshot
        if isSaved(clip) { next.favorites.removeAll { $0.id == clip.id } }
        else { next.favorites.insert(clip, at: 0) }
        do { try persist(next); return true }
        catch { self.error = "Favorites could not be updated. Please try again."; return false }
    }

    func isLocalSaved(_ id: UUID) -> Bool { movies.first(where: { $0.id == id })?.isFavorited == true }

    @discardableResult func toggleLocalFavorite(_ id: UUID) -> Bool {
        guard let index = movies.firstIndex(where: { $0.id == id && !$0.isAudio }) else { return false }
        var next = snapshot
        next.movies[index].isFavorited = next.movies[index].isFavorited != true
        do { try persist(next); return true }
        catch { self.error = "Favorites could not be updated. Please try again."; return false }
    }

    func recordSearch(_ input: String) {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        var next = snapshot
        let existing = next.history.first { $0.link == query }
        next.history.removeAll { $0.link == query }
        next.history.insert(LessonLinkVisit(id: existing?.id ?? UUID(), link: query,
                                           title: existing?.title ?? query, date: Date()), at: 0)
        next.history = Array(next.history.prefix(40))
        save(next)
    }

    func clearHistory() {
        var next = snapshot
        next.history = []
        save(next)
    }
    func removeVisit(_ visit: LessonLinkVisit) {
        var next = snapshot
        next.history.removeAll { $0.id == visit.id }
        save(next)
    }
    func importMovie(_ source: URL, title: String? = nil, folderID: UUID? = nil) async throws -> PracticeRecording {
        try await storeMovie(source, exported: false, title: title, folderID: folderID)
    }

    func saveExport(_ source: URL, title: String, beforeCommit: @escaping @MainActor () throws -> Void) async throws -> PracticeRecording {
        try beforeCommit()
        return try await storeMovie(source, exported: true, title: title, folderID: nil, beforeCommit: beforeCommit)
    }

    private func storeMovie(_ source: URL, exported: Bool, title: String?, folderID: UUID?,
                            beforeCommit: (@MainActor () throws -> Void)? = nil) async throws -> PracticeRecording {
        guard readable else { throw PulsePlayerError.storage }
        let id = UUID()
        let ext = source.pathExtension.lowercased().nilIfBlank ?? "mov"
        var item = PracticeRecording(id: id, filename: id.uuidString + "." + ext,
                                     title: title ?? source.deletingPathExtension().lastPathComponent,
                                     date: Date(), isExport: exported)
        let destination = url(for: item)
        try await Task.detached(priority: .userInitiated) {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }.value
        do {
            if !exported {
                _ = try await editableVideoDuration(for: AVURLAsset(url: destination))
            }
            try Task.checkCancellation()
            try beforeCommit?()
            // The destination may be removed from another scene during import.
            if let folderID, folders.contains(where: { $0.id == folderID }) {
                item.folderID = folderID
            }
            var next = snapshot
            next.movies.insert(item, at: 0)
            try persist(next)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return item
    }
    func delete(_ movie: PracticeRecording) {
        // Commit index removal first; a failed file deletion leaves an orphan, not a broken library entry.
        var next = snapshot
        next.movies.removeAll { $0.id == movie.id }
        do {
            try persist(next)
            let file = url(for: movie)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        } catch { self.error = error.localizedDescription }
    }
    private func save(_ next: LessonLibrarySnapshot) {
        do { try persist(next) } catch { self.error = error.localizedDescription }
    }
    private func persist(_ next: LessonLibrarySnapshot) throws {
        guard readable else { throw PulsePlayerError.storage }
        let data = try JSONEncoder().encode(next)
        try data.write(to: snapshotURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let saved = try Data(contentsOf: snapshotURL)
        guard saved == data else { throw PulsePlayerError.storage }
        snapshot = next
    }
}

struct ImportedMovie: Transferable {
    let url: URL
    let suggestedTitle: String?
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in SentTransferredFile(movie.url) }
        importing: { received in
            let ext = received.file.pathExtension.nilIfBlank ?? "mov"
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: copy)
            let name = received.file.deletingPathExtension().lastPathComponent
            return ImportedMovie(url: copy, suggestedTitle: UUID(uuidString: name) == nil ? name.nilIfBlank : nil)
        }
    }
}
