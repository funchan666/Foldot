import SwiftUI
import UIKit
import OSLog

@main
struct PulsePlayerApp: App {
    @AppStorage(AppLanguage.preferenceKey) private var languageCode = AppLanguage.defaultSelection
    @Environment(\.scenePhase) private var appPhase
    @State private var systemLanguage = AppLanguage.systemLanguage()
    private var language: AppLanguage { AppLanguage.resolve(languageCode, system: systemLanguage) }
    @StateObject private var api: APIClient
    @StateObject private var library: LibraryStore
    @StateObject private var quota: QuotaStore
    @StateObject private var commerce: CommerceStore
    @StateObject private var offline: OfflineStore
    @StateObject private var ads: RewardedAds
    @StateObject private var accountAccess = AccountAccessFlow()
    init() {
        AppLanguage.migrateUnsupportedSelection()
        let api = APIClient()
        let quota = QuotaStore()
        _api = StateObject(wrappedValue: api)
        _library = StateObject(wrappedValue: LibraryStore())
        _quota = StateObject(wrappedValue: quota)
        let commerce = CommerceStore(api: api, quota: quota)
        _commerce = StateObject(wrappedValue: commerce)
        _offline = StateObject(wrappedValue: OfflineStore(api: api, quota: quota, commerce: commerce))
        _ads = StateObject(wrappedValue: RewardedAds())
    }
    var body: some Scene {
        WindowGroup {
            PulsePlayerStartupHost().environmentObject(api).environmentObject(library)
                .environmentObject(quota).environmentObject(commerce).environmentObject(ads).environmentObject(offline)
                .environmentObject(accountAccess)
                .environment(\.locale, language.locale)
                .environment(\.layoutDirection, language.direction)
                .font(.capture(.body))
                .tint(PulsePlayerStyle.accent)
                .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                    systemLanguage = AppLanguage.systemLanguage()
                }
                .onChange(of: appPhase) { _, phase in
                    if phase == .active { systemLanguage = AppLanguage.systemLanguage() }
                }
        }
    }
}

// Keeps launch feedback visible during the bounded cold-start ad opportunity.
// Guest authentication prepares configuration and opens the app directly.
struct PulsePlayerStartupHost: View {
    @EnvironmentObject private var ads: RewardedAds
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var accountAccess: AccountAccessFlow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var finished = false
    @State private var startupBegan = ContinuousClock.now

    var body: some View {
        ZStack {
            PulsePlayerStyle.background.ignoresSafeArea()
            // Mount once so local content and authentication prepare while the
            // bounded app-open opportunity runs, without rebuilding navigation.
            PulsePlayerRootView(startupFinished: finished)
                .allowsHitTesting(finished)
                .accessibilityHidden(!finished)
            if !finished {
                PulsePlayerStartupView()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .preferredColorScheme(.light)
        .task(id: scenePhase) {
            guard scenePhase == .active, !finished else { return }
            ads.beginStartup(commerce: commerce, accountAccess: accountAccess)
        }
        .onReceive(ads.$startupFinished) { complete in
            if complete, !finished {
                Logger(subsystem: "app.pulseplayer", category: "Startup")
                    .info("Home became interactive after \(startupBegan.duration(to: .now).description, privacy: .public)")
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { finished = true }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                // A new process starts at the branded startup view, even after a full-screen ad.
                UIApplication.shared.ignoreSnapshotOnNextApplicationLaunch()
                ads.didEnterBackground()
            }
            if phase == .active {
                ads.didBecomeActive(commerce: commerce, accountAccess: accountAccess)
            }
        }
    }
}

struct PulsePlayerStartupView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var highlightPassed = false
    @State private var showsActivity = false

    var body: some View {
        let mark = Image(decorative: "PulsePlayerLaunchMark")
        mark
            .overlay {
                if !reduceMotion {
                    GeometryReader { bounds in
                        let width = bounds.size.width
                        LinearGradient(colors: [.clear, .white.opacity(0.65), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: width * 0.34, height: bounds.size.height * 1.5)
                            .rotationEffect(.degrees(16))
                            .position(x: width * (highlightPassed ? 1.4 : -0.4),
                                      y: bounds.size.height / 2)
                    }
                    .mask(mark)
                    .opacity(scenePhase == .active ? 1 : 0)
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if showsActivity {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PulsePlayerStyle.accent)
                        .offset(y: 28)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color("StartupBackground").ignoresSafeArea(.container))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LocalizedStringKey("PulsePlayer is starting"))
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                if !highlightPassed {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.72)) {
                        highlightPassed = true
                    }
                }
                // Only a slower startup needs a loading indicator.
                do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
                showsActivity = true
            }
    }
}

enum PulsePlayerTab: Int, Hashable {
    // SceneStorage persists these values across tab renames and reordering.
    case files = 1
    case search = 0
    case settings = 2

