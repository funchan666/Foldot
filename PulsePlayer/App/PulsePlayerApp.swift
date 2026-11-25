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
            if phase == .background { ads.didEnterBackground() }
            if phase == .active {
                ads.didBecomeActive(commerce: commerce, accountAccess: accountAccess)
            }
        }
    }
}

struct PulsePlayerStartupView: View {
    var body: some View {
        Image("LaunchMark")
            .resizable()
            .scaledToFit()
            .frame(width: 104, height: 104)
            .overlay(alignment: .bottom) {
                ProgressView()
                    .tint(PulsePlayerStyle.accent)
                    .offset(y: 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color("StartupBackground").ignoresSafeArea(.container))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LocalizedStringKey("PulsePlayer is starting"))
    }
}

enum PulsePlayerTab: Int, Hashable {
    case practice, files, settings

    var name: String { ["Practice", "Library", "Settings"][rawValue] }
    var artwork: String { ["GlyphFold", "GlyphLibrary", "GlyphSettings"][rawValue] }
    var identifier: String { "tab.\(name.lowercased())" }
}

private struct PulsePlayerTabItem: View {
    let tab: PulsePlayerTab
    @Environment(\.locale) private var locale
    var body: some View {
        Label {
            Text(verbatim: L10n.display(tab.name, language: AppLanguage.from(locale)))
        } icon: {
            Image(tab.artwork).renderingMode(.template)
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

private struct EditorPresentation: Identifiable {
    let id = UUID()
    let movie: PracticeRecording?
    var tool: VideoTool = .studio
}

struct PulsePlayerRootView: View {
    private enum LibraryDestination: Hashable { case tools, history }

    let startupFinished: Bool
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var ads: RewardedAds
    @EnvironmentObject private var accountAccess: AccountAccessFlow
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("root.libraryTab") private var tab: PulsePlayerTab = .practice
    @State private var editing: EditorPresentation?
    @State private var importing = false
    @State private var libraryFilter = "Fold notes"
    @State private var libraryFolderID: UUID?
    @State private var libraryPath: [LibraryDestination] = []
    @State private var showingPlus = false
    @State private var showingLessons = false
    @State private var returnToLessonEntry = false
    @State private var loginLanding: LoginLandingLink?
    @StateObject private var presentationWindow = RootPresentationWindow()
    @State private var deskEngaged = false
    @State private var libraryEngaged = false

    private var availableLoginLanding: LoginLandingLink? {
        guard startupFinished, scenePhase == .active, !ads.isPresenting,
              !ads.isPreparingAppOpen, !ads.isPreparingPrivacy, !accountAccess.isBusy,
              !commerce.busy, !commerce.preparingPurchase, editing == nil,
              !importing, !showingPlus, !showingLessons, loginLanding == nil,
              !(tab == .practice && deskEngaged),
              !(tab == .files && (libraryEngaged || !libraryPath.isEmpty)),
              let link = api.pendingLoginLanding, api.session?.userId.value == link.owner else { return nil }
        return link
    }

    var body: some View {
        TabView(selection: $tab) {
            FoldingDeskView(openPlus: openPlus, browseVideos: browseVideos, importing: $importing, engaged: $deskEngaged)
                .pulsePlayerTab(.practice)
            filesTab.pulsePlayerTab(.files)
            AccountView(openFavorites: { openFiles("Saved") }, openHistory: openHistory,
                        openFolders: { openFiles("Folders") })
                .pulsePlayerTab(.settings)
        }
            .disabled(importing)
            .background { PresentationWindowMarker(owner: presentationWindow).allowsHitTesting(false).accessibilityHidden(true) }
            .tint(PulsePlayerStyle.accent)
            .foregroundStyle(PulsePlayerStyle.paper)
            .sheet(item: $editing) { EditorSheet(initialMovie: $0.movie, initialTool: $0.tool) }
            .fullScreenCover(isPresented: $showingPlus) { MembershipView() }
            .fullScreenCover(item: $loginLanding) { link in
                LoginLandingView(link: link)
            }
            .fullScreenCover(isPresented: $showingLessons, onDismiss: {
                if returnToLessonEntry {
                    returnToLessonEntry = false
                    tab = .practice
                }
            }) {
                BrowseVideoListView(returnToLinkInput: {
                    returnToLessonEntry = true
                    showingLessons = false
                })
            }
            .overlay(alignment: .top) {
                if !showingLessons { DownloadCompletionNotice().padding(.top, 8) }
            }
            .onChange(of: library.listRequest) { _, request in
                if let request {
                    loginLanding = nil
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
            LibraryView(edit: { editing = EditorPresentation(movie: $0) },
                        browseVideos: browseVideos,
                        openEditor: { editing = EditorPresentation(movie: nil) },
                        openTools: { libraryPath = [.tools] },
                        openPlus: openPlus, openHistory: openHistory,
                        filter: $libraryFilter, importing: $importing, engaged: $libraryEngaged, selectedFolderID: $libraryFolderID)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: LibraryDestination.self) { destination in
                    switch destination {
                    case .tools:
                        ToolsView(openPlus: openPlus)
                            .toolbar(.hidden, for: .navigationBar)
                    case .history:
                        VideoHistoryView(edit: { editing = EditorPresentation(movie: $0) },
                                         review: { editing = EditorPresentation(movie: $0, tool: .ranges) })
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

    private func browseVideos() { showingLessons = true }

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
