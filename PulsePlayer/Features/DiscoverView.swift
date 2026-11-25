import OSLog
import SwiftUI

struct BrowserLessonSearch: Equatable {
    let query: String
    var url: URL? {
        var address = URLComponents(string: "https://www.google.com/search")
        address?.queryItems = [URLQueryItem(name: "q", value: query)]
        // Search engines treat an unescaped plus sign as a space.
        if let encoded = address?.percentEncodedQuery {
            address?.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
        }
        return address?.url
    }
}

@MainActor
final class FeedStore: ObservableObject {
    @Published private(set) var entries: [PlaybackQueueEntry]
    @Published private(set) var loading = false
    @Published private(set) var hasMore = true
    @Published var error: String?
    @Published private(set) var emptySearch: BrowserLessonSearch?
    var clips: [LessonClip] { entries.map(\.clip) }
    private var feedID: String?
    private var cursor: String?
    private var roundVideoIDs = Set<String>()
    private var requestQuery = ""
    private var query = ""
    private var generation = UUID()
    private let diagnostics = Logger(subsystem: "app.pulseplayer", category: "LessonFeed")

    init(seed: [LessonClip] = []) {
        entries = seed.map { PlaybackQueueEntry(id: $0.id, clip: $0) }
        hasMore = seed.isEmpty
    }

    func invalidatePendingLoad() {
        generation = UUID()
        loading = false
    }

    func replaceMedia(_ refreshed: LessonClip) {
        for index in entries.indices where entries[index].clip.id == refreshed.id {
            let original = entries[index]
            entries[index] = PlaybackQueueEntry(id: original.id, clip: refreshed)
        }
    }

    func isNearEnd(_ id: String?) -> Bool {
        guard let id, let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        return index >= entries.count - 3
    }

