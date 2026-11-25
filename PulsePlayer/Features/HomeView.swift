import SwiftUI
import UIKit

enum SearchPage: Hashable {
    case notebook, collections, browse
    case channel(ChannelRoute)
    case foldExport(FoldPracticeEntry)
}

struct LessonSearchPage: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var commerce: CommerceStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.layoutDirection) private var direction
    @ObservedObject private var practice = FoldPracticeStore.shared
    let openPlus: () -> Void
    @Binding var importing: Bool
    @Binding var engaged: Bool
    @Binding var path: [SearchPage]

    @SceneStorage("home.linkDraft") private var link = ""
    @FocusState private var linkFocused: Bool
    @State private var linkError: String?
    @State private var destination: Destination?
    @State private var editLinkAfterSearch = false
    @State private var showsAllRecent = false
    @State private var editingHistory = false

    private enum Destination: Identifiable {
        case search(String)
        case player(PlayerRoute)
        var id: String {
            switch self {
            case .search(let value): "search-\(value)"
            case .player(let route): "player-\(route.id)"
            }
        }
    }

    private var query: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var collectionLinks: [String] { commerce.release?.lcList?["us"] ?? [] }
    private var sessions: [FoldPracticeEntry] {
        practice.recent(owner: api.offlineOwnerID, library: library, offline: offline)
            .filter { $0.removedFromContinueWatching != true }
    }

    var body: some View {
        GeometryReader { viewport in
            let width = PulsePlayerStyle.pageContentWidth(in: viewport)
            let stacked = width < 310 || typeSize.isAccessibilitySize
            ScenePage(scrollsBehindTabBar: true) { page in
                let divided = PulsePlayerStyle.intersectsReservedRegion(CGRect(origin: .zero, size: page.size), in: page)
                let sideBySide = width >= 600 && !divided && !typeSize.isAccessibilitySize
                VStack(alignment: .leading, spacing: 20) {
                    searchActions
                    let recent = sessions
                    let entry = recent.first(where: { $0.finishedAt == nil }) ?? recent.first
                    if entry == nil && library.history.isEmpty && library.error == nil && !practice.needsLoadRetry {
                        emptySearch(compact: linkFocused || typeSize.isAccessibilitySize || page.size.height < 380,
                                    availableHeight: page.size.height)
                    } else {
                        let layout = sideBySide ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                                                : AnyLayout(VStackLayout(alignment: .leading, spacing: 22))
                        layout {
                            if !library.history.isEmpty { recentLinks }
                            if !linkFocused || library.history.isEmpty { videoShelf(entry: entry) }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer(stacked: stacked)
                    .pulsePlayerKeepControlsTogether()
                    .pageHorizontalMargins()
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
        .pulsePlayerScreenBackground()
        .onChange(of: destination != nil || linkFocused || editingHistory, initial: true) { _, value in engaged = value }
        .onChange(of: library.history.count) { _, count in
            if count <= 3 { showsAllRecent = false }
            if count == 0 { editingHistory = false }
        }
        .onChange(of: linkFocused) { _, focused in
            if focused { editingHistory = false }
        }
        .onDisappear { editingHistory = false }
        .scrollDismissesKeyboard(.interactively)
        .dismissKeyboardOnOutsideTap($linkFocused, scope: "lesson-search")
        .fullScreenCover(item: $destination, onDismiss: {
            if editLinkAfterSearch {
                editLinkAfterSearch = false
                linkFocused = true
            }
        }) { route in
            switch route {
            case .search(let query):
                DiscoverView(initialSearch: query, canDismiss: true, returnToLinkInput: {
                    editLinkAfterSearch = true
                    destination = nil
                })
            case .player(let route):
                PlayerScreen(route: route)
            }
        }
        .navigationDestination(for: SearchPage.self) { page in
            Group {
                switch page {
                case .browse:
                    BrowseVideoListView {
                        path.removeAll()
                        linkFocused = true
                    }
                case .notebook: FoldNotebookView(openExport: { path.append(.foldExport($0)) })
                case .foldExport(let entry): FoldClipExportView(entry: entry)
                case .collections: VideoCollectionsView(links: collectionLinks, openChannel: { path.append(.channel($0)) })
                case .channel(let route): ChannelView(route: route, openChild: { path.append(.channel($0)) })
                }
            }
            .toolbar(.hidden, for: .navigationBar, .tabBar)
        }
        .onChange(of: library.listRequest) { _, request in
            if request != nil {
                editLinkAfterSearch = false
                linkFocused = false
                path.removeAll()
                destination = nil
            }
        }
    }

    private var searchActions: some View {
        HStack(spacing: 8) {
            VideoImportActions(onImported: practiceMovie, importing: $importing, presentation: .menu(title: "Import"))
            Spacer(minLength: 8)
            GlassActionMenu(title: "Shortcuts", items: searchShortcuts) {
                TintedArtwork(name: "PlayerMore", tint: PulsePlayerStyle.accent)
                    .frame(width: 19, height: 19)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(LocalizedStringKey("More"))
        }
        .pulsePlayerKeepControlsTogether()
    }

    private var searchShortcuts: [ActionMenuItem] {
        var items = [ActionMenuItem("Practice notebook", .fold) { linkFocused = false; path.append(.notebook) }]
        if !collectionLinks.isEmpty {
            items.append(ActionMenuItem("Video collections", .library) { linkFocused = false; path.append(.collections) })
        }
        items.append(ActionMenuItem("PulsePlayer Plus", .pass) { linkFocused = false; openPlus() })
        return items
    }

    private func emptySearch(compact: Bool, availableHeight: CGFloat) -> some View {
        VStack(spacing: compact ? 8 : 14) {
            Image(decorative: "LaunchMark").resizable().scaledToFit()
                .frame(width: compact ? 32 : 66, height: compact ? 32 : 66)
            LocalizedText("No recent links")
                .font(.capture(.title3, weight: .semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            browseButton
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: compact ? 0 : availableHeight * 0.76)
        .pulsePlayerKeepControlsTogether()
    }

    private var browseButton: some View {
        Button {
            linkFocused = false
            path.append(.browse)
        } label: {
            LocalizedText("Browse videos")
                .font(.capture(.subheadline, weight: .semibold))
                .foregroundStyle(PulsePlayerStyle.accent)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18).frame(minHeight: 44)
                .pulsePlayerGlass(in: Capsule(), tint: PulsePlayerStyle.accent.opacity(0.08),
                                  fallback: PulsePlayerStyle.mist)
        }
        .buttonStyle(PressStyle())
    }

    private func videoShelf(entry: FoldPracticeEntry?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let entry {
                ResumeVideoRow(entry: entry, open: { openPractice(entry) }, remove: {
                    do { try practice.removeFromContinueWatching(entry.id) }
                    catch { library.error = error.localizedDescription }
                })
            } else if practice.needsLoadRetry, let message = practice.error {
                ErrorNote(message: message)
                Button("Try again", action: practice.retryLoading).buttonStyle(CompactActionStyle())
            }
            browseButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pulsePlayerKeepControlsTogether()
    }

    private func composer(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 4))
        return VStack(alignment: .leading, spacing: 4) {
            if let linkError { ErrorNote(message: linkError) }
            layout {
                HStack(spacing: 8) {
                    Glyph(symbol: .search, size: 18, tint: PulsePlayerStyle.accent)
                    TextField("Video link or short code", text: $link,
                              prompt: Text("Enter a link or code").foregroundStyle(PulsePlayerStyle.secondary))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($linkFocused).submitLabel(.go).onSubmit { openLink(link) }
                        .font(.capture(.body))
                        .foregroundStyle(PulsePlayerStyle.paper)
                        .environment(\.layoutDirection, query.isEmpty ? direction : .leftToRight)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityLabel(LocalizedStringKey("Video link or short code"))
                        .accessibilityIdentifier("home.videoLink")
                        .onChange(of: link) { _, _ in linkError = nil }
                    if !link.isEmpty {
                        IconButton(symbol: .close, label: "Clear link") { link = ""; linkFocused = true }
                    }
                }
                if query.isEmpty {
                    Button(action: pasteAndOpen) {
                        LocalizedText("Paste & open")
                            .font(.capture(.subheadline, weight: .semibold))
                            .foregroundStyle(PulsePlayerStyle.accent)
                            .padding(.horizontal, 8).frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityIdentifier("home.pasteLink")
                } else {
                    Button { openLink(link) } label: {
                        Glyph(symbol: .play, size: 16, tint: .white)
                            .frame(width: 44, height: 44)
                            .background(PulsePlayerStyle.accent, in: Circle())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel(LocalizedStringKey("Open video"))
                    .accessibilityIdentifier("home.openLesson")
                }
            }
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 4)
            .pulsePlayerGlass(in: .rect(cornerRadius: 20), fallback: PulsePlayerStyle.surface, interactive: false)
            .disabled(destination != nil || importing)
        }
        .keyboardInputRegion("lesson-search")
    }

    private var recentLinks: some View {
        let filtering = linkFocused && !query.isEmpty
        let matches = filtering ? library.history.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.link.localizedCaseInsensitiveContains(query)
        } : library.history
        let expanded = editingHistory || showsAllRecent || linkFocused
        let visible = matches.prefix(expanded ? matches.count : 3)
        let header = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 8))
        return VStack(alignment: .leading, spacing: 6) {
            header {
                LocalizedText("Recent links")
                    .font(.capture(.headline))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    if editingHistory {
                        Button(role: .destructive, action: library.clearHistory) {
                            LocalizedText("Clear all")
                                .font(.capture(.subheadline, weight: .medium))
                                .foregroundStyle(PulsePlayerStyle.danger)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(PressStyle())
                        .accessibilityLabel(LocalizedStringKey("Clear search history"))
                        .accessibilityIdentifier("search.clearHistory")
                    }
                    Button {
                        linkFocused = false
                        editingHistory.toggle()
                    } label: {
                        LocalizedText(editingHistory ? "Done" : "Edit")
                            .font(.capture(.subheadline, weight: .semibold))
                            .foregroundStyle(PulsePlayerStyle.accent)
                            .padding(.horizontal, 12).frame(minHeight: 32)
                            .pulsePlayerGlass(in: Capsule(), fallback: PulsePlayerStyle.mist)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityIdentifier("search.editHistory")
                }
            }
            .pulsePlayerKeepControlsTogether()

            if matches.isEmpty {
                EmptyStateScene(appearance: .inline(.search), title: "No matches in recent links")
                Button("Clear search") {
                    link = ""
                    linkError = nil
                    linkFocused = true
                }
                .buttonStyle(CompactActionStyle())
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { visit in
                        historyRow(visit)
                        if visit.id != visible.last?.id {
                            Divider().padding(.leading, 48).accessibilityHidden(true)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(PulsePlayerStyle.surface, in: .rect(cornerRadius: 16))
            }

            if library.history.count > 3 && !editingHistory && !linkFocused {
                Button { showsAllRecent.toggle() } label: {
                    LocalizedText(showsAllRecent ? "Show less" : "Show all links")
                        .font(.capture(.footnote, weight: .semibold))
                        .foregroundStyle(PulsePlayerStyle.accent)
                        .frame(minHeight: 44)
                }
                .buttonStyle(PressStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func historyRow(_ visit: LessonLinkVisit) -> some View {
        let label = HStack(spacing: 10) {
            Glyph(symbol: .link, size: 16, tint: PulsePlayerStyle.accent)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(verbatim: visit.title)
                .font(.capture(.subheadline, weight: .medium))
                .foregroundStyle(PulsePlayerStyle.paper)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                .truncationMode(.middle).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        return HStack(spacing: 4) {
            if editingHistory {
                label
                Button(role: .destructive) { library.removeVisit(visit) } label: {
                    Glyph(symbol: .close, size: 11, tint: PulsePlayerStyle.danger)
                        .frame(width: 24, height: 24)
                        .background(PulsePlayerStyle.danger.opacity(0.08), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(LocalizedStringKey("Remove history item"))
                .accessibilityValue(Text(verbatim: visit.title))
            } else {
                Button { openLink(visit.link) } label: {
                    HStack(spacing: 6) {
                        label
                        Glyph(symbol: .play, size: 12, tint: PulsePlayerStyle.secondary)
                            .frame(width: 44)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 48).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityHint(LocalizedStringKey("Open video"))
            }
        }
        .frame(minHeight: 48)
        .pulsePlayerKeepControlsTogether()
    }

    private func pasteAndOpen() {
        guard let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            linkError = "Copy a video link or short code first."
            return
        }
        openLink(value)
    }

    private func openLink(_ value: String) {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, destination == nil else { return }
        link = query
        linkError = nil
        linkFocused = false
        library.recordSearch(query)
        destination = .search(query)
    }

    private func openPractice(_ entry: FoldPracticeEntry) {
        guard let route = entry.route(library: library, offline: offline) else {
            library.error = "This video file is no longer available."
            return
        }
        linkFocused = false
        destination = .player(route)
    }

    private func practiceMovie(_ movie: PracticeRecording) {
        guard let route = PlayerRoute.localMovies([movie], selected: movie, library: library) else {
            library.error = "This video file is no longer available."
            return
        }
        linkFocused = false
        destination = .player(route)
    }
}

private struct ResumeVideoRow: View {
    let entry: FoldPracticeEntry
    let open: () -> Void
    let remove: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var quota: QuotaStore

    private var title: String {
        let raw = entry.clip.title as NSString
        let extensions = ["mp4", "mov", "m4v", "webm", "mkv", "avi"]
        return extensions.contains(raw.pathExtension.lowercased()) ? raw.deletingPathExtension : entry.clip.title
    }

    var body: some View {
        let heading = entry.finishedAt == nil ? "Continue watching" : "Watch again"
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        VStack(alignment: .leading, spacing: 2) {
            layout {
                LocalizedText(heading)
                    .font(.capture(.headline)).accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: remove) {
                    LocalizedText("Remove")
                        .font(.capture(.footnote, weight: .semibold))
                        .foregroundStyle(PulsePlayerStyle.secondary)
                        .padding(.horizontal, 10).frame(minHeight: 28)
                        .pulsePlayerGlass(in: Capsule(), fallback: PulsePlayerStyle.mist)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityValue(Text(verbatim: title))
                .accessibilityIdentifier("desk.removeResumeVideo")
            }
            Button(action: open) {
                layout {
                    FoldPracticeThumbnail(entry: entry)
                        .frame(width: 76, height: 64)
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay(alignment: .bottomTrailing) {
                            Glyph(symbol: .play, size: 10, tint: .white)
                                .frame(width: 24, height: 24)
                                .background(PulsePlayerStyle.mediaBackdrop.opacity(0.82), in: Circle())
                                .padding(4)
                        }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: title)
                            .font(.capture(.subheadline, weight: .semibold))
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                            .multilineTextAlignment(.leading)
                        if let name = entry.currentStep?.displayName(language: .from(locale))?.nilIfBlank {
                            Text(verbatim: name).font(.capture(.footnote))
                                .foregroundStyle(PulsePlayerStyle.secondary)
                        }
                        LocalizedText("Resume at %@", durationLabel(entry.resumeSeconds))
                            .font(.capture(.footnote, weight: .medium)).monospacedDigit()
                            .foregroundStyle(PulsePlayerStyle.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(PulsePlayerStyle.surface, in: .rect(cornerRadius: 16))
                .contentShape(.rect(cornerRadius: 16))
            }
            .buttonStyle(PressStyle())
            .accessibilityHint(LocalizedStringKey(heading))
            .accessibilityIdentifier("desk.resumeFold")
            allowanceNotice
        }
    }

    @ViewBuilder private var allowanceNotice: some View {
        if case let .lesson(_, owner, clipID) = entry.id, owner == api.session?.userId.value,
           clipID == entry.clip.id, !entry.clip.playbackURL.isFileURL, offline.cached(clipID) == nil {
            TimelineView(.everyMinute) { clock in
                let access = quota.watchAccess(to: clipID, premium: commerce.premium, owner: owner, at: clock.date)
                if access == .oneView || !access.canOpen {
                    LocalizedText(access.rawValue).font(.capture(.footnote))
                        .foregroundStyle(PulsePlayerStyle.secondary).padding(.top, 4)
                }
            }
        }
    }
}

struct BrowseVideoListView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    let returnToLinkInput: () -> Void
    @StateObject private var feed = FeedStore()
    @State private var loadedUserID: String?
    @State private var player: PlayerRoute?

    var body: some View {
        ScenePage { _ in
            VStack(alignment: .leading, spacing: 14) {
                if api.session == nil {
                    ConnectionPanel(loadingTitle: "Connecting to the video service…")
                } else if loadedUserID != api.session?.userId.value {
                    AccountLoadingIndicator(title: "Loading videos…")
                } else if feed.entries.isEmpty {
                    if feed.loading {
                        AccountLoadingIndicator(title: "Loading videos…")
                    } else {
                        if let error = feed.error {
                            ErrorNote(message: error)
                        } else {
                            EmptyStateScene(appearance: .screening(.feed), title: "No videos available")
                        }
                        ActionButton(title: "Try again", primary: false) {
                            Task { await reload() }
                        }
                    }
                } else {
                    recommendations
                }
                LearningLink(symbol: .link, title: "Open video", titleColor: PulsePlayerStyle.secondary,
                             action: returnToLinkInput)
            }
        }
        .sceneBack(context: "Browse videos") { dismiss() }
        .task(id: api.session?.userId.value) {
            if loadedUserID != api.session?.userId.value {
                player = nil
                await reload()
            }
        }
        .fullScreenCover(item: $player) { route in
            PlayerScreen(route: route, feed: feed)
        }
        .onChange(of: library.listRequest) { _, request in
            if request != nil { player = nil }
        }
    }

    private var recommendations: some View {
        var seen = Set<String>()
        let visible = feed.entries.filter { seen.insert($0.clip.id).inserted }
        return LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(visible) { entry in
                Button {
                    player = PlayerRoute(clips: feed.clips, startID: entry.id, continuesRecommendations: true)
                } label: {
                    HStack(spacing: 12) {
                        MediaCover(url: entry.clip.coverURL)
                            .frame(width: 88, height: 56).clipShape(.rect(cornerRadius: 8))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: entry.clip.title).font(.capture(.subheadline, weight: .semibold))
                            if let channel = entry.clip.channel.nilIfBlank {
                                Text(verbatim: channel).font(.capture(.footnote))
                                    .foregroundStyle(PulsePlayerStyle.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Glyph(symbol: .play, size: 16, tint: PulsePlayerStyle.accent)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
            if let error = feed.error { ErrorNote(message: error) }
            if feed.hasMore || feed.error != nil {
                ActionButton(title: feed.error == nil ? "Load more" : "Try again", primary: false, busy: feed.loading) {
                    Task { await feed.load(api: api) }
                }
            }
        }
    }

    private func reload() async {
        guard let userID = api.session?.userId.value else { return }
        await feed.load(api: api, search: "")
        guard !Task.isCancelled, api.session?.userId.value == userID else { return }
        loadedUserID = userID
    }
}

private struct VideoCollectionsView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let links: [String]
    let openChannel: (ChannelRoute) -> Void
    @State private var entries: [ChannelRoute] = []
    @State private var loading = true
    @State private var error: String?
    @State private var retry = 0

    @State private var completedRequest: Request?

    private struct Request: Equatable {
        let owner: String?
        let links: [String]
        let retry: Int
    }

    var body: some View {
        ScenePage { _ in
            if loading {
                AccountLoadingIndicator(title: "Loading videos…")
            } else if let error {
                MessagePanel(title: "Couldn’t load collections", message: error, actionTitle: "Try again") {
                    retry += 1
                }
            } else if entries.isEmpty {
                EmptyStateScene(appearance: .shelf(.library), title: "No videos available")
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { route in
                        Button { openChannel(route) } label: {
                            HStack(spacing: 12) {
                                MediaCover(url: route.coverURL, folder: true)
                                    .frame(width: 70, height: 48).clipShape(.rect(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: route.title).font(.capture(.subheadline, weight: .semibold))
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let count = route.videoCount {
                                        LocalizedText("\(count) videos").font(.capture(.caption))
                                            .foregroundStyle(PulsePlayerStyle.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Glyph(symbol: .back, size: 12, tint: PulsePlayerStyle.secondary).rotationEffect(.degrees(180))
                            }
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }.buttonStyle(PressStyle())
                    }
                }
            }
        }
        .sceneBack(context: "Video collections") { dismiss() }
        .task(id: request) {
            let current = request
            guard completedRequest != current else { return }
            await loadCollections()
            if !Task.isCancelled { completedRequest = current }
        }
    }

    private var request: Request { Request(owner: api.session?.userId.value, links: links, retry: retry) }

    private func loadCollections() async {
        loading = true
        error = nil
        entries = []
        do {
            let channels = try await api.channels(links: links)
            try Task.checkCancellation()
            var seen = Set<String>()
            entries = channels.compactMap { item in
                guard let info = item.extraInfo, let title = info.channelName?.nilIfBlank,
                      let link = info.externalLinks?.nilIfBlank, seen.insert(link).inserted else { return nil }
                return item.collectionRoute(link: link, title: title)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct VideoHistoryView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var offline: OfflineStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let browseVideos: () -> Void
    let edit: (PracticeRecording) -> Void
    let review: (PracticeRecording) -> Void
    @ObservedObject private var resume = LocalPlaybackResume.shared
    @State private var player: PlayerRoute?

    private var videoHistory: [RecentVideo] {
        let local = library.movies.filter { $0.lastOpenedAt != nil && !$0.isAudio }.map(RecentVideo.local)
        let downloads = offline.videos.filter { $0.lastOpenedAt != nil }.map(RecentVideo.offline)
        let online = library.watchedVideos(for: api.offlineOwnerID).map(RecentVideo.online)
        let ordered = (local + downloads + online).sorted { $0.date > $1.date }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        let history = videoHistory
        ScenePage { _ in
            if history.isEmpty {
                VStack(spacing: 14) {
                    EmptyStateScene(appearance: .screening(.play), title: "No recent videos")
                    Button(action: browseVideos) { LocalizedText("Browse videos") }
                        .buttonStyle(CompactActionStyle())
                }
                .pulsePlayerKeepControlsTogether()
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(history) { video in
                        recentRow(video, featured: video.id == history.first?.id)
                        if video.id != history.last?.id {
                            Divider().overlay(PulsePlayerStyle.line).accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        .sceneBack(context: "Recently opened") { dismiss() }
        .fullScreenCover(item: $player) { PlayerScreen(route: $0) }
    }

    private func recentRow(_ video: RecentVideo, featured: Bool) -> some View {
        let layout = featured ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                              : AnyLayout(HStackLayout(spacing: 4))
        let presentation: VideoFileButton.Presentation = featured ? .featured : .row
        return layout {
            switch video {
            case .local(let movie):
                VideoFileButton(url: library.url(for: movie), filename: movie.displayFilename, date: video.date, presentation: presentation,
                                detail: watchDetail(resume.position(for: movie))) {
                    let movies = videoHistory.compactMap { entry -> PracticeRecording? in
                        if case .local(let movie) = entry { return movie }
                        return nil
                    }
                    guard let route = PlayerRoute.localMovies(movies, selected: movie, library: library) else {
                        library.error = "This video file is no longer available."
                        return
                    }
                    player = route
                }
                HStack(spacing: 4) {
                    IconButton(symbol: .edit, label: "Edit video", glass: featured) { edit(movie) }
                    if movie.rangeMarks?.isEmpty == false {
                        IconButton(symbol: .bookmark, label: "Review saved ranges", glass: featured) { review(movie) }
                    }
                }
            case .offline(let download):
                VideoFileButton(url: download.url, filename: download.displayFilename, date: video.date, presentation: presentation,
                            fallbackCover: download.clip.coverURL,
                            detail: watchDetail(resume.position(for: download))) {
                    guard offline.cached(download.id) != nil else {
                        offline.error = "This download is no longer on this device. Download it again."
                        library.openDownloads()
                        return
                    }
                    let clip = offline.playable(download.clip)
                    player = PlayerRoute(clips: [clip], startID: clip.id)
                }
            case .online(let visit):
                VideoFileButton(url: offline.cached(visit.id)?.url ?? visit.clip.playbackURL,
                                filename: visit.clip.title, date: video.date, presentation: presentation, fallbackCover: visit.clip.coverURL) {
                    if api.session == nil, offline.cached(visit.id) == nil {
                        library.error = "Connect to replay this video."
                    } else {
                        let clip = offline.playable(visit.clip)
                        player = PlayerRoute(clips: [clip], startID: clip.id)
                    }
                }
                IconButton(symbol: .close, label: "Remove history item", glass: featured) { library.removeWatch(visit) }
            }
        }
    }

    private func watchDetail(_ position: LocalPlaybackPosition?) -> String? {
        guard let position else { return nil }
        let progress = position.fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        return L10n.format("Watched %@", [progress], language: AppLanguage.from(locale))
    }
}

private enum RecentVideo: Identifiable {
    case local(PracticeRecording), offline(OfflineVideo), online(WatchedVideo)

    var id: String {
        switch self {
        case .local(let movie): "file-\(movie.id.uuidString)"
        case .offline(let download): "remote-\(download.id)"
        case .online(let visit): "remote-\(visit.id)"
        }
    }

    var date: Date {
        switch self {
        case .local(let movie): movie.lastOpenedAt ?? movie.date
        case .offline(let download): download.lastOpenedAt ?? .distantPast
        case .online(let visit): visit.date
        }
    }
}

private struct LearningLink: View {
    let symbol: PulsePlayerGlyph
    let title: String
    var detail: String? = nil
    var titleColor = PulsePlayerStyle.paper
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Glyph(symbol: symbol, size: 18, tint: PulsePlayerStyle.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    LocalizedText(title).font(.capture(.subheadline, weight: .semibold))
                    if let detail {
                        LocalizedText(detail).font(.capture(.footnote))
                            .foregroundStyle(PulsePlayerStyle.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Glyph(symbol: .back, size: 13, tint: PulsePlayerStyle.secondary).rotationEffect(.degrees(180))
            }
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .foregroundStyle(titleColor)
            .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }
}

struct LoginLandingView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let link: LoginLandingLink

    private enum Destination {
        case folder(ChannelRoute)
        case player(PlayerRoute)
    }

    @State private var destination: Destination?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            switch destination {
            case .folder(let route): ChannelBrowser(route: route)
            case .player(let route): PlayerScreen(route: route)
            case nil:
                ScenePage { _ in
                    if let error {
                        MessagePanel(title: "Couldn’t open this link", message: error, actionTitle: "Try again") {
                            attempt += 1
                        }
                    } else {
                        AccountLoadingIndicator(title: "Finding video…")
                    }
                }
                .sceneBack(context: "Open video") { dismiss() }
            }
        }
        .task(id: attempt) { await resolve() }
        .onChange(of: api.session?.userId.value, initial: true) { _, owner in
            if owner != link.owner { dismiss() }
        }
    }

    private func resolve() async {
        guard destination == nil, api.session?.userId.value == link.owner else { return }
        error = nil
        do {
            let info = try await api.resolve(link.code, password: "", expectedOwner: ServiceID(link.owner))
            try Task.checkCancellation()
            guard api.session?.userId.value == link.owner else { return }
            guard let file = info.netDiskInfo else {
                throw PulsePlayerError.service("No video was returned. Check the link and try again later.")
            }
            let channel = info.extraInfo?.channelName?.nilIfBlank
            if file.isFolder == true {
                let title = file.name?.nilIfBlank ?? channel ?? L10n.text("Folder")
                destination = .folder(info.collectionRoute(link: link.code, title: title))
            } else {
                guard let clip = file.clip(channel: channel ?? "", fallbackLink: link.code,
                                           fallbackTitle: channel ?? L10n.text("Untitled clip"),
                                           sourceChannel: info.parentChannel(forVideoLink: link.code)) else {
                    throw PulsePlayerError.service("This item does not contain a playable video.")
                }
                destination = .player(PlayerRoute(clips: [clip], startID: clip.id, continuesRecommendations: true))
            }
        } catch {
            guard !Task.isCancelled, api.session?.userId.value == link.owner else { return }
            self.error = error.localizedDescription
        }
    }
}

struct ChannelBrowser: View {
    let route: ChannelRoute
    @Environment(\.dismiss) private var dismiss
    @State private var path: [ChannelRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ChannelView(route: route, close: { dismiss() }, openChild: { path.append($0) })
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: ChannelRoute.self) { child in
                    ChannelView(route: child, openChild: { path.append($0) })
                        .toolbar(.hidden, for: .navigationBar)
                }
        }
    }
}

struct ChannelView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let route: ChannelRoute
    var close: (() -> Void)? = nil
    let openChild: (ChannelRoute) -> Void
    @State private var items: [RemoteLessonFile] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var player: PlayerRoute?
    private var emptyChannel: Bool { items.isEmpty && !loading && !hasMore && error == nil }

    var body: some View {
        ScenePage { _ in
            LazyVStack(alignment: .leading, spacing: 14) {
                if emptyChannel {
                    EmptyStateScene(appearance: .shelf(.folder), title: "No videos available")
                    EmptyStateAction(title: "Back", symbol: .back, primary: true) { leaveChannel() }
                }
                ForEach(items, id: \.stableID) { item in
                    Button { open(item) } label: {
                        HStack(spacing: 16) {
                            MediaCover(url: WebAddress.media(item.coverImage), folder: item.isFolder == true)
                                .frame(width: 80, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 7) {
                                Text(verbatim: item.name ?? L10n.text("Untitled")).font(.capture(.headline)).lineLimit(3)
                                LocalizedText(item.isFolder == true ? "\(item.childrenFileNum ?? 0) videos" : durationLabel(item.length ?? 0))
                                    .font(.caption.monospacedDigit()).foregroundStyle(PulsePlayerStyle.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Glyph(symbol: item.isFolder == true ? .folder : .play, size: 18, tint: PulsePlayerStyle.accent)
                        }.contentShape(Rectangle())
                    }.buttonStyle(PressStyle())
                }
                if let error { ErrorNote(message: error) }
                if hasMore {
                    let title = loading ? "Loading videos…" : error == nil ? "Load more" : "Try again"
                    ActionButton(title: title, primary: false) { Task { await load() } }
                        .disabled(loading)
                }
            }
        }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    if close == nil {
                        IconButton(symbol: .back, label: "Back", glass: true) { dismiss() }
                    }
                    Text(verbatim: route.title)
                        .font(.capture(.subheadline)).foregroundStyle(PulsePlayerStyle.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let close {
                        IconButton(symbol: .close, label: "Close", glass: true, action: close)
                    }
                }
                .pulsePlayerKeepControlsTogether()
                .pageHorizontalMargins().padding(.top, 6)
            }
            .task { if items.isEmpty { await load() } }
            .fullScreenCover(item: $player) { PlayerScreen(route: $0, returningToChannel: route) }
    }
    private func leaveChannel() {
        if let close { close() } else { dismiss() }
    }

    private func load() async {
        guard !loading, hasMore else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result = try await api.channelPage(link: route.link, page: page)
            var seen = Set(items.map(\.stableID))
            items += result.list.filter { $0.name?.nilIfBlank != nil && !$0.stableID.isEmpty && seen.insert($0.stableID).inserted }
            hasMore = page * 20 < result.total && !result.list.isEmpty
            page += 1
        } catch { self.error = error.localizedDescription }
    }
    private func open(_ item: RemoteLessonFile) {
        if item.isFolder == true, let link = item.landingPage?.nilIfBlank {
            let folder = ChannelRoute(link: link, title: item.name ?? L10n.text("Folder"),
                                      coverURL: WebAddress.media(item.coverImage), videoCount: item.childrenFileNum)
            openChild(folder)
        } else if let clip = item.clip(channel: route.title, sourceChannel: route) {
            player = PlayerRoute(clips: items.compactMap { $0.clip(channel: route.title, sourceChannel: route) },
                                 startID: clip.id, continuesRecommendations: true)
        } else { error = "This item does not contain a playable video." }
    }
}
