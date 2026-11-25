import SwiftUI
import UIKit

struct FoldingDeskView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var commerce: CommerceStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var practice = FoldPracticeStore.shared
    let openPlus: () -> Void
    let browseVideos: () -> Void
    @Binding var importing: Bool
    @Binding var engaged: Bool
    @SceneStorage("home.linkDraft") private var link = ""
    @FocusState private var linkFocused: Bool
    @State private var linkError: String?
    @State private var destination: DeskDestination?
    @State private var editLinkAfterSearch = false
    @State private var deskSheet: DeskSheet?

    private enum DeskSheet: String, Identifiable {
        case starter, notebook, collections
        var id: Self { self }
    }

    private enum DeskDestination: Identifiable {
        case search(String)
        case player(PlayerRoute)
        var id: String {
            switch self {
            case .search(let value): "search-\(value)"
            case .player(let route): "player-\(route.id)"
            }
        }
    }

    private var collectionLinks: [String] { commerce.release?.lcList?["us"] ?? [] }

    var body: some View {
        ScenePage { container in
            let narrow = PulsePlayerStyle.pageContentWidth(in: container) < 310 || typeSize > .xLarge
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 10) {
                        SceneTitle("Folding desk", size: 34).fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        PlusEntryButton(action: openPlus)
                    }
                    VStack(alignment: .leading) {
                        SceneTitle("Folding desk", size: 34)
                        PlusEntryButton(action: openPlus)
                    }
                }

                let sessions = practice.recent(owner: api.offlineOwnerID, library: library, offline: offline)
                if let nextFold = sessions.first(where: { $0.finishedAt == nil }) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(title: "Continue folding").accessibilityAddTraits(.isHeader)
                        FoldPracticeRow(entry: nextFold, featured: true) {
                            guard let route = nextFold.route(library: library, offline: offline) else {
                                library.error = "This video file is no longer available."
                                return
                            }
                            linkFocused = false
                            destination = .player(route)
                        }
                    }
                } else {
                    starterLesson(stacked: narrow)
                }

                linkComposer.pulsePlayerKeepControlsTogether()
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: "Use your own video").accessibilityAddTraits(.isHeader)
                    VideoImportActions(onImported: practiceMovie, importing: $importing,
                                       presentation: .sourcePair(stacked: narrow))
                }
                VStack(alignment: .leading, spacing: 0) {
                    if !sessions.isEmpty {
                        LearningLink(symbol: .fold, title: "Practice notebook") {
                            linkFocused = false
                            deskSheet = .notebook
                        }
                        Divider()
                    }
                    LearningLink(symbol: .play, title: "Browse lessons") {
                        linkFocused = false
                        browseVideos()
                    }
                    if !collectionLinks.isEmpty {
                        Divider()
                        LearningLink(symbol: .library, title: "Video collections") {
                            linkFocused = false
                            deskSheet = .collections
                        }
                    }
                }
                if !library.history.isEmpty { searchHistory }
            }
        }
        .onChange(of: deskSheet != nil || destination != nil || linkFocused, initial: true) { _, value in
            engaged = value
        }
        .scrollDismissesKeyboard(.interactively)
        .dismissKeyboardOnOutsideTap($linkFocused, scope: "desk-link")
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
        .sheet(item: $deskSheet) { sheet in
            switch sheet {
            case .starter: FoldNotebookView(lessonFirst: true)
            case .notebook: FoldNotebookView()
            case .collections: VideoCollectionsView(links: collectionLinks)
            }
        }
        .onChange(of: library.listRequest) { _, request in
            if request != nil {
                deskSheet = nil
                destination = nil
            }
        }
    }

    private func starterLesson(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        return Button {
            linkFocused = false
            deskSheet = .starter
        } label: {
            layout {
                Image("PaperCranePreview.jpg").resizable().scaledToFill()
                    .frame(width: 94, height: 72).clipShape(.rect(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    LocalizedText("Fold a paper crane").font(.capture(.title3, weight: .semibold))
                    LocalizedText("Nine guided folds · Available offline")
                        .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(PulsePlayerStyle.raised, in: .rect(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).accessibilityIdentifier("desk.starterLesson")
    }

    private var linkComposer: some View {
        let hasLink = !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            LocalizedText("Start a folding lesson")
                .font(.capture(.title2, weight: .semibold)).accessibilityAddTraits(.isHeader)
            LocalizedText("Mark each fold in the video and replay it while you work.")
                .font(.capture(.subheadline)).foregroundStyle(PulsePlayerStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Video link or short code", text: $link)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($linkFocused).submitLabel(.go).onSubmit { openLink(link) }
                    .font(.capture(.body))
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityIdentifier("home.videoLink")
                    .onChange(of: link) { _, _ in linkError = nil }
                if !link.isEmpty {
                    IconButton(symbol: .close, label: "Clear link") { link = ""; linkFocused = true }
                }
            }
            .padding(.leading, 14).padding(.trailing, link.isEmpty ? 14 : 2)
            .frame(minHeight: 52)
            .background(PulsePlayerStyle.surface, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(linkFocused ? PulsePlayerStyle.accent : PulsePlayerStyle.line)
                    .allowsHitTesting(false)
            }
            if let linkError { ErrorNote(message: linkError) }
            let buttons = Group {
                Button(action: pasteLink) {
                    LocalizedText("Paste").font(.capture(.subheadline, weight: .semibold))
                        .padding(.horizontal, 14).frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(PulsePlayerStyle.accent)
                }.buttonStyle(PressStyle()).accessibilityIdentifier("home.pasteLink")
                Button { openLink(link) } label: {
                    LocalizedText("Open lesson").font(.capture(.headline, weight: .semibold))
                        .padding(.horizontal, 22).padding(.vertical, 6)
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(PulsePlayerStyle.paper)
                        .pulsePlayerGlass(in: Capsule(), tint: PulsePlayerStyle.accent.opacity(0.18), fallback: PulsePlayerStyle.mist)
                }
                .buttonStyle(PressStyle()).disabled(!hasLink || destination != nil)
                .accessibilityIdentifier("home.openLesson")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { buttons }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .trailing, spacing: 4) { buttons }
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .keyboardInputRegion("desk-link")
    }

    private func pasteLink() {
        guard let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            linkError = "Copy a video link or short code first."
            return
        }
        link = value
        linkError = nil
    }

    private func practiceMovie(_ movie: PracticeRecording) {
        guard let route = PlayerRoute.localMovies([movie], selected: movie, library: library) else {
            library.error = "This video file is no longer available."
            return
        }
        linkFocused = false
        destination = .player(route)
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

    private var searchHistory: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(title: "Recent links").accessibilityAddTraits(.isHeader)
            ForEach(library.history) { visit in
                HStack(spacing: 6) {
                    Button { openLink(visit.link) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: visit.title).font(.capture(.subheadline, weight: .medium))
                                .lineLimit(typeSize.isAccessibilitySize ? nil : 2).truncationMode(.middle)
                            LocalizedDateText(date: visit.date).font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(PressStyle())
                    IconButton(symbol: .close, label: "Remove history item") { library.removeVisit(visit) }
                }
                Divider()
            }
            Button("Clear search history", action: library.clearHistory)
                .buttonStyle(CompactActionStyle()).padding(.top, 6)
        }
    }
}

struct FoldPracticeRow: View {
    @Environment(\.locale) private var locale
    let entry: FoldPracticeEntry
    var featured = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: featured ? 10 : 6) {
                if entry.currentStepNumber > 0 {
                    LocalizedText("Fold %@ of %@", String(entry.currentStepNumber), String(entry.steps.count))
                        .font(.capture(.footnote, weight: .semibold)).foregroundStyle(PulsePlayerStyle.accent)
                }
                Text(verbatim: entry.clip.title)
                    .font(.capture(featured ? .title2 : .headline, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let name = entry.currentStep?.displayName(language: .from(locale)) {
                    Text(verbatim: name).font(.capture(.body)).foregroundStyle(PulsePlayerStyle.paper)
                }
                HStack(alignment: .center, spacing: 8) {
                    LocalizedText(entry.finishedAt == nil ? "Resume at %@" : "Review from %@",
                                  durationLabel(entry.resumeSeconds))
                        .font(.capture(.subheadline)).monospacedDigit()
                        .foregroundStyle(PulsePlayerStyle.secondary)
                    Spacer(minLength: 0)
                    Glyph(symbol: .play, size: 15, tint: PulsePlayerStyle.accent)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(featured ? 18 : 0)
            .padding(.vertical, featured ? 0 : 8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background {
                if featured { RoundedRectangle(cornerRadius: 16).fill(PulsePlayerStyle.raised) }
            }
            .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(featured ? "desk.resumeFold" : "library.resumeFold")
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
    @State private var returningToFiles = false

    var body: some View {
        ScenePage(depth: 48, openingGap: 0) { _ in
            SceneTitle("Browse videos", size: 26).padding(.leading, 54)
        } content: { _ in
            VStack(alignment: .leading, spacing: 14) {
                if api.session == nil {
                    ConnectionPanel(loadingTitle: "Connecting to the video service…")
                } else if loadedUserID != api.session?.userId.value {
                    AccountLoadingIndicator(title: "Loading videos…")
                } else if feed.entries.isEmpty {
                    EmptyStateScene(title: "No videos available")
                    if let error = feed.error { ErrorNote(message: error) }
                    ActionButton(title: "Try again", primary: false, busy: feed.loading) {
                        Task { await reload() }
                    }
                } else {
                    recommendations
                }
                LearningLink(symbol: .link, title: "Open video", titleColor: PulsePlayerStyle.secondary,
                             action: returnToLinkInput)
            }
        }
        .sceneDismiss(symbol: .back, label: "Back", edge: .leading) { dismiss() }
        .task(id: api.session?.userId.value) {
            if loadedUserID != api.session?.userId.value {
                player = nil
                await reload()
            }
        }
        .fullScreenCover(item: $player, onDismiss: {
            if returningToFiles { dismiss() }
        }) { route in
            PlayerScreen(route: route, feed: feed)
        }
        .onChange(of: library.listRequest) { _, request in
            guard request != nil else { return }
            if player == nil {
                dismiss()
            } else {
                returningToFiles = true
                player = nil
            }
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
    @State private var entries: [ChannelRoute] = []
    @State private var channel: ChannelRoute?
    @State private var loading = true
    @State private var error: String?
    @State private var retry = 0

    private struct Request: Equatable {
        let links: [String]
        let retry: Int
    }

    var body: some View {
        ScenePage(depth: 48, openingGap: 0) { _ in
            SceneTitle("Video collections", size: 26).padding(.leading, 54)
        } content: { _ in
            if loading {
                AccountLoadingIndicator(title: "Loading videos…")
            } else if let error {
                MessagePanel(title: "Couldn’t load collections", message: error, actionTitle: "Try again") {
                    retry += 1
                }
            } else if entries.isEmpty {
                EmptyStateScene(title: "No videos available")
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { route in
                        Button { channel = route } label: {
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
        .sceneDismiss(symbol: .back, label: "Back", edge: .leading) { dismiss() }
        .sheet(item: $channel) { ChannelView(route: $0) }
        .task(id: Request(links: links, retry: retry)) { await loadCollections() }
    }

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
        ScenePage(depth: 48, openingGap: 0) { _ in
            SceneTitle("Recently opened", size: 26)
                .padding(.leading, 54)
        } content: { _ in
            if history.isEmpty {
                EmptyStateScene(message: "No recent videos")
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(history) { video in
                        recentRow(video)
                        if video.id != history.last?.id {
                            Divider().overlay(PulsePlayerStyle.line).accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        .sceneDismiss(symbol: .back, label: "Back", edge: .leading) { dismiss() }
        .fullScreenCover(item: $player) { PlayerScreen(route: $0) }
    }

    @ViewBuilder private func recentRow(_ video: RecentVideo) -> some View {
        switch video {
        case .local(let movie):
            HStack(spacing: 4) {
                VideoFileButton(url: library.url(for: movie), filename: movie.displayFilename, date: video.date,
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
                IconButton(symbol: .edit, label: "Edit video") { edit(movie) }
                if movie.rangeMarks?.isEmpty == false {
                    IconButton(symbol: .bookmark, label: "Review saved ranges") { review(movie) }
                }
            }
        case .offline(let download):
            VideoFileButton(url: download.url, filename: download.displayFilename, date: video.date,
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
            HStack(spacing: 4) {
                VideoFileButton(url: offline.cached(visit.id)?.url ?? visit.clip.playbackURL,
                                filename: visit.clip.title, date: video.date, fallbackCover: visit.clip.coverURL) {
                    if api.session == nil, offline.cached(visit.id) == nil {
                        library.error = "Connect to replay this video."
                    } else {
                        let clip = offline.playable(visit.clip)
                        player = PlayerRoute(clips: [clip], startID: clip.id)
                    }
                }
                IconButton(symbol: .close, label: "Remove history item") { library.removeWatch(visit) }
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
            case .folder(let route): ChannelView(route: route)
            case .player(let route): PlayerScreen(route: route)
            case nil:
                ScenePage(depth: 48, openingGap: 0) { _ in
                    SceneTitle("Open video", size: 26).padding(.leading, 54)
                } content: { _ in
                    if let error {
                        MessagePanel(title: "Couldn’t open this link", message: error, actionTitle: "Try again") {
                            attempt += 1
                        }
                    } else {
                        AccountLoadingIndicator(title: "Finding video…")
                    }
                }
                .sceneDismiss(symbol: .back, label: "Back", edge: .leading) { dismiss() }
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

struct ChannelView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let route: ChannelRoute
    @State private var items: [RemoteLessonFile] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var child: ChannelRoute?
    @State private var player: PlayerRoute?
    private var emptyChannel: Bool { items.isEmpty && !loading && !hasMore && error == nil }

    var body: some View {
        ScenePage(depth: 64, openingGap: 0) { _ in
            Text(verbatim: route.title).font(.capture(.headline))
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                .padding(.trailing, 50)
        } content: { _ in
            LazyVStack(alignment: .leading, spacing: 14) {
                if emptyChannel {
                    EmptyStateScene(title: "No videos available")
                    EmptyStateAction(title: "Back", symbol: .back, primary: true) { dismiss() }
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
            .sceneDismiss { dismiss() }
            .task { if items.isEmpty { await load() } }
            .sheet(item: $child) { ChannelView(route: $0) }
            .fullScreenCover(item: $player) { PlayerScreen(route: $0, returningToChannel: route) }
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
            child = ChannelRoute(link: link, title: item.name ?? L10n.text("Folder"),
                                 coverURL: WebAddress.media(item.coverImage), videoCount: item.childrenFileNum)
        } else if let clip = item.clip(channel: route.title, sourceChannel: route) {
            player = PlayerRoute(clips: items.compactMap { $0.clip(channel: route.title, sourceChannel: route) },
                                 startID: clip.id, continuesRecommendations: true)
        } else { error = "This item does not contain a playable video." }
    }
}
