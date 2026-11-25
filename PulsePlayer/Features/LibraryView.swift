import SwiftUI
import AVFoundation

struct LibraryView: View {
    @EnvironmentObject private var api: APIClient
    @ObservedObject private var practice = FoldPracticeStore.shared
    @State private var showingNotebook = false
    @State private var lastFileCollection = Category.imports
    @FocusState private var findingFold: Bool
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var commerce: CommerceStore
    @ObservedObject private var localPlayback = LocalPlaybackResume.shared
    @State private var showingExportMembership = false
    var edit: (PracticeRecording) -> Void
    var browseVideos: () -> Void
    var openEditor: () -> Void
    let openTools: () -> Void
    let openPlus: () -> Void
    let openHistory: () -> Void
    @Binding var filter: String
    @Binding var importing: Bool
    @Binding var engaged: Bool
    @State private var player: PlayerRoute?
    @State private var sharing: SharedFile?
    @State private var removing: PracticeRecording?
    @State private var removingDownload: OfflineVideo?
    @State private var expandedMovieActionsID: UUID?
    @State private var sharingMovieID: UUID?
    @State private var editingDownloadID: String?
    @Binding var selectedFolderID: UUID?
    @State private var folderAction: FolderAction?
    @State private var folderName = ""
    @State private var folderError: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let foldCollection = "Fold notes"
    private var showsFolds: Bool { filter == Self.foldCollection }
    private var category: Category { Category(rawValue: filter) ?? .imports }
    private var localMovies: [PracticeRecording] {
        category == .exports ? library.movies.filter(\.isExport) : unfiledImports
    }
    private var unfiledImports: [PracticeRecording] { library.importedMovies.filter { $0.folderID == nil } }
    private var selectedFolder: LocalVideoFolder? {
        library.folders.first { $0.id == selectedFolderID }
    }

    private var practiceEntries: [FoldPracticeEntry] {
        practice.recent(owner: api.offlineOwnerID, library: library, offline: offline)
    }

    private enum FolderAction: Identifiable {
        case create(moving: UUID?)
        case rename(LocalVideoFolder)
        case move(PracticeRecording)
        case delete(LocalVideoFolder)

        var id: String { title }
        var title: String {
            switch self {
            case .create: "New folder"
            case .rename: "Rename folder"
            case .move: "Move to folder"
            case .delete: "Delete this folder?"
            }
        }
    }