    func load(api: APIClient, search: String? = nil) async {
        if let search {
            generation = UUID()
            entries = []; feedID = nil; cursor = nil; hasMore = true; loading = false
            query = search; requestQuery = search; roundVideoIDs = []
            emptySearch = nil
        }
        guard !loading else { return }
        let current = generation
        loading = true
        error = nil
        defer { if generation == current { loading = false } }
        do {
            var sawInvalidMedia = false
            // Skip a few duplicate/invalid pages, but never spin on an empty service.
            for _ in 0..<3 {
                if !hasMore {
                    // Do not replace an unmatched explicit query with recommendations.
                    if entries.isEmpty, requestQuery.nilIfBlank != nil { break }
                    feedID = nil; cursor = nil; roundVideoIDs = []
                    requestQuery = "" // Finished search/collection -> fresh recommendation round.
                    hasMore = true
                }
                let previousCursor = cursor
                let response = try await api.feed(query: requestQuery, feedID: feedID, cursor: cursor)
                try Task.checkCancellation()
                guard current == generation else { return }
                let playable = response.list.compactMap(\.clip)
                let rejected = response.list.count - playable.count
                if rejected > 0 {
                    sawInvalidMedia = true
                    diagnostics.notice("Lesson feed discarded \(rejected) rows with missing IDs or unusable media addresses")
                }
                let additions = playable.filter { roundVideoIDs.insert($0.id).inserted }
                    .map { PlaybackQueueEntry(id: UUID().uuidString, clip: $0) }
                feedID = response.feedId?.nilIfBlank
                cursor = response.nextCursor?.nilIfBlank
                hasMore = response.hasMore && cursor != nil && cursor != previousCursor
                if !additions.isEmpty { entries += additions; return }
                if response.list.isEmpty {
                    hasMore = false
                    break
                }
            }
            if entries.isEmpty {
                if sawInvalidMedia {
                    error = query.nilIfBlank == nil ? "No playable videos were returned. Try again."
                                                  : "Check the link and try again."
                } else if requestQuery.nilIfBlank != nil {
                    emptySearch = BrowserLessonSearch(query: requestQuery)
                }
            }
            if !entries.isEmpty { error = "No more videos are available right now. Try again." }
        } catch is CancellationError {
            // Leaving a screen/search is not a service failure.
        } catch {
            if current == generation, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
struct DiscoverView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    private let canDismiss: Bool
    private let onExit: (() -> Void)?
    private let returnToLinkInput: (() -> Void)?
    @EnvironmentObject private var offline: OfflineStore
    private var displayEntries: [PlaybackQueueEntry] {
        feed.entries.map { PlaybackQueueEntry(id: $0.id, clip: offline.playable($0.clip)) }
    }
    private let morePageID = "recommendation-tail"
    @EnvironmentObject private var api: APIClient
    @StateObject private var feed = FeedStore()
    @StateObject private var players = PlaybackPool()
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""
    @State private var visible = false
    @State private var activeID: String?
    @State private var browserSearch: PolicyDocument?
    @State private var loadedUserID: String?
    init(initialSearch: String = "", canDismiss: Bool = false, onExit: (() -> Void)? = nil,
         returnToLinkInput: (() -> Void)? = nil) {
        self.canDismiss = canDismiss
        self.onExit = onExit
        self.returnToLinkInput = returnToLinkInput
        _search = State(initialValue: initialSearch)
    }
    var body: some View {
        let showsPlayback = api.session != nil && !feed.entries.isEmpty
        let exit: (() -> Void)? = canDismiss || onExit != nil ? exitPlayer : nil
        return Group {
            if showsPlayback {
                playerPages(exit: exit)
            } else {
                VStack(spacing: 0) {
                    PlayerHeader(exit: exit)
                    lessonStatusPage
                }
            }
        }.pulsePlayerScreenBackground(showsPlayback ? PulsePlayerStyle.mediaBackdrop : PulsePlayerStyle.background)
            .foregroundStyle(PulsePlayerStyle.paper)
            .preferredColorScheme(showsPlayback ? .dark : .light)
            .modifier(PlayerPagingAccess(entries: displayEntries, selectedID: $activeID, tailID: morePageID, players: players))
            .onChange(of: library.listRequest) { _, request in
                if request != nil { players.releaseAll(); if canDismiss { dismiss() } }
            }
            .onAppear { visible = true; players.update(entries: displayEntries, selectedID: activeID) }
            .task(id: api.session?.userId.value) { await loadInitialFeed() }
            .onChange(of: activeID) { _, id in
                if showsPlayback { players.update(entries: displayEntries, selectedID: id) }
                guard visible, api.session != nil,
                      id == morePageID || feed.isNearEnd(id) else { return }
                Task { guard visible else { return }; await feed.load(api: api) }
            }
            .onChange(of: feed.entries) { previous, entries in
                guard visible else { return }
                if activeID == morePageID, entries.count > previous.count {
                    activeID = entries[previous.count].id
                } else if !entries.contains(where: { $0.id == activeID }) { activeID = entries.first?.id }
                players.update(entries: displayEntries, selectedID: activeID)
            }
            .onDisappear { visible = false; feed.invalidatePendingLoad(); players.releaseAll() }
            .fullScreenCover(item: $browserSearch) { document in
                PolicyBrowser(document: document, webSearch: true)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { players.suspend() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in players.trimMemory() }
    }

    private func playerPages(exit: (() -> Void)?) -> some View {
        PlaybackPager(activeID: $activeID, exit: exit) { size, insets in
            ForEach(displayEntries) { entry in
                let clip = entry.clip
                Group {
                    if let playback = players.controllers[entry.id] {
                        ClipPage(clip: clip, active: activeID == entry.id,
                                 gesture: .forVideo(entry.id, in: feed.entries), safeInsets: insets,
                                 hasExitButton: exit != nil, playback: playback, replaceMedia: feed.replaceMedia,
                                 didStartPlaying: { players.prepareNext(after: entry.id) },
                                 didStopPlaying: { if activeID == entry.id { players.suspend() } },
                                 onSwipeExit: exitPlayer)
                    } else {
                        PlayerPoster(url: clip.coverURL)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipped().id(entry.id)
            }
            VStack(spacing: 16) {
                if let error = feed.error { ErrorNote(message: error) }
                ActionButton(title: feed.loading ? "Loading videos…" : feed.error == nil ? "Load more" : "Try again",
                             primary: false) { Task { await feed.load(api: api) } }
                    .disabled(feed.loading)
            }
            .padding(14)
            .pulsePlayerPanel(cornerRadius: 14)
            .environment(\.colorScheme, .light)
            .frame(maxWidth: 460)
            .pageHorizontalMargins()
            .frame(width: size.width, height: size.height)
            .clipped().id(morePageID)
        }
    }

    private var lessonStatusPage: some View {
        let ready = loadedUserID != nil && loadedUserID == api.session?.userId.value
        let empty = ready && feed.entries.isEmpty && !feed.loading && feed.error == nil
        return ScenePage { _ in
            if api.session == nil {
                ConnectionPanel(loadingTitle: "Connecting to the video service…")
            } else if feed.loading || !ready {
                HStack(spacing: 12) {
                    ProgressView().tint(PulsePlayerStyle.accent).accessibilityHidden(true)
                    LocalizedText(search.nilIfBlank == nil ? "Loading videos…" : "Finding video…")
                        .font(.capture(.subheadline))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .pulsePlayerPanel(cornerRadius: 14)
            } else if let error = feed.error {
                VStack(alignment: .leading, spacing: 12) {
                    MessagePanel(title: "Couldn’t load videos", message: error, actionTitle: "Try again") {
                        Task { await loadInitialFeed() }
                    }
                    if search.nilIfBlank != nil, let returnToLinkInput {
                        EmptyStateAction(title: "Edit link", symbol: .link, action: returnToLinkInput)
                    }
                }
            } else if empty {
                let request = feed.emptySearch
                VStack(alignment: .leading, spacing: 14) {
                    EmptyStateScene(title: request == nil ? "No videos available" : "No matching video",
                                    message: request == nil ? nil : "Check the link and try again.")
                    if request == nil {
                        EmptyStateAction(title: "Try again", symbol: .feed, primary: true) {
                            Task { await loadInitialFeed() }
                        }
                    }
                    if let returnToLinkInput {
                        EmptyStateAction(title: "Edit link", symbol: .link, primary: request != nil, action: returnToLinkInput)
                    }
                    if let request, WebAddress.media(request.query) == nil, WebAddress.landingCode(request.query) != nil {
                        EmptyStateAction(title: "Search in browser", symbol: .search, primary: returnToLinkInput == nil) {
                            openBrowserSearch(request)
                        }
                    }
                }
            }
        }
    }

    private func loadInitialFeed() async {
        loadedUserID = nil
        guard let userID = api.session?.userId.value else { return }
        await feed.load(api: api, search: search)
        guard !Task.isCancelled, api.session?.userId.value == userID else { return }
        loadedUserID = userID
        activeID = feed.entries.first?.id
    }

    private func openBrowserSearch(_ request: BrowserLessonSearch) {
        guard let url = request.url else { return }
        players.suspend()
        browserSearch = PolicyDocument(title: "Web search", url: url)
    }
    private func exitPlayer() {
        guard canDismiss || onExit != nil else { return }
        players.releaseAll()
        if let onExit { onExit() } else { dismiss() }
    }

}

struct PlayerScreen: View {
    @EnvironmentObject private var ads: RewardedAds
    @ObservedObject private var notebook = FoldPracticeStore.shared
    @State private var presentationID = UUID()
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let route: PlayerRoute
    private let returningToChannel: ChannelRoute?
    @State private var visible = false
    @State private var activeID: String?
    @StateObject private var feed: FeedStore
    @StateObject private var players = PlaybackPool()
    @Environment(\.scenePhase) private var scenePhase
    private let morePageID = "collection-recommendation-tail"
    private var displayEntries: [PlaybackQueueEntry] {
        feed.entries.compactMap { entry in
            let clip = entry.clip.playbackURL.isFileURL ? entry.clip : offline.playable(entry.clip)
            guard !clip.playbackURL.isFileURL || localPlaybackIdentity(for: clip, library: library, offline: offline) != nil else {
                return nil
            }
            return PlaybackQueueEntry(id: entry.id, clip: clip)
        }
    }
    init(route: PlayerRoute, feed: FeedStore? = nil, returningToChannel: ChannelRoute? = nil) {
        self.route = route
        self.returningToChannel = returningToChannel
        _activeID = State(initialValue: route.startID)
        _feed = StateObject(wrappedValue: feed ?? FeedStore(seed: route.clips))
    }
    var body: some View {
        let entries = displayEntries
        let isPracticing = entries.first(where: { $0.id == activeID }).flatMap {
            notebook.entry(for: notebook.identity(for: $0.clip, owner: api.offlineOwnerID))
        } != nil
        Group {
            if entries.isEmpty {
                VStack(spacing: 0) {
                    PlayerHeader(exit: exitPlayer)
                    ScenePage { _ in
                        EmptyStateScene(title: "Playback unavailable",
                                        message: "This video file is missing or unreadable. Open it again or download a new copy.")
                    }
                }
            } else {
                playerPages(entries)
            }
        }.pulsePlayerScreenBackground(entries.isEmpty ? PulsePlayerStyle.background : PulsePlayerStyle.mediaBackdrop)
            .foregroundStyle(PulsePlayerStyle.paper)
            .preferredColorScheme(entries.isEmpty ? .light : .dark)
            .onChange(of: library.listRequest) { _, request in if request != nil { exitPlayer() } }
            .onChange(of: api.offlineOwnerID) { previous, current in
                if previous != nil, previous != current, route.clips.contains(where: { $0.localMovieID == nil }) {
                    exitPlayer()
                }
            }
            .modifier(PlayerPagingAccess(entries: entries, selectedID: $activeID, tailID: morePageID, players: players))
            .onChange(of: isPracticing) { _, practicing in
                if visible { ads.setPracticeVisible(practicing, screen: presentationID) }
            }
            .onAppear {
                visible = true
                ads.setPracticeVisible(isPracticing, screen: presentationID)
                selectAvailableEntry(in: entries)
                players.update(entries: entries, selectedID: activeID)
                continueFeedIfNeeded(activeID)
            }
            .onChange(of: activeID) { _, id in
                players.update(entries: entries, selectedID: id)
                continueFeedIfNeeded(id)
            }
            .onChange(of: entries) { previous, entries in
                guard visible else { return }
                if activeID == morePageID, entries.count > previous.count {
                    let previousIDs = Set(previous.map(\.id))
                    activeID = entries.first(where: { !previousIDs.contains($0.id) })?.id ?? activeID
                } else {
                    selectAvailableEntry(in: entries)
                }
                players.update(entries: entries, selectedID: activeID)
            }
            .onDisappear {
                visible = false
                ads.setPracticeVisible(false, screen: presentationID)
                feed.invalidatePendingLoad()
                players.releaseAll()
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { players.suspend() } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in players.trimMemory() }
    }

    private func playerPages(_ entries: [PlaybackQueueEntry]) -> some View {
        let localPlaylist = entries.filter { $0.clip.playbackURL.isFileURL }
        return PlaybackPager(activeID: $activeID, exit: exitPlayer) { size, insets in
            ForEach(entries) { entry in
                let clip = entry.clip
                Group {
                    if let playback = players.controllers[entry.id] {
                        ClipPage(clip: clip, active: activeID == entry.id,
                                 gesture: .forVideo(entry.id, in: entries), safeInsets: insets,
                                 hasExitButton: true, playback: playback, replaceMedia: feed.replaceMedia,
                                 didStartPlaying: { players.prepareNext(after: entry.id) },
                                 didStopPlaying: { if activeID == entry.id { players.suspend() } },
                                 onSwipeExit: exitPlayer,
                                 localPlaylist: localPlaylist,
                                 playlistEntryID: entry.id,
                                 selectPlaylistEntry: { activeID = $0 },
                                 returningToChannel: returningToChannel)
                    } else { PlayerPoster(url: clip.coverURL) }
                }
                .frame(width: size.width, height: size.height)
                .clipped().id(entry.id)
            }
            if route.continuesRecommendations {
                VStack(spacing: 16) {
                    if let error = feed.error { ErrorNote(message: error) }
                    ActionButton(title: feed.loading ? "Loading videos…" : feed.error == nil ? "Load more" : "Try again",
                                 primary: false) { Task { await feed.load(api: api) } }
                        .disabled(feed.loading)
                }
                .padding(14)
                .pulsePlayerPanel(cornerRadius: 14)
                .environment(\.colorScheme, .light)
                .frame(maxWidth: 460)
                .pageHorizontalMargins()
                .frame(width: size.width, height: size.height)
                .clipped().id(morePageID)
            }
        }
    }

    private func selectAvailableEntry(in entries: [PlaybackQueueEntry]) {
        guard activeID != morePageID, !entries.contains(where: { $0.id == activeID }) else { return }
        activeID = entries.first?.id
    }
    private func exitPlayer() {
        players.releaseAll()
        dismiss()
    }
    private func continueFeedIfNeeded(_ id: String?) {
        guard visible, route.continuesRecommendations, id == morePageID || feed.isNearEnd(id) else { return }
        Task { guard visible else { return }; await feed.load(api: api) }
    }
}

private extension View {
    func inPlaybackFrame(_ frame: CGRect, direction: LayoutDirection, alignment: Alignment = .center) -> some View {
        let left: Edge.Set = direction == .rightToLeft ? .trailing : .leading
        let topLeft: Alignment = direction == .rightToLeft ? .topTrailing : .topLeading
        return self.frame(width: frame.width, height: frame.height, alignment: alignment)
            .padding(left, frame.minX).padding(.top, frame.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: topLeft)
    }
}

private enum PlayerTopControls {
    static let buttonSize: CGFloat = 44
    static let topInset: CGFloat = 8
    static let edgeInset: CGFloat = 12
    static let spacing: CGFloat = 8
    static let adjacentOffset = buttonSize + spacing
}

private struct PlaybackPager<Pages: View>: View {
    @Binding var activeID: String?
    let exit: (() -> Void)?
    @ViewBuilder var pages: (CGSize, EdgeInsets) -> Pages

    var body: some View {
        GeometryReader { safeViewport in
            GeometryReader { viewport in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        pages(viewport.size, safeViewport.safeAreaInsets)
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $activeID, anchor: .top)
                .scrollIndicators(.hidden)
                .clipped()
            }
            .ignoresSafeArea(.container)
        }
        .overlay(alignment: .top) {
            PlayerHeader(exit: exit, overMedia: true)
                .padding(.top, PlayerTopControls.topInset)
        }
    }
}

@MainActor
private func localPlaybackIdentity(for clip: LessonClip, library: LibraryStore,
                                   offline: OfflineStore) -> LocalPlaybackIdentity? {
    guard clip.playbackURL.isFileURL else { return nil }
    let url = clip.playbackURL.standardizedFileURL
    if let id = clip.localMovieID {
        guard let movie = library.movies.first(where: { $0.id == id }),
              library.url(for: movie).standardizedFileURL == url,
              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return .movie(id)
    }
    guard let video = offline.cached(clip.id), video.url.standardizedFileURL == url else { return nil }
    return .download(owner: video.owner, id: video.id)
}

private struct PlaybackGateKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var playbackGatePresented: Bool {
        get { self[PlaybackGateKey.self] }
        set { self[PlaybackGateKey.self] = newValue }
    }
}

// Enforce admission at the paging boundary, so denied pages cannot strand the
// user on a succession of unplayable videos. Returning to admitted clips is free.
private struct PlayerPagingAccess: ViewModifier {
    let entries: [PlaybackQueueEntry]
    @Binding var selectedID: String?
    let tailID: String
    @ObservedObject var players: PlaybackPool
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var commerce: CommerceStore
    @State private var admittedID: String?
    @State private var requestedID: String?
    @State private var showingWatchOptions = false
    @State private var promptedOnOpen = false
    @State private var swipeOrigin: String?
    @State private var trackingSwipe = false
    @State private var swipeEnded: UUID?
    @AppStorage(PlayerGesture.swipeHintKey) private var completedHint = false

    private var watchRewardEligible: Bool {
        quota.canRequestReward(for: .watch, premium: commerce.premium)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.playbackGatePresented, showingWatchOptions)
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { value in
                guard !showingWatchOptions, abs(value.translation.height) > abs(value.translation.width) else { return }
                if !trackingSwipe { trackingSwipe = true; swipeOrigin = admittedID; swipeEnded = nil }
            }.onEnded { _ in swipeEnded = UUID() })
            .task(id: swipeEnded) {
                guard swipeEnded != nil else { return }
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                trackingSwipe = false; swipeOrigin = nil
            }
            .onAppear { admit(selectedID) }
            .onChange(of: selectedID) { _, value in admit(value) }
            .onChange(of: watchRewardEligible) { _, eligible in
                if eligible { admit(selectedID) }
            }
            .fullScreenCover(isPresented: $showingWatchOptions, onDismiss: finishWatchOptions) {
                AllowanceLimitPrompt(kind: .watch)
            }
    }
    private func canWatch(_ id: String) -> Bool {
        guard let clip = entries.first(where: { $0.id == id })?.clip else { return false }
        return clip.playbackURL.isFileURL || quota.mayWatch(clip.id, premium: commerce.premium)
    }
    private func admit(_ id: String?) {
        guard !showingWatchOptions, let id else { return }
        if let admittedID, !entries.contains(where: { $0.id == admittedID }) { self.admittedID = nil }
        let isTail = id == tailID
        guard isTail || entries.contains(where: { $0.id == id }) else { return }
        // Release an unfinished attempt before checking the next video's allowance.
        if let admittedID, admittedID != id { players.controllers[admittedID]?.pause() }
        if isTail { quota.resetIfNeeded() }
        if canWatch(id) || (isTail && !watchRewardEligible) {
            if !isTail {
                if trackingSwipe, let swipeOrigin, swipeOrigin != id, admittedID != id {
                    completedHint = true
                }
                admittedID = id
            }
            return
        }
        players.controllers.values.forEach { $0.pause() }
        players.suspend()
        if let admittedID, admittedID != id {
            // A new deliberate swipe may prompt again; dismissal itself never does.
            if watchRewardEligible {
                requestedID = id
                showingWatchOptions = true
            }
            selectedID = admittedID
        } else {
            admittedID = id
            if watchRewardEligible, !promptedOnOpen {
                promptedOnOpen = true
                requestedID = id
                showingWatchOptions = true
            }
        }
    }

    private func finishWatchOptions() {
        guard let requestedID else { return }
        self.requestedID = nil
        quota.resetIfNeeded()
        if canWatch(requestedID) || (requestedID == tailID && !watchRewardEligible) {
            selectedID = requestedID
        }
    }
}

struct AllowanceLimitPrompt: View {
    private static let maximumWidth: CGFloat = 352
    let kind: AllowanceKind
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var ads: RewardedAds
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @AccessibilityFocusState private var titleFocused: Bool
    @State private var showingPlans = false
    @State private var adAttempt: AdAttempt?
    @State private var adTask: Task<Void, Never>?
    @State private var adUnavailable = false

    private struct AdAttempt {
        let previousCompletion: UUID?
        let previousNotice: UUID?
    }

    private var rewardNotice: LuckyRewardNotice? {
        guard let adAttempt, let notice = ads.luckyReward, notice.id != adAttempt.previousNotice else { return nil }
        return notice
    }
    private var canContinue: Bool {
        quota.error == nil && (commerce.premium || quota.isUnlimited(kind) || quota.remaining(kind) > 0)
    }
    private var rewardEligible: Bool {
        quota.canRequestReward(for: kind, premium: commerce.premium)
    }
    private var canStartAd: Bool {
        rewardEligible && !ads.busy && !ads.isPresenting && !ads.isPreparingAppOpen
    }
    private var title: String {
        if rewardNotice != nil { return "No ad available" }
        if canContinue {
            return kind == .watch ? "Your viewing allowance has been updated." : "Your download allowance has been updated."
        }
        guard rewardEligible else {
            return quota.error ?? "Your connection is not ready. Please try again shortly."
        }
        return kind == .watch ? "Daily view limit reached" : "Daily download limit reached"
    }

    var body: some View {
        Group {
            if showingPlans {
                MembershipView()
            } else {
                dialog
            }
        }
        .presentationBackground(.clear)
        .onChange(of: ads.completedReward) { _, completion in
            guard let adAttempt, let completion, completion != adAttempt.previousCompletion else { return }
            close()
        }
        .onDisappear {
            if !ads.isPresenting { cancelAdRequest() }
        }
    }

    private var dialog: some View {
        GeometryReader { container in
            let area = visibleArea(in: container)
            ScrollView {
                PulsePlayerGlassGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 8) {
                            LocalizedText(title)
                                .font(.capture(.title3, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityFocused($titleFocused)
                            IconButton(symbol: .close, label: "Close", glass: true, action: close)
                                .disabled(ads.isPresenting)
                        }
                        choices
                    }
                }
                .foregroundStyle(PulsePlayerStyle.paper)
                .environment(\.colorScheme, .light)
                .padding(16)
                .frame(maxWidth: Self.maximumWidth)
                .pulsePlayerPanel(cornerRadius: 24)
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: area.height)
            }
            .frame(width: area.width, height: area.height)
            .padding(.leading, area.minX).padding(.top, area.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.black.opacity(0.62).ignoresSafeArea())
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { if !ads.isPresenting { close() } }
        .onAppear { titleFocused = true }
    }

    @ViewBuilder private var choices: some View {
        let notice = rewardNotice
        if notice != nil || canContinue {
            if let notice {
                LocalizedText(notice.message).font(.capture(.subheadline))
                    .foregroundStyle(PulsePlayerStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ActionButton(title: kind == .watch ? "Continue watching" : "Close", action: close)
                .disabled(ads.isPresenting)
        } else if rewardEligible {
            let language = AppLanguage.from(locale)
            let loadingAd = adAttempt != nil && ads.busy
            choiceButton(L10n.text("View Plus plans", language: language), primary: true) {
                cancelAdRequest()
                showingPlans = true
            }
            .disabled(ads.isPresenting)
            .accessibilityIdentifier(kind == .watch ? "watchLimit.viewPlans" : "downloadLimit.viewPlans")

            choiceButton(rewardTitle(language: language), symbol: .play, loading: loadingAd, action: requestAd)
                .accessibilityValue(Text(verbatim: loadingAd ? L10n.text("Loading ad…", language: language) : ""))
                .disabled(!canStartAd)
                .accessibilityIdentifier(kind == .watch ? "watchLimit.watchAd" : "downloadLimit.watchAd")
            if adAttempt != nil, !ads.busy, !ads.isPresenting {
                if let error = ads.error {
                    ErrorNote(message: error)
                } else if let message = ads.message ?? (adUnavailable ? "No ad available" : nil) {
                    LocalizedText(message).font(.capture(.footnote))
                        .foregroundStyle(PulsePlayerStyle.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            ActionButton(title: "Close", action: close)
                .disabled(ads.isPresenting)
        }
    }

    private func choiceButton(_ title: String, symbol: PulsePlayerGlyph? = nil, primary: Bool = false,
                              loading: Bool = false, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button(action: action) {
            HStack(spacing: 12) {
                if let symbol {
                    Group {
                        if loading {
                            ProgressView().tint(PulsePlayerStyle.accent)
                        } else {
                            Glyph(symbol: symbol, size: 17, tint: PulsePlayerStyle.accent)
                        }
                    }.frame(width: 22).accessibilityHidden(true)
                }
                Text(verbatim: title).font(.capture(primary ? .headline : .subheadline, weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(minHeight: primary ? 54 : 50)
            .foregroundStyle(primary ? PulsePlayerStyle.ink : PulsePlayerStyle.paper)
            .background(primary ? PulsePlayerStyle.accent : PulsePlayerStyle.raised, in: shape)
            .contentShape(.interaction, shape)
        }
        .buttonStyle(PressStyle())
    }

    private func rewardTitle(language: AppLanguage) -> String {
        if quota.completedAds(kind) >= 3 {
            return L10n.text(kind == .watch ? "Watch an ad for unlimited views today" : "Watch an ad for unlimited downloads today",
                             language: language)
        }
        let count = quota.rewardCount(for: kind).formatted(.number.locale(locale))
        return L10n.format(kind == .watch ? "Watch an ad for %@ more views" : "Watch an ad for %@ more downloads",
                           [count], language: language)
    }

    private func requestAd() {
        guard canStartAd else { return }
        adTask?.cancel()
        let attempt = AdAttempt(previousCompletion: ads.completedReward, previousNotice: ads.luckyReward?.id)
        adAttempt = attempt
        adUnavailable = false
        adTask = Task {
            await ads.watch(commerce: commerce, quota: quota, kind: kind)
            guard !Task.isCancelled else { return }
            adTask = nil
            adUnavailable = !ads.isPresenting && rewardNotice == nil && ads.completedReward == attempt.previousCompletion
        }
    }

    private func cancelAdRequest() {
        if rewardNotice != nil { ads.luckyReward = nil }
        if let adTask {
            adTask.cancel()
            ads.cancelRewardLoading()
        }
        adTask = nil
        adAttempt = nil
    }

    private func close() {
        cancelAdRequest()
        dismiss()
    }

    private func visibleArea(in container: GeometryProxy) -> CGRect {
        var area = CGRect(origin: .zero, size: container.size)
        guard #available(iOS 27.1, *) else { return area }
        let regions = container.reservedRegions(kind: .occlusion) + container.reservedRegions(kind: .division)
        for region in regions where region.isActive {
            let width = min(Self.maximumWidth, area.width)
            let column = CGRect(x: area.midX - width / 2, y: area.minY, width: width, height: area.height)
            let obstruction = area.intersection(region.frame)
            guard !obstruction.isEmpty, column.intersects(obstruction) else { continue }
            let pane = PulsePlayerStyle.largestPane(in: area, excluding: obstruction)
            if !pane.isEmpty { area = pane }
        }
        return area
    }
}

private enum PlayerGesture: Equatable {
    case swipeUp, swipeDown, tapForControls

    static let swipeHintKey = "foldot.player.completedSwipeHint.v7"

    static func forVideo(_ id: String, in entries: [PlaybackQueueEntry]) -> Self {
        guard entries.count > 1 else { return .tapForControls }
        return entries.last?.id == id ? .swipeDown : .swipeUp
    }

    var isSwipe: Bool { self != .tapForControls }

    var title: String {
        switch self {
        case .swipeUp: "Swipe up for the next video"
        case .swipeDown: "Swipe down for the previous video"
        case .tapForControls: "Tap the video to show or hide controls"
        }
    }
}

private struct PlayerGestureHint: View {
    let eligible: Bool
    let gesture: PlayerGesture
    @AppStorage(PlayerGesture.swipeHintKey) private var completedSwipe = false
    @AppStorage("foldot.player.completedControlsHint.v1") private var completedControls = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showing = false

    var body: some View {
        let available = eligible && !completedSwipe && (gesture.isSwipe || !completedControls)
        let showsHint = available && showing
        ZStack {
            if showsHint {
                HStack(spacing: 10) {
                    PlayerGestureArtwork(gesture: gesture)
                    LocalizedText(gesture.title)
                        .font(.capture(gesture.isSwipe ? .subheadline : .caption, weight: .semibold))
                        .foregroundStyle(PulsePlayerStyle.onDark)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .pulsePlayerGlass(in: RoundedRectangle(cornerRadius: 16), tint: PulsePlayerStyle.mediaBackdrop.opacity(0.82),
                            fallback: PulsePlayerStyle.mediaSurface, interactive: false, onDark: true)
                .frame(maxWidth: 320)
                .padding(.horizontal, 12).padding(.bottom, 16)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showsHint)
        .task(id: available ? gesture : nil) {
            showing = false
            guard available else { return }
            do {
                try await Task.sleep(for: .milliseconds(400))
                try Task.checkCancellation()
                showing = true
                try await Task.sleep(for: .seconds(6))
                try Task.checkCancellation()
            } catch { return }
            showing = false
            if gesture.isSwipe { completedSwipe = true }
            else { completedControls = true }
        }
    }
}

private struct PlayerGestureArtwork: View {
    let gesture: PlayerGesture
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var demonstrating = false

    var body: some View {
        let moved = demonstrating && !reduceMotion
        Group {
            if gesture.isSwipe {
                let up = gesture == .swipeUp
                TintedArtwork(name: PulsePlayerGlyph.back.assetName, tint: PulsePlayerStyle.onDark)
                    .frame(width: 22, height: 22)
                    .rotationEffect(.degrees(up ? 90 : -90))
                    .offset(y: moved ? (up ? -5 : 5) : (up ? 5 : -5))
            } else {
                TintedArtwork(name: "PlayerMore", tint: PulsePlayerStyle.onDark)
                    .frame(width: 20, height: 20)
                    .scaleEffect(moved ? 0.84 : 1)
            }
        }
        .frame(width: 24, height: 32)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.65).repeatCount(4, autoreverses: true)) {
                demonstrating = true
            }
        }
    }
}

private enum PlayerOptions: String, Identifiable {
    case speed, more, folds
    var id: String { rawValue }
}

private struct ClipPage: View {
    private static let panelCornerRadius: CGFloat = 26
    private static let panelTint = PulsePlayerStyle.mediaBackdrop.opacity(0.69)
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var ads: RewardedAds
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var phase
    @Environment(\.playbackGatePresented) private var pagingGate
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AppStorage(LocalPlaybackResume.enabledKey) private var resumesLocalPlayback = true
    @AppStorage(LocalPlaybackPreferences.speedKey) private var defaultLocalSpeed = 1.0
    @AppStorage(LocalPlaybackPreferences.loopKey) private var loopsLocalPlayback = false
    let clip: LessonClip
    let active: Bool
    let gesture: PlayerGesture
    let safeInsets: EdgeInsets
    let hasExitButton: Bool
    @ObservedObject var playback: PlaybackController
    let replaceMedia: (LessonClip) -> Void
    var didStartPlaying: () -> Void = {}
    var didStopPlaying: () -> Void = {}
    var onSwipeExit: () -> Void = {}
    var localPlaylist: [PlaybackQueueEntry] = []
    var playlistEntryID: String? = nil
    var selectPlaylistEntry: (String) -> Void = { _ in }
    var returningToChannel: ChannelRoute? = nil
    @State private var visible = false
    @State private var firstFrameReady = false
    @State private var accessChecked = false
    @State private var resumeAfterSheet = false
    @State private var resumeAfterInterruption = false
    @State private var showingWatchOptions = false
    @State private var options: PlayerOptions?
    @State private var editorAfterOptions = false
    @State private var playlistEntryAfterOptions: String?
    @State private var showsFolderOptions = false
    @State private var folderMoveError: String?
    @State private var editor = false
    @State private var channelAfterTools: ChannelRoute?
    @State private var recorded = false
    @State private var allowed = false
    @State private var scrubbing = false
    @GestureState private var draggingDock = false
    @State private var controlsHidden = false
    @State private var controlsActivity = 0
    @State private var dockContentHeight: CGFloat = 136
    @State private var retryRequest: UUID?
    @State private var favoriteError: String?
    @State private var presentedSource: ChannelRoute?
    @State private var sourceResult: (lookup: SourceLookup, channel: ChannelRoute?)?

    private struct SourceLookup: Equatable {
        let owner: ServiceID
        let videoLink: String
    }

    private var localMovie: PracticeRecording? {
        guard let id = clip.localMovieID else { return nil }
        return library.movies.first { $0.id == id }
    }

    private var localIdentity: LocalPlaybackIdentity? {
        localPlaybackIdentity(for: clip, library: library, offline: offline)
    }

    private var foldID: FoldPracticeID? {
        FoldPracticeStore.shared.identity(for: clip, owner: commerce.api.offlineOwnerID)
    }

    private var foldSource: LessonClip {
        if clip.localMovieID == nil, clip.playbackURL.isFileURL, let cached = offline.cached(clip.id) {
            return cached.clip
        }
        return clipWithSource
    }

    private var sourceLookup: SourceLookup? {
        guard clip.sourceChannel == nil, clip.localMovieID == nil,
              let owner = commerce.api.session?.userId,
              let link = clip.shortLink.flatMap({ WebAddress.landingCode($0) }) else { return nil }
        return SourceLookup(owner: owner, videoLink: link)
    }

    private var channelSource: ChannelRoute? {
        if let source = clip.sourceChannel { return source }
        guard let sourceResult, sourceResult.lookup == sourceLookup else { return nil }
        return sourceResult.channel
    }

    private var clipWithSource: LessonClip {
        var updated = clip
        updated.sourceChannel = channelSource
        return updated
    }

    private var librarySource: (list: LibraryList, title: String, videoCount: Int?)? {
        let language = AppLanguage.from(locale)
        if let movie = localMovie {
            if let folder = library.folders.first(where: { $0.id == movie.folderID }) {
                return (.folder(folder.id), folder.name, library.movies(in: folder).filter { !$0.isAudio }.count)
            }
            return movie.isExport ? (.exports, L10n.text("Exports", language: language), nil)
                                  : (.imports, L10n.text("Imports", language: language), nil)
        }
        if clip.playbackURL.isFileURL, offline.cached(clip.id) != nil {
            return (.offline, L10n.text("Offline", language: language), nil)
        }
        if library.isSaved(clip) { return (.favorites, L10n.text("Favorites", language: language), nil) }
        return nil
    }

    private var hasOpenPanel: Bool {
        showingWatchOptions || options != nil || editor || presentedSource != nil
    }
    private var canControlPlayback: Bool {
        active && allowed && firstFrameReady && phase == .active && !ads.isPresenting
            && !pagingGate && !hasOpenPanel
    }
    private var showsPlaybackFeedback: Bool { active && visible && !pagingGate && !hasOpenPanel }
    private var canHideControls: Bool {
        visible && canControlPlayback && playback.intendsPlayback && playback.error == nil
            && !scrubbing && !draggingDock && favoriteError == nil && !voiceOverEnabled
    }
    private var controlsAreHidden: Bool { controlsHidden && canHideControls }
    private var canAutoHideControls: Bool { canHideControls && playback.isPlaying && !playback.isLoading }

    var body: some View {
        playerViewport
            .foregroundStyle(PulsePlayerStyle.paper)
            .clipped()
            .onAppear { visible = true; if active { activate() } }
            .onChange(of: active) { _, active in
                resumeAfterInterruption = false
                if active {
                    activate()
                } else {
                    firstFrameReady = false
                    scrubbing = false
                    favoriteError = nil
                    resumeAfterSheet = false
                    playback.pause()
                    if playback.foldGuide != nil { playback.stopRepeating() }
                }
            }
            .task(id: retryRequest) {
                guard let request = retryRequest else { return }
                await retryFailedPlayback()
                if request == retryRequest { retryRequest = nil }
            }
            .onChange(of: playback.error) { _, error in if error != nil { scrubbing = false } }
            .onChange(of: canHideControls) { _, canHide in
                if !canHide { controlsHidden = false }
            }
            .task(id: canAutoHideControls && !controlsAreHidden ? controlsActivity : nil) {
                guard canAutoHideControls, !controlsAreHidden else { return }
                do {
                    try await Task.sleep(for: .seconds(3))
                    try Task.checkCancellation()
                } catch { return }
                if canAutoHideControls { setControlsHidden(true) }
            }
            .onChange(of: playback.isPlaying) { _, playing in
                if playing, active, visible, allowed, !recorded {
                    recorded = true
                    if let localMovie {
                        library.markOpened(localMovie)
                    } else if clip.playbackURL.isFileURL {
                        offline.markOpened(clip.id)
                    } else if let owner = commerce.api.session?.userId.value {
                        library.recordWatch(clipWithSource, owner: owner)
                    }
                }
                if playing, active, recorded { didStartPlaying() }
                if !playing, active { didStopPlaying() }
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                guard active, visible, playback.isPlaying, !clip.playbackURL.isFileURL else { return }
                _ = authorizeOnlinePlayback()
            }
            .onChange(of: quota.watchesLeft) { before, after in
                if before == 0, after > 0, accessChecked, !allowed, playback.error == nil {
                    activate()
                }
            }
            .onChange(of: phase) { _, state in
                if state != .active { interruptPlayback() } else { resumeIfNeeded() }
            }
            .onChange(of: localIdentity) { _, identity in
                if clip.playbackURL.isFileURL && identity == nil { rejectUnavailableLocalFile() }
            }
            .onChange(of: defaultLocalSpeed) { _, _ in updateLocalPlaybackPreferences() }
            .onChange(of: loopsLocalPlayback) { _, _ in updateLocalPlaybackPreferences() }
            .onChange(of: clip.playbackURL) { _, _ in activate() }
            .onChange(of: ads.isPresenting) { _, presenting in
                if presenting { interruptPlayback() } else { resumeIfNeeded() }
            }
            .onDisappear { visible = false; resumeAfterInterruption = false; playback.pause() }
            .onChange(of: library.listRequest) { _, request in
                if request != nil {
                    editorAfterOptions = false
                    playlistEntryAfterOptions = nil
                    options = nil
                    channelAfterTools = nil
                    editor = false
                    presentedSource = nil
                }
            }
            .task(id: active && visible && phase == .active ? sourceLookup : nil) {
                guard active, visible, phase == .active, let sourceLookup else { return }
                await resolveSource(sourceLookup)
            }
            .onChange(of: showingWatchOptions) { _, presented in if presented { playback.pause() } }
            .onChange(of: pagingGate) { _, presented in
                if presented { playback.pause() } else if active { activate() }
            }
            .fullScreenCover(isPresented: $showingWatchOptions, onDismiss: { if active { activate() } }) {
                AllowanceLimitPrompt(kind: .watch)
            }
            .sheet(item: $options, onDismiss: finishOptions) { selection in
                playbackOptions(selection)
            }
            .sheet(item: $presentedSource, onDismiss: resumeAfterControls) { channel in
                ChannelView(route: channel).preferredColorScheme(.light)
            }
            .sheet(isPresented: $editor, onDismiss: resumeAfterControls) {
                EditorSheet(initialMovie: localMovie).preferredColorScheme(.light)
            }
    }
    private var playerViewport: some View {
        GeometryReader { viewport in
            let regions = playbackAreas(in: viewport)
            let stage = safeControls(in: regions.media, viewport: viewport)
            let otherPane = regions.dock.map { safeControls(in: $0, viewport: viewport) }
            let frames = practiceFrames(stage: stage, otherPane: otherPane)
            ZStack(alignment: .topLeading) {
                if active {
                    videoStage.inPlaybackFrame(frames.video, direction: layoutDirection)
                    playbackOverlay.inPlaybackFrame(frames.video, direction: layoutDirection, alignment: .center)
                    PlayerGestureHint(eligible: canHideControls, gesture: gesture)
                        .inPlaybackFrame(frames.video, direction: layoutDirection, alignment: .bottom)
                    if controlsAreHidden {
                        showControlsButton(in: stage, viewportWidth: viewport.size.width)
                    } else {
                        let height = min(dockContentHeight, max(0, frames.tools.height - 28))
                        playbackDock(height: height, width: frames.tools.width)
                            .inPlaybackFrame(frames.tools, direction: layoutDirection, alignment: .center)
                    }
                } else {
                    PlayerPoster(url: clip.coverURL).inPlaybackFrame(stage, direction: layoutDirection)
                }
            }
        }
    }

    private func practiceFrames(stage: CGRect, otherPane: CGRect?) -> (video: CGRect, tools: CGRect) {
        if let otherPane { return (stage, otherPane) }
        if controlsAreHidden { return (stage, .zero) }
        if stage.width >= 540, stage.width > stage.height * 1.2 {
            let sidebar = min(stage.width * 0.45, typeSize.isAccessibilitySize ? 380 : 320)
            let edge: CGRectEdge = layoutDirection == .rightToLeft ? .minXEdge : .maxXEdge
            let parts = stage.divided(atDistance: sidebar, from: edge)
            return (parts.remainder, parts.slice)
        }
        // Keep the complete sheet of paper visible. A portrait recording needs more
        // vertical space than a wide overhead shot, even on the same phone.
        let picture = playback.presentationSize
        let naturalHeight = picture.width > 0 && picture.height > 0
            ? stage.width * picture.height / picture.width : stage.height * 0.55
        let minimumVideo = stage.height * (typeSize.isAccessibilitySize ? 0.42 : 0.5)
        let videoGoal = min(max(naturalHeight, minimumVideo), stage.height * 0.72)
        let height = min(dockContentHeight + 28, max(0, stage.height - videoGoal))
        let parts = stage.divided(atDistance: height, from: .maxYEdge)
        return (parts.remainder, parts.slice)
    }

    private var videoStage: some View {
        ZStack {
            PulsePlayerStyle.mediaBackdrop
            VideoSurface(player: playback.player, fill: false, onReadyForDisplay: { firstFrameReady = $0 })
                .opacity(allowed ? 1 : 0)
                .allowsHitTesting(false)
            if !allowed || !firstFrameReady {
                PlayerPoster(url: clip.coverURL)
            }
            PlayerSurfaceGestures(tap: tapVideo, swipeLeft: swipeExit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
        .clipped()
    }

    private func tapVideo() {
        if controlsAreHidden {
            setControlsHidden(false)
        } else if canAutoHideControls {
            setControlsHidden(true)
        } else if !playback.intendsPlayback {
            togglePlayback()
        }
    }

    private func swipeExit() {
        guard active, visible, phase == .active, !ads.isPresenting,
              !pagingGate, !hasOpenPanel, !scrubbing else { return }
        onSwipeExit()
    }

    @ViewBuilder private var playbackOverlay: some View {
        if showsPlaybackFeedback, allowed, let error = playback.error {
            ViewThatFits(in: .vertical) {
                playbackFailure(error)
                ScrollView { playbackFailure(error) }
                    .scrollBounceBehavior(.basedOnSize)
            }
            .padding(.horizontal, 12).padding(.top, 52).padding(.bottom, 8)
            .frame(maxWidth: 420)
        } else if controlsAreHidden && playback.isLoading {
            PlayerLoadingFeedback(buffering: true, floating: true)
                .allowsHitTesting(false)
        }
    }

    private func showControlsButton(in area: CGRect, viewportWidth: CGFloat) -> some View {
        let size = PlayerTopControls.buttonSize
        let edge = PlayerTopControls.edgeInset
        let top = PlayerTopControls.topInset
        let spacing = PlayerTopControls.adjacentOffset
        let rightToLeft = layoutDirection == .rightToLeft
        let exitX = rightToLeft ? safeInsets.trailing + edge : viewportWidth - safeInsets.trailing - edge - size
        let moreX = rightToLeft ? area.minX + edge : area.maxX - edge - size
        let exit = CGRect(x: exitX, y: safeInsets.top + top, width: size, height: size)
        let more = CGRect(x: moreX, y: area.minY + top, width: size, height: size)
        let sharesCorner = hasExitButton && more.intersects(exit)
        let fitsBesideExit = area.width >= 2 * edge + size + spacing
        return Button { setControlsHidden(false) } label: {
            TintedArtwork(name: "PlayerMore", tint: PulsePlayerStyle.onDark)
                .frame(width: 20, height: 20)
                .frame(width: size, height: size)
                .pulsePlayerGlass(in: Capsule(), tint: PulsePlayerStyle.mediaBackdrop.opacity(0.65),
                            fallback: PulsePlayerStyle.mediaSurface, onDark: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(LocalizedStringKey("Show playback controls"))
        .accessibilityIdentifier("player.showControls")
        .inPlaybackFrame(CGRect(x: moreX + (sharesCorner && fitsBesideExit ? (rightToLeft ? spacing : -spacing) : 0),
                                y: more.minY + (sharesCorner && !fitsBesideExit ? spacing : 0),
                                width: size, height: size), direction: layoutDirection)
    }

    private func setControlsHidden(_ hidden: Bool) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { controlsHidden = hidden }
    }

    private func playbackFailure(_ error: String) -> some View {
        MessagePanel(title: "Couldn’t load video", message: error, actionTitle: "Try again") {
            if retryRequest == nil { retryRequest = UUID() }
        }
        .disabled(retryRequest != nil)
        .environment(\.colorScheme, .light)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func retryFailedPlayback() async {
        guard active, visible else { return }
        let api = commerce.api
        if !clip.playbackURL.isFileURL, let link = clip.shortLink.flatMap(WebAddress.landingCode),
           let owner = api.session?.userId {
            let result = try? await api.resolve(link, password: "", expectedOwner: owner)
            guard !Task.isCancelled, active, visible, api.session?.userId == owner else { return }
            if let refreshed = result?.netDiskInfo?.clip(channel: clip.channel, fallbackLink: link,
                                                        fallbackTitle: clip.title, sourceChannel: clip.sourceChannel),
               refreshed.id == clip.id, refreshed.playbackURL != clip.playbackURL {
                if let foldID { FoldPracticeStore.shared.refreshSource(refreshed, in: foldID) }
                replaceMedia(refreshed)
                return
            }
        }
        if !Task.isCancelled { activate(reload: true) }
    }

    private func playbackDock(height: CGFloat, width: CGFloat) -> some View {
        ScrollView {
            dockContent(narrow: width < 360 || typeSize.isAccessibilitySize)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded(.up) }) {
                    dockContentHeight = $0
                }
        }
        .frame(height: height)
        .scrollDisabled(dockContentHeight <= height)
        .scrollBounceBehavior(.basedOnSize)
        .simultaneousGesture(DragGesture(minimumDistance: 8).updating($draggingDock) { value, dragging, _ in
            if dockContentHeight > height, abs(value.translation.height) > abs(value.translation.width) {
                dragging = true
            }
        })
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: 620)
        .foregroundStyle(PulsePlayerStyle.onDark)
        .pulsePlayerGlass(in: RoundedRectangle(cornerRadius: Self.panelCornerRadius), tint: Self.panelTint,
                    fallback: PulsePlayerStyle.mediaSurface, interactive: false, onDark: true)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    private func dockContent(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            playbackFeedback
            if playback.error == nil { transport(narrow: narrow) }
            PlaybackFoldNavigation(videoTitle: clip.title, identity: foldID,
                                   enabled: canControlPlayback && playback.error == nil, jump: jumpToFold)
                .padding(.horizontal, 4)
            if let foldID {
                FoldPracticeControls(clip: foldSource, identity: foldID, playback: playback,
                                     enabled: canControlPlayback, didInteract: { controlsActivity += 1 },
                                     showSteps: { showOptions(.folds) })
            }
            Divider().overlay(PulsePlayerStyle.onDark.opacity(0.12))
            lessonSettings
        }
    }

    private func jumpToFold(_ id: FoldPracticeID, stepID: UUID) throws {
        guard canControlPlayback, playback.error == nil, foldID == id,
              playback.loadedURL == clip.playbackURL,
              let entry = FoldPracticeStore.shared.entry(for: id),
              let step = entry.steps.first(where: { $0.id == stepID }) else { return }
        controlsActivity += 1
        try FoldPracticeStore.shared.select(step, in: id, reopen: false)
        playback.stopRepeating()
        playback.seek(step.start)
    }

    @ViewBuilder private var playbackSourceLink: some View {
        if let channel = channelSource {
            sourceButton(title: channel.title, coverURL: channel.coverURL, videoCount: channel.videoCount) {
                channelAfterTools = channel
                options = nil
            }
        } else if let source = librarySource {
            sourceButton(title: source.title, coverURL: nil, videoCount: source.videoCount) {
                resumeAfterSheet = false
                options = nil
                library.openList(source.list)
            }
        } else if let channel = clip.channel.nilIfBlank {
            Text(verbatim: channel).font(.capture(.caption))
                .foregroundStyle(PulsePlayerStyle.mediaSecondary).lineLimit(1).padding(.horizontal, 4)
        }
    }

    private func sourceButton(title: String, coverURL: URL?, videoCount: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                MediaCover(url: coverURL, folder: true, onMedia: true)
                    .frame(width: 38, height: 32)
                    .clipShape(.rect(cornerRadius: 7))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.capture(.footnote, weight: .semibold))
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    if let videoCount, videoCount >= 0 {
                        LocalizedText("%@ videos", videoCount.formatted(.number.locale(locale)))
                            .font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.mediaSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Glyph(symbol: .back, size: 11, tint: PulsePlayerStyle.mediaSecondary).rotationEffect(.degrees(180))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(minHeight: 44)
            .background(PulsePlayerStyle.onDark.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityIdentifier("player.openSource")
        .disabled(!active || pagingGate || ads.isPresenting)
    }

    private func resolveSource(_ lookup: SourceLookup) async {
        guard sourceResult?.lookup != lookup else { return }
        let api = commerce.api
        let parent = try? await api.resolve(lookup.videoLink, password: "", expectedOwner: lookup.owner)
        guard !Task.isCancelled, sourceLookup == lookup else { return }
        var channel: ChannelRoute?
        if let parent = parent?.parentChannel(forVideoLink: lookup.videoLink),
           let folder = try? await api.resolve(parent.link, password: "", expectedOwner: lookup.owner),
           folder.netDiskInfo?.isFolder == true || folder.folderName?.nilIfBlank != nil {
            let title = folder.folderName?.nilIfBlank ?? folder.netDiskInfo?.name?.nilIfBlank
                ?? folder.extraInfo?.channelName?.nilIfBlank ?? parent.title
            var resolved = folder.collectionRoute(link: parent.link, title: title)
            resolved.videoCount = resolved.videoCount ?? parent.videoCount
            channel = resolved
        }
        guard !Task.isCancelled, sourceLookup == lookup else { return }
        sourceResult = (lookup, channel)
        if channel != nil, recorded, playback.isPlaying {
            library.recordWatch(clipWithSource, owner: lookup.owner.value)
        }
    }

    private func transport(narrow: Bool) -> some View {
        let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        return layout {
            HStack(spacing: 2) {
                if localIdentity != nil { skipButton(seconds: -10) }
                Button(action: togglePlayback) {
                    Glyph(symbol: playback.intendsPlayback ? .pause : .play, size: 19,
                          tint: PulsePlayerStyle.mediaBackdrop)
                        .frame(width: 44, height: 44)
                        .background(PulsePlayerStyle.mediaAccent, in: Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(LocalizedStringKey(playback.intendsPlayback ? "Pause video" : "Play video"))
                .accessibilityIdentifier("player.playPause")
                .disabled(!canControlPlayback || playback.error != nil)
                if localIdentity != nil { skipButton(seconds: 10) }
            }
            PlayerProgressControl(playback: playback, timeline: playback.timeline,
                                  enabled: canControlPlayback, canResume: canControlPlayback,
                                  scrubbing: $scrubbing, tint: PulsePlayerStyle.mediaAccent,
                                  showsTimecodes: true, onMedia: true, resumePlayback: resumePlayback)
                .frame(maxWidth: .infinity)
        }
    }

    private var lessonSettings: some View {
        let controls = Group {
            Button { showOptions(.speed) } label: {
                HStack(spacing: 5) {
                    LocalizedText("Speed")
                    Text(verbatim: rateText(playback.speed)).monospacedDigit()
                }
            }
            .accessibilityIdentifier("player.speed")
            Button {
                controlsActivity += 1
                playback.setMuted(!playback.muted)
            } label: {
                HStack(spacing: 5) {
                    Glyph(symbol: playback.muted ? .mute : .sound, size: 15, tint: PulsePlayerStyle.onDark)
                    LocalizedText(playback.muted ? "Unmute" : "Mute")
                }
            }
            .accessibilityIdentifier("player.mute")
            Button { showOptions(.more) } label: {
                HStack(spacing: 5) {
                    TintedArtwork(name: "PlayerMore", tint: PulsePlayerStyle.onDark).frame(width: 15, height: 15)
                    LocalizedText("Video tools")
                }
            }
            .accessibilityIdentifier("player.videoTools")
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { controls }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 0) { controls }
        }
        .buttonStyle(PlaybackUtilityStyle())
        .disabled(!active || hasOpenPanel || pagingGate || ads.isPresenting)
    }

    private func skipButton(seconds: Double) -> some View {
        let label = seconds < 0 ? "Back 10 seconds" : "Forward 10 seconds"
        let amount = Int(abs(seconds)).formatted(.number.locale(locale))
        return Button {
            let duration = playback.timeline.duration
            guard duration > 0 else { return }
            playback.seek(min(duration, max(0, playback.timeline.elapsed + seconds)))
        } label: {
            Text(verbatim: (seconds < 0 ? "−" : "+") + amount)
                .font(.capture(.caption, weight: .semibold)).monospacedDigit()
                .foregroundStyle(PulsePlayerStyle.onDark)
                .padding(.horizontal, 6)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(LocalizedStringKey(label))
        .disabled(!canControlPlayback || playback.error != nil)
    }

    @ViewBuilder private var playbackFeedback: some View {
        if showsPlaybackFeedback {
            if accessChecked && !allowed {
                let limitReached = quota.canRequestReward(for: .watch, premium: commerce.premium)
                VStack(alignment: .leading, spacing: 4) {
                    LocalizedText(limitReached ? "Daily view limit reached" : "Playback unavailable")
                        .font(.capture(.subheadline, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if limitReached {
                        dockFeedbackButton("Get more views") { showingWatchOptions = true }
                    } else {
                        ErrorNote(message: quota.error ?? "Your connection is not ready. Please try again shortly.", onMedia: true)
                        dockFeedbackButton("Try again") { activate() }
                    }
                }.padding(4)
            } else if allowed, playback.error == nil,
                      playback.isLoading || (!firstFrameReady && playback.intendsPlayback) {
                PlayerLoadingFeedback(buffering: firstFrameReady)
            }
        }
    }

    private func dockFeedbackButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LocalizedText(title)
                .font(.capture(.footnote, weight: .semibold))
                .foregroundStyle(PulsePlayerStyle.mediaAccent)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .frame(minWidth: 44, minHeight: 44)
                .background(PulsePlayerStyle.mediaAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func playbackAreas(in viewport: GeometryProxy) -> (media: CGRect, dock: CGRect?) {
        var area = CGRect(origin: .zero, size: viewport.size)
        guard #available(iOS 27.1, *) else { return (area, nil) }
        for region in viewport.reservedRegions(kind: .division) where region.isActive {
            let split = area.intersection(region.frame)
            guard !split.isNull, !split.isEmpty else { continue }
            if split.height >= split.width {
                let before = split.minX - area.minX
                let after = area.maxX - split.maxX
                if min(before, after) >= 164 {
                    return (CGRect(x: area.minX, y: area.minY, width: before, height: area.height),
                            CGRect(x: split.maxX, y: area.minY, width: after, height: area.height))
                }
            } else {
                let before = split.minY - area.minY
                let after = area.maxY - split.maxY
                if min(before, after) >= 100 {
                    return (CGRect(x: area.minX, y: area.minY, width: area.width, height: before),
                            CGRect(x: area.minX, y: split.maxY, width: area.width, height: after))
                }
            }
            area = PulsePlayerStyle.largestPane(in: area, excluding: split)
        }
        return (area, nil)
    }

    private func safeControls(in frame: CGRect, viewport: GeometryProxy) -> CGRect {
        let safeArea = CGRect(x: layoutDirection == .rightToLeft ? safeInsets.trailing : safeInsets.leading, y: safeInsets.top,
                              width: max(0, viewport.size.width - safeInsets.leading - safeInsets.trailing),
                              height: max(0, viewport.size.height - safeInsets.top - safeInsets.bottom))
        let visible = frame.intersection(safeArea)
        var area = visible.isEmpty ? frame : visible
        guard #available(iOS 27.1, *) else { return area }
        for region in viewport.reservedRegions(kind: .occlusion) where region.isActive {
            let obstruction = area.intersection(region.frame)
            guard !obstruction.isNull, !obstruction.isEmpty else { continue }
            let pane = PulsePlayerStyle.largestPane(in: area, excluding: obstruction)
            if !pane.isEmpty { area = pane }
        }
        return area
    }

    private func rateText(_ rate: Float) -> String {
        LocalPlaybackPreferences.label(rate, locale: locale)
    }

    private func showOptions(_ selection: PlayerOptions) {
        resumeAfterSheet = playback.intendsPlayback
        playback.pause()
        showsFolderOptions = false
        folderMoveError = nil
        options = selection
    }

    private func finishOptions() {
        favoriteError = nil
        if let channel = channelAfterTools {
            channelAfterTools = nil
            guard active, visible, !pagingGate else { return }
            if channel.id == returningToChannel?.id {
                resumeAfterSheet = false
                onSwipeExit()
            } else {
                presentedSource = channel
            }
        } else if let entry = playlistEntryAfterOptions {
            playlistEntryAfterOptions = nil
            if active && visible && !pagingGate && localPlaylist.contains(where: { $0.id == entry }) {
                resumeAfterSheet = false
                selectPlaylistEntry(entry)
            } else {
                resumeAfterControls()
            }
        } else if editorAfterOptions {
            editorAfterOptions = false
            if active && visible && !pagingGate { editor = true }
        } else {
            resumeAfterControls()
        }
    }

    private func playbackOptions(_ selection: PlayerOptions) -> some View {
        let isLocal = localIdentity != nil
        let title: String
        switch selection {
        case .speed: title = "Speed"
        case .more: title = "Video tools"
        case .folds: title = "Fold notes"
        }
        return playerMenuSheet(title, close: { options = nil }) {
            if selection == .folds, let foldID {
                FoldPracticePanel(identity: foldID, playback: playback) { play in
                    resumeAfterSheet = play
                    options = nil
                }
            } else if selection == .speed {
                speedOptions(isLocal: isLocal)
            } else {
                moreOptions(isLocal: isLocal)
            }
        }
    }

    private func playerMenuSheet<Content: View>(
        _ title: String, close: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LocalizedText(title)
                    .font(.capture(.title3, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Button(action: close) {
                    Glyph(symbol: .close, size: 14, tint: PulsePlayerStyle.onDark)
                        .frame(width: 32, height: 32)
                        .background(PulsePlayerStyle.onDark.opacity(0.10), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(LocalizedStringKey("Close"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .pageHorizontalMargins()
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 12)
        .foregroundStyle(PulsePlayerStyle.onDark)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Self.panelCornerRadius)
        .presentationBackground {
            Color.clear
                .pulsePlayerGlass(in: RoundedRectangle(cornerRadius: Self.panelCornerRadius), tint: Self.panelTint,
                            fallback: PulsePlayerStyle.mediaSurface, interactive: false, onDark: true)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder private func speedOptions(isLocal: Bool) -> some View {
        let speeds = isLocal ? LocalPlaybackPreferences.speeds : [Float(0.5), 1, 1.5, 2]
        let column = GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 112 : 60), spacing: 6)
        LazyVGrid(columns: [column], spacing: 6) {
            ForEach(speeds, id: \.self) { rate in
                let selected = playback.speed == rate
                Button {
                    if isLocal {
                        defaultLocalSpeed = Double(rate)
                        updateLocalPlaybackPreferences()
                    } else {
                        playback.setSpeed(rate)
                        options = nil
                    }
                } label: {
                    Text(verbatim: rateText(rate))
                        .font(.capture(.subheadline, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selected ? PulsePlayerStyle.mediaBackdrop : PulsePlayerStyle.onDark)
                        .background(selected ? PulsePlayerStyle.mediaAccent : PulsePlayerStyle.onDark.opacity(0.08), in: Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }

        if isLocal {
            Toggle(isOn: $loopsLocalPlayback) {
                LocalizedText("Loop playback").font(.capture(.subheadline, weight: .medium))
                    .foregroundStyle(PulsePlayerStyle.onDark)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tint(PulsePlayerStyle.mediaAccent)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(minHeight: 48)
            .background(PulsePlayerStyle.onDark.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder private func moreOptions(isLocal: Bool) -> some View {
        let saved = clip.localMovieID.map { library.isLocalSaved($0) } ?? library.isSaved(clip)
        let movable = isLocal && localMovie?.isExport == false ? localMovie : nil
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: clip.title).font(.capture(.headline, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            playbackSourceLink
        }

        Button(action: save) {
            HStack(spacing: 10) {
                TintedArtwork(name: saved ? "PlayerFavorited" : "PlayerFavorite", tint: PulsePlayerStyle.mediaAccent)
                    .frame(width: 18, height: 18)
                LocalizedText(saved ? "Remove from favorites" : "Save to favorites")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(PlaybackUtilityStyle())
        if let favoriteError { ErrorNote(message: favoriteError, onMedia: true) }

        optionButton(clip.localMovieID == nil ? "Edit a local video" : "Edit video", symbol: .edit) {
            editorAfterOptions = true
            options = nil
        }
        if let movable {
            optionButton("Move to folder", symbol: .folder) { showsFolderOptions.toggle() }
                .accessibilityAddTraits(showsFolderOptions ? .isSelected : [])
            if showsFolderOptions { folderOptions(for: movable) }
        }
        if clip.localMovieID == nil {
            OfflineDownloadButton(clip: foldSource)
        } else {
            VideoExportEntry(clip: clip) { openExport in
                optionButton("Export video", symbol: .download, action: openExport)
            }
        }
        if isLocal && localPlaylist.count > 1 { playlistOptions }
    }

    private var optionDivider: some View {
        Rectangle().fill(PulsePlayerStyle.onDark.opacity(0.14)).frame(height: 1)
            .padding(.horizontal, 12)
            .accessibilityHidden(true).allowsHitTesting(false)
    }

    private func optionButton(_ title: String, symbol: PulsePlayerGlyph, action: @escaping () -> Void) -> some View {
        Button(action: action) { PlayerMenuRow(symbol: symbol) { LocalizedText(title) } }
            .buttonStyle(PressStyle())
    }

    private var playlistOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Playlist").accessibilityAddTraits(.isHeader)
            LazyVStack(spacing: 0) {
                ForEach(localPlaylist) { entry in
                    let selected = entry.id == playlistEntryID
                    Button {
                        if !selected { playlistEntryAfterOptions = entry.id }
                        options = nil
                    } label: {
                        HStack(spacing: 8) {
                            VideoFileThumbnail(url: entry.clip.playbackURL, maximumSize: 160,
                                               fallbackCover: entry.clip.coverURL)
                                .frame(width: 48, height: 34)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(verbatim: entry.clip.title)
                                .font(.capture(.footnote, weight: selected ? .semibold : .medium))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundStyle(selected ? PulsePlayerStyle.mediaAccent : PulsePlayerStyle.onDark)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if selected { Glyph(symbol: .play, size: 13, tint: PulsePlayerStyle.mediaAccent) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(minHeight: 46)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    if entry.id != localPlaylist.last?.id { optionDivider }
                }
            }
            .background(PulsePlayerStyle.onDark.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func folderOptions(for movie: PracticeRecording) -> some View {
        let destinations = library.folders.filter { $0.id != movie.folderID }
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Folders").accessibilityAddTraits(.isHeader)
            if library.folders.isEmpty {
                LocalizedText("No folders yet").font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.mediaSecondary)
            }
            LazyVStack(spacing: 0) {
                if movie.folderID != nil {
                    optionButton("Remove from folder", symbol: .folder) { move(movie, to: nil) }
                    if !destinations.isEmpty { optionDivider }
                }
                ForEach(destinations) { folder in
                    Button { move(movie, to: folder.id) } label: {
                        PlayerMenuRow(symbol: .folder) { Text(verbatim: folder.name) }
                    }
                    .buttonStyle(PressStyle())
                    if folder.id != destinations.last?.id { optionDivider }
                }
            }
            .background(PulsePlayerStyle.onDark.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            if let folderMoveError { ErrorNote(message: folderMoveError, onMedia: true) }
        }
    }

    private func move(_ movie: PracticeRecording, to folderID: UUID?) {
        do {
            try library.moveMovie(movie.id, to: folderID)
            options = nil
        } catch {
            folderMoveError = error.localizedDescription
        }
    }

    private func updateLocalPlaybackPreferences() {
        guard active, playback.loadedURL == clip.playbackURL else { return }
        playback.configureLocalPlayback(speed: LocalPlaybackPreferences.speed(defaultLocalSpeed), loops: loopsLocalPlayback)
    }

    private func activate(reload: Bool = false) {
        guard active, visible, phase == .active, !ads.isPresenting, !pagingGate,
              !hasOpenPanel else { return }
        recorded = false
        accessChecked = true
        if clip.playbackURL.isFileURL {
            guard let localIdentity else { rejectUnavailableLocalFile(); return }
            allowed = true
            if playback.loadedURL != clip.playbackURL || reload {
                firstFrameReady = false
                playback.load(clip.playbackURL, autoplay: false)
            }
            playback.enableLocalProgress(for: localIdentity, resumesPlayback: resumesLocalPlayback)
            if let foldID { playback.enableFoldPractice(for: foldID) }
            updateLocalPlaybackPreferences()
            playback.play()
            return
        }
        startOnlinePlayback(reload: reload)
    }
    private func startOnlinePlayback(reload: Bool = false) {
        let needsLoad = playback.loadedURL != clip.playbackURL || reload
        guard needsLoad || playback.error == nil else { return }
        guard let owner = commerce.api.session?.userId.value,
              let admission = quota.reserveWatch(clip.id, premium: commerce.premium, owner: owner) else {
            allowed = false
            playback.pause()
            return
        }
        allowed = true
        let completion: ((Bool) -> Void)?
        switch admission {
        case .alreadyWatched: completion = nil
        case .reserved(let reservation):
            completion = { [quota] played in quota.settleWatch(reservation, played: played) }
        }
        if needsLoad {
            firstFrameReady = false
            playback.load(clip.playbackURL, autoplay: true, initialWatchCompletion: completion)
            if let foldID { playback.enableFoldPractice(for: foldID) }
        } else {
            if let foldID { playback.enableFoldPractice(for: foldID) }
            playback.trackInitialWatch(completion)
            playback.play()
        }
    }
    private func authorizeOnlinePlayback() -> Bool {
        if let owner = commerce.api.session?.userId.value {
            allowed = quota.recordWatch(clip.id, premium: commerce.premium, owner: owner)
        } else {
            allowed = false
        }
        if !allowed { playback.pause() }
        return allowed
    }
    private func resumePlayback() {
        guard playback.loadedURL == clip.playbackURL else { activate(); return }
        if clip.playbackURL.isFileURL { playback.play() }
        else { startOnlinePlayback() }
    }
    private func togglePlayback() {
        guard canControlPlayback, playback.error == nil else { return }
        if playback.intendsPlayback { playback.pause() }
        else { resumePlayback() }
    }
    private func rejectUnavailableLocalFile() {
        accessChecked = true
        allowed = true
        firstFrameReady = false
        playback.release()
        playback.error = "This video file is missing or unreadable. Open it again or download a new copy."
    }
    private func resumeAfterControls() {
        guard resumeAfterSheet, active, visible, phase == .active,
              !ads.isPresenting, !hasOpenPanel else { return }
        resumeAfterSheet = false
        activate()
    }
    private func interruptPlayback() {
        if active, visible, playback.intendsPlayback { resumeAfterInterruption = true }
        playback.pause()
    }
    private func resumeIfNeeded() {
        guard resumeAfterInterruption || resumeAfterSheet, active, visible, phase == .active,
              !ads.isPresenting, !hasOpenPanel else { return }
        resumeAfterInterruption = false
        resumeAfterSheet = false
        activate()
    }
    private func save() {
        controlsActivity += 1
        favoriteError = nil
        let succeeded: Bool
        if let id = clip.localMovieID {
            succeeded = library.toggleLocalFavorite(id)
        } else {
            var favorite = offline.cached(clip.id)?.clip ?? clip
            favorite.sourceChannel = channelSource ?? favorite.sourceChannel
            succeeded = library.toggle(favorite)
        }
        if !succeeded {
            favoriteError = "Favorites could not be updated. Please try again."
            library.error = nil // This full-screen surface owns the feedback.
        }
    }
}

private struct PlayerSurfaceGestures: UIViewRepresentable {
    let tap: () -> Void
    let swipeLeft: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(actions: self) }

    func makeUIView(context: Context) -> UIView {
        let surface = UIView()
        let coordinator = context.coordinator
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.didTap))
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.didPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = coordinator
        surface.addGestureRecognizer(tap)
        surface.addGestureRecognizer(pan)
        return surface
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.actions = self
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var actions: PlayerSurfaceGestures

        init(actions: PlayerSurfaceGestures) { self.actions = actions }

        // Fail before recognition so a vertical pan can page the enclosing scroll view.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            return isLeftward(pan.velocity(in: nil))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func didTap() { actions.tap() }

        @objc func didPan(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .ended else { return }
            let movement = pan.translation(in: nil)
            if movement.x < -90, isLeftward(movement) { actions.swipeLeft() }
        }

        private func isLeftward(_ movement: CGPoint) -> Bool {
            -movement.x > abs(movement.y) * 1.7
        }
    }
}

private struct PlayerHeader: View {
    let exit: (() -> Void)?
    var overMedia = false

    var body: some View {
        VStack(spacing: 3) {
            if let exit {
                if overMedia {
                    PlayerExitButton(overMedia: true, action: exit)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, PlayerTopControls.edgeInset)
                } else {
                    PlayerExitButton(overMedia: false, action: exit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .pageHorizontalMargins()
                }
            }
            DownloadCompletionNotice()
        }
    }
}

private struct PlayerExitButton: View {
    let overMedia: Bool
    let action: () -> Void
    var body: some View {
        let foreground = overMedia ? PulsePlayerStyle.onDark : PulsePlayerStyle.paper
        Button(action: action) {
            HStack(spacing: 6) {
                Glyph(symbol: .close, size: overMedia ? 16 : 12, tint: foreground)
                if !overMedia {
                    LocalizedText("Exit").font(.capture(.footnote, weight: .semibold))
                        .foregroundStyle(foreground).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, overMedia ? 0 : 12).padding(.vertical, overMedia ? 0 : 4)
            .frame(minWidth: PlayerTopControls.buttonSize, minHeight: PlayerTopControls.buttonSize)
            .pulsePlayerGlass(in: Capsule(), tint: overMedia ? PulsePlayerStyle.mediaBackdrop.opacity(0.65) : nil,
                        fallback: overMedia ? PulsePlayerStyle.mediaSurface : PulsePlayerStyle.raised, onDark: overMedia)
            .contentShape(Rectangle())
        }.buttonStyle(PressStyle()).accessibilityLabel(LocalizedStringKey("Exit"))
            .accessibilityIdentifier("player.exit")
    }
}

struct PlayerMenuRow<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let symbol: PulsePlayerGlyph
    var showsChevron = true
    @ViewBuilder let label: () -> Label

    var body: some View {
        HStack(spacing: 10) {
            Glyph(symbol: symbol, size: 16, tint: PulsePlayerStyle.mediaAccent).frame(width: 22)
            label()
                .font(.capture(.subheadline, weight: .medium))
                .foregroundStyle(PulsePlayerStyle.onDark)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsChevron {
                Glyph(symbol: .back, size: 10, tint: PulsePlayerStyle.mediaSecondary).rotationEffect(.degrees(180))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(minHeight: 46)
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
    }
}

struct PlayerProgressControl: View {
    @ObservedObject var playback: PlaybackController
    @ObservedObject var timeline: PlaybackTimeline
    let enabled: Bool
    let canResume: Bool
    @Binding var scrubbing: Bool
    var tint: Color = PulsePlayerStyle.accent
    var showsPlayhead = false
    var showsTimecodes = false
    var onMedia = false
    var resumePlayback: (() -> Void)? = nil
    @State private var scrubPosition: Double = 0
    @State private var resumeAfterScrub = false

    var body: some View {
        if showsTimecodes {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(verbatim: durationLabel(scrubbing ? scrubPosition : timeline.elapsed))
                        .foregroundStyle(tint)
                    Spacer(minLength: 6)
                    Text(verbatim: durationLabel(timeline.duration))
                        .foregroundStyle(onMedia ? PulsePlayerStyle.mediaSecondary : PulsePlayerStyle.secondary)
                }.font(.capture(.caption, weight: .semibold)).monospacedDigit()
                scrubber
            }.environment(\.layoutDirection, .leftToRight)
        } else {
            scrubber.overlay(alignment: .top) {
                if scrubbing {
                    Text(verbatim: "\(durationLabel(scrubPosition)) / \(durationLabel(timeline.duration))")
                        .environment(\.layoutDirection, .leftToRight)
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, showsPlayhead ? 6 : 0)
                        .foregroundStyle(showsPlayhead ? PulsePlayerStyle.onDark : PulsePlayerStyle.paper)
                        .background(showsPlayhead ? PulsePlayerStyle.mediaBackdrop : .clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                        .offset(y: -8)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var scrubber: some View {
        PulsePlayerScrubber(value: Binding(
                get: { scrubbing ? scrubPosition : timeline.elapsed },
                set: {
                    scrubPosition = $0
                    // During a drag, move the UI only. Seek once on release.
                    if !scrubbing { playback.seek($0) }
                }
            ), range: 0...max(0.01, timeline.duration), label: "Playback position",
                         tint: tint, trackTint: onMedia ? PulsePlayerStyle.onDark.opacity(0.26) : PulsePlayerStyle.secondary.opacity(0.24),
                         trackHeight: scrubbing ? 5 : showsTimecodes ? 4 : 2,
                         showsPlayhead: showsPlayhead, showsThumb: showsTimecodes,
                         onEditingChanged: { editing in
                if editing {
                    scrubPosition = timeline.elapsed
                    resumeAfterScrub = playback.intendsPlayback
                    scrubbing = true
                    playback.pause()
                } else {
                    playback.seek(scrubPosition)
                    scrubbing = false
                    if resumeAfterScrub && canResume {
                        if let resumePlayback { resumePlayback() } else { playback.play() }
                    }
                    resumeAfterScrub = false
                }
            })
            .disabled(!enabled || timeline.duration <= 0 || playback.error != nil)
    }
}

private struct PlayerPoster: View {
    let url: URL?
    var body: some View {
        PulsePlayerStyle.mediaBackdrop.overlay {
            GeometryReader { geometry in
                if let url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        }
                    }
                }
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct PlayerLoadingFeedback: View {
    let buffering: Bool
    var floating = false
    @State private var revealed = false
    var body: some View {
        let content = HStack(spacing: 8) {
            ProgressView().tint(PulsePlayerStyle.mediaAccent).accessibilityHidden(true)
            LocalizedText(buffering ? "Buffering…" : "Loading…")
                .font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.mediaSecondary)
        }
        Group {
            if floating {
                content.padding(.horizontal, 12).padding(.vertical, 8)
                    .pulsePlayerGlass(in: Capsule(), tint: PulsePlayerStyle.mediaBackdrop.opacity(0.72),
                                fallback: PulsePlayerStyle.mediaSurface, interactive: false, onDark: true)
            } else {
                content.padding(.horizontal, 4)
            }
        }
        .opacity(revealed ? 1 : 0).accessibilityHidden(!revealed)
        .task {
            do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation(); revealed = true }
            catch { }
        }
        .onDisappear { revealed = false }
    }
}

struct PulsePlayerScrubber: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    var tint: Color = PulsePlayerStyle.accent
    var trackTint: Color = PulsePlayerStyle.secondary.opacity(0.24)
    var trackHeight: CGFloat = 4
    var showsPlayhead = false
    var showsThumb = false
    var onEditingChanged: (Bool) -> Void = { _ in }
    @GestureState private var dragging = false
    @State private var editing = false
    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard value.isFinite, range.lowerBound.isFinite, span.isFinite, span > 0 else { return 0 }
        return CGFloat(min(1, max(0, (value - range.lowerBound) / span)))
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if showsPlayhead {
                    Capsule().fill(tint).frame(width: 3, height: 44)
                        .offset(x: max(0, geometry.size.width - 3) * fraction)
                } else {
                    Capsule().fill(trackTint).frame(height: trackHeight)
                    Capsule().fill(tint).frame(width: geometry.size.width * fraction, height: trackHeight)
                    if showsThumb {
                        Circle().fill(tint).frame(width: 10, height: 10)
                            .offset(x: max(0, geometry.size.width - 10) * fraction)
                    }
                }
            }
                .frame(width: geometry.size.width, height: 44, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).updating($dragging) { _, state, _ in state = true }.onChanged { gesture in
                    if !editing { editing = true; onEditingChanged(true) }
                    value = range.lowerBound + min(1, max(0, gesture.location.x / max(1, geometry.size.width))) * (range.upperBound - range.lowerBound)
                }.onEnded { _ in finishEditing() })
        }.frame(height: 44).environment(\.layoutDirection, .leftToRight)
            .accessibilityElement().accessibilityLabel(LocalizedStringKey(label))
            .onChange(of: dragging) { _, dragging in if !dragging { finishEditing() } }
            .accessibilityValue(durationLabel(value)).accessibilityAdjustableAction { direction in
                value = min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? 1 : -1)))
            }
    }
    private func finishEditing() {
        guard editing else { return }
        editing = false
        onEditingChanged(false)
    }
}

private struct PlaybackUtilityStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.capture(.subheadline, weight: .medium))
            .foregroundStyle(PulsePlayerStyle.onDark)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 6)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.55)
    }
}

private struct PlaybackFoldNavigation: View {
    let videoTitle: String
    let identity: FoldPracticeID?
    let enabled: Bool
    let jump: (FoldPracticeID, UUID) throws -> Void
    @ObservedObject private var practice = FoldPracticeStore.shared
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var error: String?
    private var language: AppLanguage { .from(locale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let entry = practice.entry(for: identity),
               let index = entry.steps.firstIndex(where: { $0.id == entry.selectedID }) {
                let current = entry.steps[index]
                Text(verbatim: videoTitle).font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.mediaSecondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                let number = (index + 1).formatted(.number.locale(locale))
                let total = entry.steps.count.formatted(.number.locale(locale))
                let stepNumber = L10n.format("Fold %@ of %@", [number, total], language: language)
                if let name = current.displayName(language: language) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: stepNumber).font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.mediaAccent)
                        Text(verbatim: name).font(.capture(.headline, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                } else {
                    Text(verbatim: stepNumber).font(.capture(.headline, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                }
                if entry.steps.count > 1 {
                    let links = Group {
                        if index > 0 { stepLink(entry.steps[index - 1], in: entry.id, next: false) }
                        if index + 1 < entry.steps.count { stepLink(entry.steps[index + 1], in: entry.id, next: true) }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 10) { links }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 0) { links }
                    }
                    .disabled(!enabled)
                }
            } else {
                Text(verbatim: videoTitle).font(.capture(.subheadline, weight: .semibold))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                LocalizedText(error).font(.capture(.caption))
                    .foregroundStyle(PulsePlayerStyle.mediaSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: identity) { _, _ in error = nil }
    }

    private func stepLink(_ step: FoldPracticeStep, in id: FoldPracticeID, next: Bool) -> some View {
        let name = step.displayName(language: language)
        return Button {
            do {
                try jump(id, step.id)
                error = nil
            } catch { self.error = error.localizedDescription }
        } label: {
            HStack(spacing: 6) {
                if !next { Glyph(symbol: .back, size: 10, tint: PulsePlayerStyle.mediaAccent) }
                VStack(alignment: .leading, spacing: 1) {
                    LocalizedText(next ? "Next fold" : "Previous fold")
                        .font(.capture(.footnote, weight: .semibold))
                        .foregroundStyle(PulsePlayerStyle.mediaAccent)
                    if next, let name {
                        Text(verbatim: name).font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.onDark)
                    }
                }.fixedSize(horizontal: false, vertical: true)
                if next { Glyph(symbol: .back, size: 10, tint: PulsePlayerStyle.mediaAccent).rotationEffect(.degrees(180)) }
            }
            .padding(.horizontal, 8).padding(.vertical, 3).frame(minHeight: 44)
            .background(PulsePlayerStyle.onDark.opacity(0.08), in: .rect(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).multilineTextAlignment(.leading)
        .accessibilityValue(Text(verbatim: durationLabel(step.start)))
        .accessibilityIdentifier(next ? "player.nextMarkedFold" : "player.previousMarkedFold")
    }
}