    var name: String {
        switch self {
        case .files: "Library"
        case .search: "Search"
        case .settings: "Settings"
        }
    }

    var glyph: PulsePlayerGlyph {
        switch self {
        case .files: .library
        case .search: .search
        case .settings: .settings
        }
    }
    var identifier: String { "tab.\(name.lowercased())" }
}

private struct PulsePlayerTabItem: View {
    let tab: PulsePlayerTab
    @Environment(\.locale) private var locale
    var body: some View {
        Label {
            Text(verbatim: L10n.display(tab.name, language: AppLanguage.from(locale)))
        } icon: {
            Image(tab.glyph.assetName).renderingMode(.template)
        }
        .accessibilityLabel(Text(verbatim: L10n.text(tab.name, language: AppLanguage.from(locale))))
        .accessibilityIdentifier(tab.identifier)
    }
}

private extension View {
    func pulsePlayerTab(_ tab: PulsePlayerTab) -> some View {
        tabItem { PulsePlayerTabItem(tab: tab) }
            .tag(tab)
            .toolbarColorScheme(.light, for: .tabBar)
    }
}

// SwiftUI can present from a tab, a nested notebook, or a system picker.
// Look up only the window that owns this root before claiming a server-supplied link.
@MainActor
private final class RootPresentationWindow: ObservableObject {
    weak var marker: UIView?

    var isAvailable: Bool {
        guard let window = marker?.window, window.isKeyWindow,
              window.windowScene?.activationState == .foregroundActive,
              let root = window.rootViewController else { return false }
        return isIdle(root)
    }

    private func isIdle(_ controller: UIViewController) -> Bool {
        controller.presentedViewController == nil && controller.transitionCoordinator == nil
            && !controller.isBeingDismissed && !controller.isBeingPresented
            && controller.children.allSatisfy(isIdle)
    }
}

private struct PresentationWindowMarker: UIViewRepresentable {
    let owner: RootPresentationWindow

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        owner.marker = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct PulsePlayerRootView: View {
    private enum LibraryDestination: Hashable {
        case tools, history, notebook, browse
        case editor(UUID?, VideoTool)
        case foldExport(FoldPracticeEntry)
    }

    let startupFinished: Bool
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var ads: RewardedAds
    @EnvironmentObject private var accountAccess: AccountAccessFlow
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("root.libraryTab") private var tab: PulsePlayerTab = .files
    @State private var settingsPath: [SettingsPage] = []
    @State private var searchPath: [SearchPage] = []
    @State private var importing = false
    @State private var libraryFilter = "Fold notes"
    @State private var libraryFolderID: UUID?
    @State private var libraryPath: [LibraryDestination] = []
    @State private var showingPlus = false
    @State private var loginLanding: LoginLandingLink?
    @StateObject private var presentationWindow = RootPresentationWindow()
    @State private var searchEngaged = false
    @State private var libraryEngaged = false

    private var availableLoginLanding: LoginLandingLink? {
        guard startupFinished, scenePhase == .active, !ads.isPresenting,
              !ads.isPreparingAppOpen, !ads.isPreparingPrivacy, !accountAccess.isBusy,
              !commerce.busy, !commerce.preparingPurchase,
              !importing, !showingPlus, loginLanding == nil,
              !(tab == .search && (searchEngaged || !searchPath.isEmpty)),
              !(tab == .settings && !settingsPath.isEmpty),
              !(tab == .files && (libraryEngaged || !libraryPath.isEmpty)),
              let link = api.pendingLoginLanding, api.session?.userId.value == link.owner else { return nil }
        return link
    }

    var body: some View {
        TabView(selection: $tab) {
            filesTab.pulsePlayerTab(.files)
            NavigationStack(path: $searchPath) {
                LessonSearchPage(openPlus: openPlus, importing: $importing,
                                 engaged: $searchEngaged, path: $searchPath)
                    .toolbar(.hidden, for: .navigationBar)
            }
            .pulsePlayerTab(.search)
            NavigationStack(path: $settingsPath) {
                AccountView(openFavorites: { openFiles("Saved") }, openFolders: { openFiles("Folders") },
                            openSearch: showLinkEntry, path: $settingsPath)
                    .toolbar(.hidden, for: .navigationBar)
            }
            .pulsePlayerTab(.settings)
        }
            .disabled(importing)
            .background { PresentationWindowMarker(owner: presentationWindow).allowsHitTesting(false).accessibilityHidden(true) }
            .tint(PulsePlayerStyle.accent)
            .foregroundStyle(PulsePlayerStyle.paper)
            .fullScreenCover(isPresented: $showingPlus) { MembershipView() }
            .fullScreenCover(item: $loginLanding) { link in
                LoginLandingView(link: link)
            }
            .overlay(alignment: .top) {
                if !isBrowsing { DownloadCompletionNotice().padding(.top, 8) }
            }
            .onChange(of: library.listRequest) { _, request in
                if let request {
                    loginLanding = nil
                    searchPath.removeAll()
                    settingsPath.removeAll()
                    openFiles(request.list.filter, folderID: request.list.folderID)
                }
            }
            .task(id: availableLoginLanding) {
                guard let link = availableLoginLanding else { return }
                // Child and system sheet transitions can outlive their SwiftUI bindings.
                // Keep the link unclaimed until an entire presentation transition settles.
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                    guard availableLoginLanding == link else { return }
                    if presentationWindow.isAvailable {
                        if api.claimLoginLanding(link) { loginLanding = link }
                        return
                    }
                }
            }
            .task(id: api.session?.userId.value) {
                guard api.session != nil else { return }
                if !commerce.rightsVerified || commerce.release == nil { await commerce.refresh() }
                await offline.resumePending()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { quota.resetIfNeeded() }
            }
            .overlay(alignment: .top) {
                if let message = library.error {
                    HStack {
                        LocalizedText(message).font(.capture(.subheadline))
                        IconButton(symbol: .close, label: "Dismiss message") { library.error = nil }
                    }.padding(14)
                        .pulsePlayerGlass(in: .rect(cornerRadius: 18), fallback: PulsePlayerStyle.raised, interactive: false)
                        .padding()
                }
            }
            .modifier(AccountBusyModifier())
    }