    private enum Category: String, CaseIterable, Identifiable {
        case imports = "Imports"
        case folders = "Folders"
        case offline = "Downloads"
        case exports = "Exports"
        case saved = "Saved"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .saved: "Favorites"
            case .offline: "Offline"
            case .imports, .folders, .exports: rawValue
            }
        }
        var emptyTitle: String {
            switch self {
            case .saved: "No favorites yet"
            case .offline: "No offline videos yet"
            case .imports: "Import a video"
            case .folders: "No folders yet"
            case .exports: "No exports yet"
            }
        }
        var emptyMessage: String? {
            switch self {
            case .saved: "Save a video while watching to find it here."
            case .offline: "Download a video to watch it without a connection."
            case .imports: "Your original stays untouched."
            case .folders: nil
            case .exports: "Videos and audio you export from the editor appear here."
            }
        }
        var opensOnlineVideos: Bool { self == .saved || self == .offline }
    }

    private var showsEmptyState: Bool {
        guard count(in: category) == 0 else { return false }
        if category == .offline {
            return !offline.busy && offline.error == nil
        }
        return library.error == nil
    }

    private var presentingContent: Bool {
        findingFold || showingNotebook || showingExportMembership || player != nil || folderAction != nil || sharing != nil
            || removing != nil || removingDownload != nil || selectedFolderID != nil
    }

    var body: some View {
        ScenePage() { container in
            let width = min(640, PulsePlayerStyle.pageContentWidth(in: container))
            VStack(alignment: .leading, spacing: 18) {
                libraryHeader
                libraryNavigation
                if showsFolds {
                    if let message = practice.error {
                        ErrorNote(message: message)
                        if practice.needsLoadRetry {
                            ActionButton(title: "Try again", primary: false, action: practice.retryLoading)
                        }
                    }
                    if !practice.needsLoadRetry {
                        FoldLibraryIndex(entries: practiceEntries, searchFocused: $findingFold,
                                         play: openFold, notebook: { showingNotebook = true },
                                         startLesson: startCraneLesson)
                    }
                } else {
                    workbenchActions
                    libraryContents(in: container, width: width)
                }
            }
        }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: presentingContent, initial: true) { _, value in engaged = value }
            .sheet(isPresented: $showingNotebook) { FoldNotebookView() }
            .onChange(of: filter) { _, value in
                expandedMovieActionsID = nil
                findingFold = false
                if let collection = Category(rawValue: value) { lastFileCollection = collection }
                if value != Category.folders.rawValue { selectedFolderID = nil }
            }
            .onChange(of: library.listRequest) { _, _ in expandedMovieActionsID = nil }
            .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
            .fullScreenCover(isPresented: $showingExportMembership) { MembershipView(exportRequired: true) }
            .fullScreenCover(item: $player) { PlayerScreen(route: $0) }
            .sheet(item: $folderAction) { action in folderSheet(action) }
            .sheet(item: $removingDownload) { video in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        SheetHeading(title: "Remove offline video?") { removingDownload = nil }
                        Text(verbatim: video.clip.title).font(.capture(.headline)).lineLimit(3)
                        LocalizedText("This removes the download from this device.")
                            .foregroundStyle(PulsePlayerStyle.secondary)
                        ActionButton(title: "Remove download", primary: false) {
                            offline.remove(video); removingDownload = nil
                        }
                        ActionButton(title: "Cancel") { removingDownload = nil }
                    }.padding(24)
                }.pulsePlayerScreenBackground().presentationDetents([.medium, .large])
            }
            .sheet(item: $removing) { movie in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        SheetHeading(title: "Delete this local copy?") { removing = nil }
                        Text(verbatim: movie.displayFilename).font(.capture(.headline))
                        LocalizedText("This deletes the selected copy from your PulsePlayer library.")
                            .foregroundStyle(PulsePlayerStyle.secondary)
                        ActionButton(title: "Delete local copy") { library.delete(movie); removing = nil }
                        ActionButton(title: "Cancel", primary: false) { removing = nil }
                    }.padding(24)
                }.pulsePlayerScreenBackground().presentationDetents([.medium, .large])
            }
    }

    private var libraryHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                SceneTitle("Library", size: 32).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                PlusEntryButton(action: openPlus)
            }
            VStack(alignment: .leading) {
                SceneTitle("Library", size: 32)
                PlusEntryButton(action: openPlus)
            }
        }
    }

    private var libraryNavigation: some View {
        let choices = Group {
            libraryTab("Marked folds", active: showsFolds) { filter = Self.foldCollection }
            libraryTab("Video files", active: !showsFolds) { filter = lastFileCollection.rawValue }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { choices }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 2) { choices }
        }
        .padding(3)
        .pulsePlayerGlass(in: .rect(cornerRadius: 14))
        .pulsePlayerKeepControlsTogether()
    }

    private func libraryTab(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LocalizedText(title)
                .font(.capture(.subheadline, weight: active ? .bold : .regular))
                .foregroundStyle(active ? PulsePlayerStyle.accent : PulsePlayerStyle.paper)
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(active ? PulsePlayerStyle.mist : .clear, in: .rect(cornerRadius: 11))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func openFold(_ id: FoldPracticeID, stepID: UUID) {
        // A result may outlive a rename, a deletion or an account switch.
        guard let entry = practiceEntries.first(where: { $0.id == id }),
              let step = entry.steps.first(where: { $0.id == stepID }),
              let route = entry.route(library: library, offline: offline) else {
            library.error = "This video file is no longer available."
            return
        }
        do {
            try practice.select(step, in: id, reopen: false)
            findingFold = false
            player = route
        } catch { library.error = error.localizedDescription }
    }

    private func startCraneLesson() {
        do {
            player = try library.paperCraneRoute()
        } catch { library.error = error.localizedDescription }
    }

    private var workbenchActions: some View {
        let buttons = Group {
            Button { openTools() } label: {
                HStack {
                    Glyph(symbol: .edit, size: 16, tint: PulsePlayerStyle.accent)
                    LocalizedText("Editing tools")
                }
            }
            .accessibilityIdentifier("library.tools")
            Button(action: openHistory) {
                LocalizedText("Recently opened")
            }
            .accessibilityIdentifier("library.history")
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 5) { buttons }
        }
        .buttonStyle(LibraryActionStyle()).disabled(importing)
    }

    private func libraryContents(in container: GeometryProxy, width: CGFloat) -> some View {
        let bounds = CGRect(origin: .zero, size: container.size)
        let usesSidebar = width >= 540 && typeSize <= .xLarge && !PulsePlayerStyle.intersectsReservedRegion(bounds, in: container)
        let layout = usesSidebar ? AnyLayout(HStackLayout(alignment: .top, spacing: 22))
                                 : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        return layout {
            if usesSidebar {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Category.allCases) { entry in
                        Button { filter = entry.rawValue } label: {
                            HStack(spacing: 6) {
                                LocalizedText(entry.title)
                                    .font(.capture(.subheadline, weight: entry == category ? .bold : .regular))
                                Spacer(minLength: 2)
                                Text(count(in: entry), format: .number)
                                    .font(.capture(.footnote)).monospacedDigit()
                            }
                            .padding(.horizontal, 8).frame(minHeight: 44)
                            .foregroundStyle(entry == category ? PulsePlayerStyle.accent : PulsePlayerStyle.paper)
                            .background(entry == category ? PulsePlayerStyle.mist : .clear, in: .rect(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }.buttonStyle(PressStyle())
                        .accessibilityAddTraits(entry == category ? .isSelected : [])
                    }
                }.frame(width: 148)
            } else {
                Menu {
                    ForEach(Category.allCases) { entry in
                        Button { filter = entry.rawValue } label: {
                            LocalizedText("%@ (%@)", L10n.text(entry.title), count(in: entry).formatted())
                        }.accessibilityAddTraits(entry == category ? .isSelected : [])
                    }
                } label: {
                    HStack(spacing: 10) {
                        LocalizedText(category.title).font(.capture(.headline, weight: .semibold))
                        Text(count(in: category), format: .number)
                            .font(.capture(.footnote)).monospacedDigit().foregroundStyle(PulsePlayerStyle.secondary)
                        Spacer(minLength: 0)
                        LocalizedText("Collections").font(.capture(.footnote, weight: .medium))
                            .foregroundStyle(PulsePlayerStyle.accent)
                        Glyph(symbol: .back, size: 10, tint: PulsePlayerStyle.accent).rotationEffect(.degrees(-90))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 4)
                    .frame(minHeight: 48)
                    .pulsePlayerGlass(in: .rect(cornerRadius: 12))
                }
                .accessibilityHint("Choose a library collection")
                .pulsePlayerKeepControlsTogether()
            }
            librarySection(stackedRows: (usesSidebar ? width - 170 : width) < 310 || typeSize.isAccessibilitySize)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func librarySection(stackedRows: Bool) -> some View {
        let empty = showsEmptyState
        return VStack(alignment: .leading, spacing: 16) {
            if category != .folders, empty || category == .imports {
                sectionIntro(empty: empty, stacked: stackedRows)
            }
            switch category {
            case .saved:
                let localFavorites = library.favoriteMovies
                LazyVStack(spacing: 0) {
                    ForEach(localFavorites) {
                        movieRow($0, stacked: stackedRows, playlist: localFavorites, favoriteRow: true)
                    }
                    ForEach(library.favorites) { clip in favoriteRow(clip, stacked: stackedRows) }
                }
            case .folders:
                folderContents(stackedRows: stackedRows)
            case .offline:
                downloadStatus
                LazyVStack(spacing: 0) {
                    ForEach(offline.videos) { video in downloadRow(video, stacked: stackedRows) }
                }
                DownloadAllowanceSummary()
            case .imports, .exports:
                LazyVStack(spacing: 0) {
                    ForEach(localMovies) { movie in movieRow(movie, stacked: stackedRows, playlist: localMovies) }
                }
            }
        }
    }

    private func sectionIntro(empty: Bool, stacked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if empty {
                EmptyStateScene(title: category.emptyTitle, message: category.emptyMessage)
            }
            if category == .imports {
                VideoImportActions(onImported: { playMovie($0, playlist: [$0]) }, importing: $importing,
                                   presentation: .library(stacked: stacked))
            } else if category.opensOnlineVideos {
                EmptyStateAction(title: "Browse videos", symbol: .play, primary: true, action: browseVideos)
            } else {
                EmptyStateAction(title: "Edit a video", symbol: .edit, primary: true, action: openEditor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func count(in entry: Category) -> Int {
        switch entry {
        case .saved: library.favoriteMovies.count + library.favorites.count
        case .folders: library.folders.count
        case .offline: offline.videos.count
        case .imports: unfiledImports.count
        case .exports: library.movies.lazy.filter(\.isExport).count
        }
    }

    @ViewBuilder private func folderContents(stackedRows: Bool) -> some View {
        if let folder = selectedFolder {
            let movies = library.movies(in: folder)
            VStack(alignment: .leading, spacing: 12) {
                Button { selectedFolderID = nil } label: {
                    HStack(spacing: 8) {
                        Glyph(symbol: .back, size: 12, tint: PulsePlayerStyle.accent)
                        LocalizedText("Folders")
                    }
                }.buttonStyle(LibraryActionStyle())

                Text(verbatim: folder.name).font(.capture(.title2, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { folderManagementButtons(folder) }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) { folderManagementButtons(folder) }
                }.disabled(importing)

                VideoImportActions(onImported: { _ in }, importing: $importing,
                                   presentation: .library(stacked: stackedRows), folderID: folder.id)
                if movies.isEmpty { EmptyStateScene(title: "No videos in this folder yet") }
                LazyVStack(spacing: 0) {
                    ForEach(movies) { movie in movieRow(movie, stacked: stackedRows, playlist: movies) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ActionButton(title: "New folder") { presentFolderAction(.create(moving: nil)) }
                    .disabled(importing)
                    .accessibilityIdentifier("library.folders.create")
                if library.folders.isEmpty { EmptyStateScene(title: Category.folders.emptyTitle) }
                LazyVStack(spacing: 0) {
                    ForEach(library.folders, content: folderRow)
                }
            }
        }
    }

    @ViewBuilder private func folderManagementButtons(_ folder: LocalVideoFolder) -> some View {
        Button("Rename folder") { presentFolderAction(.rename(folder), name: folder.name) }
            .buttonStyle(LibraryActionStyle())
        Button("Delete folder") { presentFolderAction(.delete(folder)) }
            .buttonStyle(LibraryActionStyle())
    }

    private func folderRow(_ folder: LocalVideoFolder) -> some View {
        Button {
            expandedMovieActionsID = nil
            selectedFolderID = folder.id
            filter = Category.folders.rawValue
        } label: {
            HStack(spacing: 12) {
                Glyph(symbol: .folder, size: 20, tint: PulsePlayerStyle.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: folder.name).font(.capture(.headline))
                    LocalizedText("%@ videos", library.movies(in: folder).count.formatted())
                        .font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Glyph(symbol: .back, size: 12, tint: PulsePlayerStyle.secondary).rotationEffect(.degrees(180))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(importing)
        .modifier(LibraryRowSurface())
    }

    private func presentFolderAction(_ action: FolderAction, name: String = "") {
        folderName = name
        folderError = nil
        folderAction = action
    }

    private func folderSheet(_ action: FolderAction) -> some View {
        VStack(spacing: 0) {
            SheetHeading(title: action.title) { folderAction = nil }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch action {
                    case .create(let movieID):
                        folderNameEditor(buttonTitle: "Create folder") {
                            let folder = try library.createFolder(folderName, moving: movieID)
                            if movieID == nil { selectedFolderID = folder.id }
                        }
                    case .rename(let folder):
                        folderNameEditor(buttonTitle: "Save") {
                            try library.renameFolder(folder.id, name: folderName)
                        }
                    case .move(let movie):
                        moveOptions(movie)
                    case .delete(let folder):
                        Text(verbatim: folder.name).font(.capture(.headline))
                        LocalizedText("Deleting this folder keeps its videos in your library.")
                            .font(.capture(.subheadline)).foregroundStyle(PulsePlayerStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ActionButton(title: "Delete folder", primary: false) {
                            commitFolderChange {
                                try library.deleteFolder(folder.id)
                                if selectedFolderID == folder.id { selectedFolderID = nil }
                            }
                        }
                    }
                    if let folderError { ErrorNote(message: folderError) }
                }
                .pulsePlayerPage()
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .foregroundStyle(PulsePlayerStyle.paper)
        .pulsePlayerScreenBackground()
        .presentationDetents([.medium, .large])
    }

    private func folderNameEditor(buttonTitle: String, save: @escaping () throws -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Folder name", text: $folderName)
                .pulsePlayerField()
                .onChange(of: folderName) { _, _ in folderError = nil }
                .submitLabel(.done)
                .onSubmit { commitFolderChange(save) }
            ActionButton(title: buttonTitle) { commitFolderChange(save) }
                .disabled(folderName.nilIfBlank == nil)
        }
    }

    private func moveOptions(_ movie: PracticeRecording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: movie.displayFilename).font(.capture(.headline))
                .fixedSize(horizontal: false, vertical: true)
            if movie.folderID != nil {
                ActionButton(title: "Remove from folder", primary: false) {
                    commitFolderChange { try library.moveMovie(movie.id, to: nil) }
                }
            }
            ForEach(library.folders.filter { $0.id != movie.folderID }) { folder in
                Button {
                    commitFolderChange { try library.moveMovie(movie.id, to: folder.id) }
                } label: {
                    HStack(spacing: 12) {
                        Glyph(symbol: .folder, size: 18, tint: PulsePlayerStyle.accent)
                        Text(verbatim: folder.name).font(.capture(.subheadline, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .pulsePlayerGlass(in: .rect(cornerRadius: 10))
                    .contentShape(Rectangle())
                }.buttonStyle(PressStyle())
            }
            ActionButton(title: "New folder") { presentFolderAction(.create(moving: movie.id)) }
        }
    }

    private func commitFolderChange(_ change: () throws -> Void) {
        do {
            try change()
            folderAction = nil
        } catch {
            folderError = error.localizedDescription
        }
    }

    @ViewBuilder private var downloadStatus: some View {
        if offline.busy || offline.error != nil {
            VStack(alignment: .leading, spacing: 8) {
                if offline.downloadingID != nil {
                    if let title = offline.currentTitle {
                        Text(verbatim: title).font(.capture(.subheadline, weight: .semibold)).lineLimit(2)
                    }
                    LocalizedText("Downloading · \(Int(offline.progress * 100))%")
                        .font(.capture(.caption)).monospacedDigit()
                    Button("Cancel download") { Task { await offline.cancel() } }
                        .buttonStyle(LibraryActionStyle())
                } else if offline.busy {
                    HStack(spacing: 9) {
                        ProgressView().tint(PulsePlayerStyle.accent).accessibilityHidden(true)
                        LocalizedText(offline.isRestoring ? "Restoring downloads…" : "Preparing download…")
                            .font(.capture(.subheadline))
                    }
                }
                if let error = offline.error {
                    ErrorNote(message: error)
                    if offline.downloadingID != nil {
                        Button("Retry") { Task { await offline.retryCompletion() } }
                            .buttonStyle(LibraryActionStyle())
                    }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .pulsePlayerPanel(cornerRadius: 16)
        }
    }

    private func favoriteRow(_ clip: LessonClip, stacked: Bool) -> some View {
        let url = offline.cached(clip.id)?.url ?? clip.playbackURL
        return HStack(spacing: 4) {
            Button { player = PlayerRoute(clips: library.favorites, startID: clip.id) } label: {
                fileLabel(clip.title, stacked: stacked,
                          thumbnail: VideoFileThumbnail(url: url, maximumSize: 480, fallbackCover: clip.coverURL),
                          actionGlyph: .play) {
                    if let channel = clip.channel.nilIfBlank { Text(verbatim: channel) }
                }
            }.buttonStyle(PressStyle())
            IconButton(symbol: .bookmark, label: "Remove from favorites") { library.toggle(clip) }
        }
        .modifier(LibraryRowSurface())
    }

    private func fileLabel<Detail: View>(_ filename: String, stacked: Bool, thumbnail: VideoFileThumbnail,
                                         actionGlyph: PulsePlayerGlyph? = nil, @ViewBuilder detail: () -> Detail) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                             : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            thumbnail
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: stacked ? 132 : 88)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    if let actionGlyph {
                        Glyph(symbol: actionGlyph, size: 10, tint: PulsePlayerStyle.onDark)
                            .frame(width: 22, height: 22)
                            .background(PulsePlayerStyle.mediaBackdrop.opacity(0.88), in: RoundedRectangle(cornerRadius: 5))
                            .padding(4).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: filename)
                    .font(.capture(.subheadline, weight: .semibold))
                    .foregroundStyle(PulsePlayerStyle.paper)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .truncationMode(.middle)
                detail()
                    .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func downloadRow(_ video: OfflineVideo, stacked: Bool) -> some View {
        let available = video.hasLocalFile
        let actionsLayout = stacked || typeSize > .xLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 8))
        return VStack(alignment: .leading, spacing: 2) {
            Button { playDownload(video) } label: {
                fileLabel(video.displayFilename, stacked: stacked,
                          thumbnail: VideoFileThumbnail(url: video.url, maximumSize: 480, fallbackCover: video.clip.coverURL),
                          actionGlyph: available ? .play : nil) {
                    LocalizedText(available ? "Available offline" : "Download needed")
                }
            }.buttonStyle(PressStyle())
            HStack(alignment: .bottom, spacing: 8) {
                if available {
                    actionsLayout { downloadActions(video) }
                } else {
                    Button("Download again") { Task { await offline.download(video.clip) } }
                        .buttonStyle(LibraryActionStyle()).disabled(offline.busy)
                }
                Spacer(minLength: 0)
                IconButton(symbol: .close, label: "Remove download") { removingDownload = video }
            }
        }
        .modifier(LibraryRowSurface())
    }

    @ViewBuilder private func downloadActions(_ video: OfflineVideo) -> some View {
        VideoExportEntry(clip: offline.playable(video.clip)) { openExport in
            Button("Export", action: openExport).buttonStyle(LibraryActionStyle())
        }
        if !video.isHLS {
            Button(LocalizedStringKey(editingDownloadID == video.id ? "Importing…" : "Edit video")) {
                editDownload(video)
            }.buttonStyle(LibraryActionStyle()).disabled(importing)
        }
    }

    private func editDownload(_ video: OfflineVideo) {
        guard !importing else { return }
        guard let stored = offline.cached(video.id), !stored.isHLS else {
            offline.error = "This download is no longer on this device. Download it again."
            return
        }
        editingDownloadID = video.id
        importing = true
        Task {
            defer { editingDownloadID = nil; importing = false }
            do {
                let copy = try await library.importMovie(stored.url, title: stored.clip.title)
                edit(copy)
            } catch { library.error = error.localizedDescription }
        }
    }

    private func movieRow(_ movie: PracticeRecording, stacked: Bool, playlist: [PracticeRecording],
                          favoriteRow: Bool = false) -> some View {
        let thumbnail = VideoFileThumbnail(url: library.url(for: movie), maximumSize: 480, isAudio: movie.isAudio)
        let label = fileLabel(movie.displayFilename, stacked: stacked, thumbnail: thumbnail,
                              actionGlyph: movie.isAudio ? nil : .play) {
            LocalizedDateText(date: movie.date)
            if sharingMovieID == movie.id {
                LocalizedText("Preparing export…")
            }
            if let position = localPlayback.position(for: movie), position.fraction > 0 {
                ProgressView(value: position.fraction)
                    .tint(PulsePlayerStyle.accent)
                    .frame(maxWidth: 160)
                    .accessibilityLabel(LocalizedStringKey("Playback position"))
            }
        }
        let showingActions = expandedMovieActionsID == movie.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: stacked ? .top : .center, spacing: 4) {
                if movie.isAudio {
                    label
                } else {
                    Button { playMovie(movie, playlist: playlist) } label: { label }.buttonStyle(PressStyle())
                }
                Button {
                    expandedMovieActionsID = showingActions ? nil : movie.id
                } label: {
                    TintedArtwork(name: "PlayerMore", tint: showingActions ? PulsePlayerStyle.accent : PulsePlayerStyle.secondary)
                        .frame(width: 16, height: 16)
                        .frame(width: 32, height: 32)
                        .pulsePlayerGlass(in: Capsule(), tint: showingActions ? PulsePlayerStyle.accent.opacity(0.18) : nil)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(LocalizedStringKey("More"))
                .accessibilityAddTraits(showingActions ? .isSelected : [])
                .disabled(importing)
            }
            if showingActions {
                Rectangle().fill(PulsePlayerStyle.line).frame(height: 1).accessibilityHidden(true)
                movieActions(movie, stacked: stacked, favoriteRow: favoriteRow)
                    .disabled(importing)
            }
        }
        .modifier(LibraryRowSurface())
    }

    private func movieActions(_ movie: PracticeRecording, stacked: Bool, favoriteRow: Bool) -> some View {
        let row = stacked || typeSize > .xLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        return VStack(alignment: .leading, spacing: 0) {
            if !movie.isAudio {
                row {
                    Button("Edit video") {
                        expandedMovieActionsID = nil
                        edit(movie)
                    }
                    .buttonStyle(LibraryMovieActionStyle(symbol: .edit, emphasized: true))
                    Button("Move to folder") {
                        expandedMovieActionsID = nil
                        presentFolderAction(.move(movie))
                    }
                    .buttonStyle(LibraryMovieActionStyle(symbol: .folder))
                }
            }
            row {
                Button("Share") {
                    expandedMovieActionsID = nil
                    shareMovie(movie)
                }
                .disabled(sharingMovieID != nil)
                if favoriteRow {
                    Button("Remove from favorites") {
                        expandedMovieActionsID = nil
                        if library.isLocalSaved(movie.id) { library.toggleLocalFavorite(movie.id) }
                    }
                } else {
                    Button("Delete local file", role: .destructive) {
                        expandedMovieActionsID = nil
                        removing = movie
                    }
                }
            }
            .buttonStyle(LibraryMovieActionStyle())
        }
    }

    private func playDownload(_ video: OfflineVideo) {
        let clips = offline.videos.compactMap { item -> LessonClip? in
            offline.cached(item.id) == nil ? nil : offline.playable(item.clip)
        }
        if clips.contains(where: { $0.id == video.id }) {
            player = PlayerRoute(clips: clips, startID: video.id)
        } else { offline.error = "This download is no longer on this device. Download it again." }
    }

    private func playMovie(_ movie: PracticeRecording, playlist: [PracticeRecording]) {
        if let route = PlayerRoute.localMovies(playlist, selected: movie, library: library) {
            player = route
        } else {
            library.error = "This video file is no longer available."
        }
    }

    private func shareMovie(_ movie: PracticeRecording) {
        guard commerce.canExportMedia else {
            showingExportMembership = true
            return
        }
        sharingMovieID = movie.id
        Task {
            defer { sharingMovieID = nil }
            do { sharing = SharedFile(url: try await library.shareFile(for: movie, commerce: commerce)) }
            catch { library.error = error.localizedDescription }
        }
    }
}

private struct FoldLibraryIndex: View {
    let entries: [FoldPracticeEntry]
    @FocusState.Binding var searchFocused: Bool
    let play: (FoldPracticeID, UUID) -> Void
    let notebook: () -> Void
    let startLesson: () -> Void
    @Environment(\.locale) private var locale
    @State private var query = ""
    @State private var status = Status.all
    @State private var expanded: FoldPracticeID?

    private enum Status: String, CaseIterable {
        case all = "All sessions"
        case underway = "In progress"
        case finished = "Completed"

        func includes(_ entry: FoldPracticeEntry) -> Bool {
            switch self {
            case .all: true
            case .underway: entry.finishedAt == nil
            case .finished: entry.finishedAt != nil
            }
        }
    }

    private struct Mark: Identifiable {
        let step: FoldPracticeStep
        let numberLabel: String
        let name: String?
        var id: UUID { step.id }
    }

    private struct Matches: Identifiable {
        let entry: FoldPracticeEntry
        let marks: [Mark]
        var id: FoldPracticeID { entry.id }
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var results: [Matches] {
        let language = AppLanguage.from(locale)
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.compactMap { entry in
            guard status.includes(entry) else { return nil }
            let marks: [Mark] = entry.steps.enumerated().compactMap { offset, step in
                let ordinal = (offset + 1).formatted(.number.locale(locale))
                let label = L10n.format("Fold %@", [ordinal], language: language)
                let name = step.displayName(language: language)
                if !words.isEmpty {
                    let text = [entry.clip.title, name ?? "", label, durationLabel(step.start)].joined(separator: " ")
                    guard words.allSatisfy({ word in
                        text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                   range: nil, locale: locale) != nil
                    }) else { return nil }
                }
                return Mark(step: step, numberLabel: label, name: name)
            }
            return marks.isEmpty ? nil : Matches(entry: entry, marks: marks)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if entries.isEmpty {
                EmptyStateScene(title: "No folds marked yet", message: "Open a lesson and mark a fold to keep its place here.")
                ActionButton(title: "Play the crane lesson", action: startLesson)
            } else {
                searchField
                statusFilter
                let matches = results
                if matches.isEmpty {
                    EmptyStateScene(title: searching ? "No matching folds" : "No sessions with this status")
                    Button {
                        query = ""
                        status = .all
                        searchFocused = false
                    } label: { LocalizedText("Show all sessions") }
                        .buttonStyle(LibraryActionStyle())
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(matches) { group in
                            lesson(group)
                            Divider()
                        }
                    }
                }
                EmptyStateAction(title: "Practice notebook", symbol: .fold, primary: false) {
                    searchFocused = false
                    notebook()
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Glyph(symbol: .search, size: 16, tint: PulsePlayerStyle.secondary).accessibilityHidden(true)
            TextField("Find a lesson or fold", text: $query)
                .textFieldStyle(.plain).autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                .accessibilityIdentifier("library.findFold")
            if !query.isEmpty {
                IconButton(symbol: .close, label: "Clear search") { query = "" }
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .pulsePlayerGlass(in: .rect(cornerRadius: 12))
        .pulsePlayerKeepControlsTogether()
    }

    private var statusFilter: some View {
        let choices = ForEach(Status.allCases, id: \.self) { choice in
            Button {
                status = choice
                searchFocused = false
            } label: {
                LocalizedText(choice.rawValue)
                    .font(.capture(.footnote, weight: choice == status ? .bold : .regular))
                    .foregroundStyle(choice == status ? PulsePlayerStyle.accent : PulsePlayerStyle.secondary)
                    .padding(.horizontal, 8).frame(minHeight: 44)
                    .background(choice == status ? PulsePlayerStyle.mist : .clear, in: .rect(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityAddTraits(choice == status ? .isSelected : [])
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) { choices }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 0) { choices }
        }.pulsePlayerKeepControlsTogether()
    }

    @ViewBuilder private func lesson(_ group: Matches) -> some View {
        let entry = group.entry
        let isOpen = searching || expanded == entry.id
        if searching {
            Text(verbatim: entry.clip.title)
                .font(.capture(.headline, weight: .semibold)).accessibilityAddTraits(.isHeader)
        } else {
            Button {
                expanded = isOpen ? nil : entry.id
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: entry.clip.title).font(.capture(.headline, weight: .semibold))
                        if entry.finishedAt != nil {
                            LocalizedText("Completed")
                                .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
                        } else {
                            LocalizedText("Fold %@ of %@", String(entry.currentStepNumber), String(entry.steps.count))
                                .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Glyph(symbol: .back, size: 12, tint: PulsePlayerStyle.accent)
                        .rotationEffect(.degrees(isOpen ? 90 : -90)).accessibilityHidden(true)
                }
                .frame(minHeight: 48).contentShape(Rectangle())
            }
            .buttonStyle(PressStyle()).multilineTextAlignment(.leading)
            .accessibilityHint(isOpen ? Text("Hide marked folds") : Text("Show marked folds"))
        }

        if isOpen {
            ForEach(group.marks) { mark in
                Button { play(entry.id, mark.id) } label: {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            if let name = mark.name {
                                Text(verbatim: name).font(.capture(.body, weight: .medium))
                                Text(verbatim: mark.numberLabel)
                                    .font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.secondary)
                            } else {
                                Text(verbatim: mark.numberLabel).font(.capture(.body, weight: .medium))
                            }
                        }.fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 2)
                        Text(verbatim: durationLabel(mark.step.start))
                            .font(.capture(.footnote)).monospacedDigit().foregroundStyle(PulsePlayerStyle.secondary)
                            .fixedSize()
                        Glyph(symbol: .play, size: 13, tint: PulsePlayerStyle.accent).accessibilityHidden(true)
                    }
                    .padding(.leading, 10).padding(.vertical, 3)
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle()).multilineTextAlignment(.leading)
                .accessibilityHint(Text("Play from this fold"))
            }
        } else if let step = entry.currentStep {
            Button { play(entry.id, step.id) } label: {
                LocalizedText(entry.finishedAt == nil ? "Resume at %@" : "Review from %@", durationLabel(step.start))
            }
            .buttonStyle(LibraryActionStyle())
        }
    }
}

private struct LibraryRowSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider().allowsHitTesting(false) }
    }
}

private struct LibraryMovieActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var symbol: PulsePlayerGlyph? = nil
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        let foreground = configuration.role == .destructive ? PulsePlayerStyle.danger
            : emphasized ? PulsePlayerStyle.accent : PulsePlayerStyle.paper
        let label = HStack(spacing: 7) {
            if let symbol { Glyph(symbol: symbol, size: 14, tint: PulsePlayerStyle.accent) }
            configuration.label
                .font(.capture(.footnote, weight: .semibold))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minWidth: 44, maxWidth: .infinity, minHeight: 34, alignment: .leading)

        return Group {
            if emphasized {
                label.pulsePlayerGlass(in: .rect(cornerRadius: 8), tint: PulsePlayerStyle.accent.opacity(0.12),
                                 fallback: PulsePlayerStyle.mist)
            } else {
                label
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .opacity(!enabled ? 0.58 : configuration.isPressed ? 0.72 : 1)
    }
}

private struct LibraryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.capture(.footnote, weight: .semibold))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(minHeight: 32)
            .foregroundStyle(PulsePlayerStyle.accent)
            .pulsePlayerGlass(in: .rect(cornerRadius: 8))
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(!enabled ? 0.58 : configuration.isPressed ? 0.72 : 1)
    }
}

struct OfflineDownloadButton: View {
    let clip: LessonClip
    var starting = false
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var commerce: CommerceStore
    @State private var downloadGate = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                downloadStatus
                Rectangle().fill(PulsePlayerStyle.onDark.opacity(0.14)).frame(height: 1)
                    .padding(.horizontal, 12).accessibilityHidden(true)
                VideoExportEntry(clip: clip) { openExport in
                    Button(action: openExport) {
                        PlayerMenuRow(symbol: .download) { LocalizedText("Export video") }
                    }
                    .buttonStyle(PressStyle())
                }
                if let error = offline.error {
                    ErrorNote(message: error, onMedia: true).padding(.horizontal, 12)
                    if offline.downloadingID == clip.id {
                        downloadAction("Retry", symbol: .download) { Task { await offline.retryCompletion() } }
                    }
                }
            }
            .background(PulsePlayerStyle.onDark.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            DownloadAllowanceSummary(onMedia: true)
        }
        .fullScreenCover(isPresented: $downloadGate) { AllowanceLimitPrompt(kind: .download) }
    }

    @ViewBuilder private var downloadStatus: some View {
        if offline.cached(clip.id) != nil || clip.playbackURL.isFileURL {
            statusText("Available offline").foregroundStyle(PulsePlayerStyle.mediaAccent)
            DownloadCompletionNotice(onMedia: true)
        } else if offline.downloadingID == clip.id {
            VStack(alignment: .leading, spacing: 8) {
                LocalizedText("Downloading · \(Int(offline.progress * 100))%")
                    .font(.capture(.subheadline, weight: .medium)).monospacedDigit()
                ProgressView(value: offline.progress)
                    .progressViewStyle(.linear)
                    .tint(PulsePlayerStyle.mediaAccent).accessibilityHidden(true)
            }.padding(12)
            downloadAction("Cancel download", symbol: .close) { Task { await offline.cancel() } }
        } else if starting || offline.preparingID == clip.id {
            HStack(spacing: 8) {
                ProgressView().tint(PulsePlayerStyle.mediaAccent).accessibilityHidden(true)
                LocalizedText("Preparing download…")
                    .font(.capture(.subheadline)).fixedSize(horizontal: false, vertical: true)
            }.padding(12)
        } else {
            downloadAction("Download for offline viewing", symbol: .download) {
                if quota.mayDownload(clip.id, premium: commerce.premium) {
                    Task { await offline.download(clip) }
                } else { downloadGate = true }
            }.disabled(offline.busy || clip.playbackURL.isFileURL)
                .accessibilityIdentifier("player.downloadOffline")
            if offline.isRestoring {
                statusText("Restoring downloads…").foregroundStyle(PulsePlayerStyle.mediaSecondary)
            } else if offline.busy {
                statusText("Another download is in progress.").foregroundStyle(PulsePlayerStyle.mediaSecondary)
            }
        }
    }

    private func statusText(_ title: String) -> some View {
        LocalizedText(title).font(.capture(.subheadline))
            .fixedSize(horizontal: false, vertical: true).padding(12)
    }

    private func downloadAction(_ title: String, symbol: PulsePlayerGlyph, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PlayerMenuRow(symbol: symbol, showsChevron: false) { LocalizedText(title) }
        }
        .buttonStyle(PressStyle())
    }
}