    private var filesTab: some View {
        NavigationStack(path: $libraryPath) {
            LibraryView(edit: { libraryPath.append(.editor($0.id, .studio)) },
                        browseVideos: { libraryPath.append(.browse) },
                        openEditor: { libraryPath.append(.editor(nil, .studio)) },
                        openSearch: showLinkEntry,
                        openTools: { libraryPath = [.tools] }, openNotebook: { libraryPath.append(.notebook) },
                        openPlus: openPlus, openHistory: openHistory,
                        filter: $libraryFilter, importing: $importing, engaged: $libraryEngaged, selectedFolderID: $libraryFolderID)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: LibraryDestination.self) { destination in
                    switch destination {
                    case .browse:
                        BrowseVideoListView(returnToLinkInput: showLinkEntry)
                            .toolbar(.hidden, for: .navigationBar, .tabBar)
                    case .tools:
                        ToolsView(openPlus: openPlus, edit: { movie, tool in libraryPath.append(.editor(movie.id, tool)) })
                            .toolbar(.hidden, for: .navigationBar)
                    case .notebook:
                        FoldNotebookView(openExport: { libraryPath.append(.foldExport($0)) })
                            .toolbar(.hidden, for: .navigationBar, .tabBar)
                    case .foldExport(let entry):
                        FoldClipExportView(entry: entry)
                            .toolbar(.hidden, for: .navigationBar, .tabBar)
                    case .editor(let id, let tool):
                        EditorSheet(initialMovie: library.movies.first { $0.id == id }, initialTool: tool, pushed: true)
                            .toolbar(.hidden, for: .navigationBar, .tabBar)
                    case .history:
                        VideoHistoryView(browseVideos: { libraryPath.append(.browse) }, edit: { libraryPath.append(.editor($0.id, .studio)) },
                                         review: { libraryPath.append(.editor($0.id, .ranges)) })
                            .toolbar(.hidden, for: .navigationBar)
                    }
                }
        }
    }

    private func openFiles(_ filter: String, folderID: UUID? = nil) {
        libraryFilter = filter
        libraryFolderID = folderID
        libraryPath = []
        tab = .files
    }

    private func openHistory() {
        tab = .files
        libraryPath = [.history]
    }

    private func openPlus() { showingPlus = true }

    private var isBrowsing: Bool {
        switch tab {
        case .files: libraryPath.last == .browse
        case .search: searchPath.last == .browse
        case .settings: settingsPath.last == .browse
        }
    }

    private func showLinkEntry() {
        if tab == .files, libraryPath.last == .browse { libraryPath.removeLast() }
        if tab == .settings, settingsPath.last == .browse { settingsPath.removeLast() }
        searchPath.removeAll()
        tab = .search
    }

}

// A network recovery surface, not a second login or consent gate.
struct ConnectionPanel: View {
    @EnvironmentObject private var api: APIClient
    var loadingTitle = "Connecting to PulsePlayer…"
    @State private var error: String?
    @State private var connecting = false
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 24) {
            if let error {
                MessagePanel(title: "Couldn’t connect to PulsePlayer", message: error)
                ActionButton(title: "Try again", busy: connecting) { attempt += 1 }
            } else {
                AccountLoadingIndicator(title: loadingTitle)
            }
            PolicyLinks()
        }
        .frame(maxWidth: 440).frame(maxWidth: .infinity)
        .task(id: attempt) {
            guard api.session == nil else { return }
            connecting = true
            error = nil
            defer { connecting = false }
            do { try await api.prepareVisitor() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