// A separate, always-visible workflow; users need not visit the cache panel.
struct VideoExportEntry<Trigger: View>: View {
    let clip: LessonClip
    let trigger: (@escaping () -> Void) -> Trigger
    @State private var showingExport = false
    @State private var showingMembership = false
    @EnvironmentObject private var commerce: CommerceStore
    var body: some View {
        trigger(openExport)
            .accessibilityIdentifier("player.openExport")
            .sheet(isPresented: $showingExport) { OfflineExportSheet(clip: clip).preferredColorScheme(.light) }
            .fullScreenCover(isPresented: $showingMembership, onDismiss: {
                if commerce.canExportMedia { showingExport = true }
            }) {
                MembershipView(exportRequired: true)
            }
    }

    private func openExport() {
        if commerce.canExportMedia { showingExport = true }
        else { showingMembership = true }
    }
}

private struct OfflineExportSheet: View {
    let clip: LessonClip
    @Environment(\.dismiss) private var dismiss
    @StateObject private var departure = ExportDeparture()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeading(title: "Export video") { departure.request { dismiss() } }
                Text(verbatim: clip.title).font(.capture(.subheadline)).fixedSize(horizontal: false, vertical: true)
                OfflineExportButton(clip: clip)
            }.padding(22)
        }.pulsePlayerScreenBackground().presentationDetents([.medium, .large])
            .environmentObject(departure)
            .modifier(ExportDepartureProtection(departure: departure))
    }
}

// One owner for the close button, explicit cancel and interactive dismissal.
@MainActor
final class ExportDeparture: ObservableObject {
    @Published private(set) var running = false
    @Published var confirming = false
    private var cancellation: (() -> Void)?
    private var afterCancellation: (() -> Void)?
    func begin(cancel: @escaping () -> Void) { running = true; cancellation = cancel }
    func finish() {
        running = false; cancellation = nil
        confirming = false; afterCancellation = nil
    }
    func request(_ close: @escaping () -> Void = {}) {
        guard running else { close(); return }
        afterCancellation = close; confirming = true
    }
    func keepWorking() { confirming = false; afterCancellation = nil }
    func stop() {
        let close = afterCancellation
        cancellation?()
        confirming = false; afterCancellation = nil
        close?()
    }
}

struct ExportDepartureProtection: ViewModifier {
    @ObservedObject var departure: ExportDeparture
    func body(content: Content) -> some View {
        content.interactiveDismissDisabled(departure.running)
            .accessibilityHidden(departure.confirming)
            .overlay {
                if departure.confirming {
                    GeometryReader { container in
                        ScrollView {
                            VStack(spacing: 18) {
                                LocalizedText("Stop this export?").font(.capture(.headline))
                                LocalizedText("The export is still in progress. Leaving now cancels it. Your video stays safe.")
                                    .font(.capture(.subheadline)).foregroundStyle(PulsePlayerStyle.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                ActionButton(title: "Keep exporting", action: departure.keepWorking)
                                ActionButton(title: "Stop export", primary: false, action: departure.stop)
                            }.padding(22).frame(maxWidth: 360)
                                .background { CaptureSurface(tone: .plum) }.padding(20)
                                .frame(maxWidth: .infinity, minHeight: container.size.height)
                        }.background(.black.opacity(0.7))
                            .accessibilityAddTraits(.isModal)
                    }
                }
            }
    }
}

struct DownloadCompletionNotice: View {
    var onMedia = false
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        Group {
            if offline.completedDownloadID != nil {
                if onMedia {
                    notice.padding(.horizontal, 12)
                } else {
                    notice.padding(12)
                        .pulsePlayerGlass(in: .rect(cornerRadius: 14), fallback: PulsePlayerStyle.raised, interactive: false)
                        .padding(.horizontal, 12)
                }
            }
        }.task(id: offline.completedDownloadID) {
            guard let notice = offline.completedDownloadID else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            if offline.completedDownloadID == notice { offline.completedDownloadID = nil }
        }
    }

    private var notice: some View {
        HStack(spacing: onMedia ? 8 : 12) {
            LocalizedText("Ready to watch offline")
                .font(.capture(.caption)).fixedSize(horizontal: false, vertical: true)
            Button {
                offline.completedDownloadID = nil
                library.openDownloads()
            } label: {
                LocalizedText("View").font(.capture(.footnote, weight: .semibold))
                    .foregroundStyle(onMedia ? PulsePlayerStyle.mediaAccent : PulsePlayerStyle.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }.buttonStyle(PressStyle())
                .accessibilityLabel(LocalizedStringKey("View offline videos"))
            if onMedia {
                Button { offline.completedDownloadID = nil } label: {
                    Glyph(symbol: .close, size: 14, tint: PulsePlayerStyle.mediaSecondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(PressStyle()).accessibilityLabel(LocalizedStringKey("Dismiss message"))
            } else {
                IconButton(symbol: .close, label: "Dismiss message") { offline.completedDownloadID = nil }
            }
        }
        .foregroundStyle(onMedia ? PulsePlayerStyle.mediaSecondary : PulsePlayerStyle.paper)
    }
}

// Uncached exports use the same download admission and completion journal.
// Export is a Plus benefit; cached copies still pass the membership check.
private struct OfflineExportButton: View {
    let clip: LessonClip
    @EnvironmentObject private var departure: ExportDeparture
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var commerce: CommerceStore
    @State private var downloadGate = false
    @State private var preparingSource = false
    @State private var exportTask: Task<Void, Never>?
    @State private var sharing: SharedFile?
    @State private var exportError: String?
    @State private var savedExport: PracticeRecording?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let savedExport {
                SavedVideoExport(movie: savedExport, sharing: exportTask != nil) {
                    shareExport(savedExport)
                }
            } else {
                ActionButton(title: preparingSource ? "Preparing export…" : exportTask == nil ? "Export video" : "Exporting…",
                             primary: false, busy: exportTask != nil, action: startExport)
                    .accessibilityIdentifier("player.exportVideo")
                if !clip.playbackURL.isFileURL, offline.cached(clip.id) == nil {
                    LocalizedText("We download the video before exporting. Existing downloads are reused.")
                        .font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.secondary)
                    DownloadAllowanceSummary()
                }
                if preparingSource, offline.downloadingID == clip.id {
                    LocalizedText("Downloading · \(Int(offline.progress * 100))%").font(.capture(.caption))
                }
                if exportTask != nil {
                    Button("Cancel export") { departure.request() }.buttonStyle(CompactActionStyle())
                }
            }
            if let exportError { ErrorNote(message: exportError) }
        }
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
        .fullScreenCover(isPresented: $downloadGate) { MembershipView(exportRequired: true) }
        .onDisappear { exportTask?.cancel() }
    }

    private func shareExport(_ recording: PracticeRecording) {
        guard exportTask == nil else { return }
        guard commerce.canExportMedia else { downloadGate = true; return }
        exportError = nil
        exportTask = Task {
            defer { exportTask = nil }
            do {
                let url = try await library.shareFile(for: recording, commerce: commerce)
                if !Task.isCancelled { sharing = SharedFile(url: url) }
            } catch is CancellationError { }
            catch { exportError = error.localizedDescription }
        }
    }

    private func startExport() {
        guard exportTask == nil else { return }
        guard commerce.canExportMedia else { downloadGate = true; return }
        if !clip.playbackURL.isFileURL, offline.cached(clip.id) == nil,
           !quota.mayDownload(clip.id, premium: commerce.premium) {
            downloadGate = true
            return
        }
        exportError = nil
        exportTask = Task { @MainActor in
            defer { exportTask = nil; preparingSource = false; departure.finish() }
            let owner = commerce.api.session?.userId.value
            var converted: URL?
            defer { if let converted { try? FileManager.default.removeItem(at: converted) } }
            do {
                preparingSource = true
                let source = try await offline.editableSource(for: clip)
                preparingSource = false
                var output = source
                if !["mp4", "mov", "m4v"].contains(source.pathExtension.lowercased()) {
                    let asset = AVURLAsset(url: source)
                    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
                          session.supportedFileTypes.contains(.mp4) else {
                        throw PulsePlayerError.service("This video format cannot be exported. Please use an MP4 or MOV file.")
                    }
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
                    converted = destination
                    session.outputURL = destination
                    session.outputFileType = .mp4
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { continuation in
                            session.exportAsynchronously { continuation.resume() }
                        }
                    } onCancel: { session.cancelExport() }
                    try Task.checkCancellation()
                    guard session.status == .completed else {
                        throw PulsePlayerError.service("Video export failed. Please try again.")
                    }
                    output = destination
                }
                try Task.checkCancellation()
                try commerce.requireMediaExport()
                let recording = try await library.importMovie(output, exported: true, title: clip.title) {
                    try commerce.requireMediaExport()
                    guard owner == commerce.api.session?.userId.value else { throw PulsePlayerError.unauthorized }
                }
                if !Task.isCancelled { savedExport = recording }
            } catch is CancellationError { }
            catch {
                exportError = error.localizedDescription
            }
        }
        departure.begin { exportTask?.cancel() }
    }
}

// Shared, live allowance display at the download decision and in the offline library.
struct DownloadAllowanceSummary: View {
    var onMedia = false
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var commerce: CommerceStore
    @State private var showingReward = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AllowanceStatusPanel(kinds: [.download], onMedia: onMedia)
            if quota.canRequestReward(for: .download, premium: commerce.premium) {
                if onMedia {
                    Button { showingReward = true } label: {
                        PlayerMenuRow(symbol: .play) { LocalizedText("Get more downloads") }
                    }
                    .buttonStyle(PressStyle())
                    .background(PulsePlayerStyle.onDark.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                } else {
                    ActionButton(title: "Get more downloads", primary: false) { showingReward = true }
                }
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .fullScreenCover(isPresented: $showingReward) { AllowanceLimitPrompt(kind: .download) }
    }
}
