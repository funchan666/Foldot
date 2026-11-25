import SwiftUI
import WebKit

@MainActor
final class AccountAccessFlow: ObservableObject {
    @Published private(set) var busyMessage: String?
    var isBusy: Bool { busyMessage != nil }

    func perform(_ message: String, operation: () async throws -> Void) async throws {
        guard !isBusy else { throw CancellationError() }
        busyMessage = message
        defer { busyMessage = nil }
        await Task.yield()
        try await operation()
    }
}

struct AccountLoadingIndicator: View {
    let title: String
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().tint(PulsePlayerStyle.accent).accessibilityHidden(true)
            LocalizedText(title).font(.capture(.subheadline, weight: .semibold)).multilineTextAlignment(.center)
        }.padding(22).frame(maxWidth: 250)
            .foregroundStyle(PulsePlayerStyle.paper)
            .pulsePlayerGlass(in: RoundedRectangle(cornerRadius: 16), tint: PulsePlayerStyle.surface.opacity(0.75), interactive: false)
            .accessibilityElement(children: .combine)
    }
}

struct AccountBusyModifier: ViewModifier {
    @EnvironmentObject private var accountAccess: AccountAccessFlow
    func body(content: Content) -> some View {
        content.allowsHitTesting(!accountAccess.isBusy)
            .accessibilityHidden(accountAccess.isBusy)
            .overlay {
                if let message = accountAccess.busyMessage {
                    ZStack {
                        Color.black.opacity(0.58).ignoresSafeArea()
                        AccountLoadingIndicator(title: message).padding(24)
                    }.accessibilityAddTraits(.isModal)
                }
            }
    }
}

// Native text/layout over the app's existing surfaces; no rendered text artwork.
struct AccountDecisionDialog: View {
    let title: String
    let message: String
    let confirmTitle: String
    var showsPolicies = false
    var destructive = false
    var cancel: (() -> Void)? = nil
    let confirm: () -> Void
    @AccessibilityFocusState private var titleFocused: Bool
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LocalizedText(title).font(.capture(.headline)).foregroundStyle(PulsePlayerStyle.paper)
                        .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
                    LocalizedText(message).font(.capture(.subheadline)).foregroundStyle(PulsePlayerStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsPolicies { PolicyLinks() }
                    PulsePlayerGlassGroup {
                        VStack(spacing: 10) {
                            Button(action: confirm) {
                                LocalizedText(confirmTitle).font(.capture(.subheadline, weight: .semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.center).padding(.horizontal, 16).padding(.vertical, 12)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .foregroundStyle(destructive ? PulsePlayerStyle.danger : PulsePlayerStyle.accent)
                                    .pulsePlayerGlass(in: RoundedRectangle(cornerRadius: 12),
                                                tint: (destructive ? PulsePlayerStyle.danger : PulsePlayerStyle.accent).opacity(0.12),
                                                fallback: destructive ? PulsePlayerStyle.surface : PulsePlayerStyle.mist)
                                    .contentShape(.interaction, RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(PressStyle())
                            if let cancel { ActionButton(title: "Cancel", primary: false, action: cancel) }
                        }
                    }
                }.padding(20).frame(maxWidth: 360)
                    .pulsePlayerPanel(cornerRadius: 16)
                    .padding(24).frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }.background(Color.black.opacity(0.68).ignoresSafeArea())
            .accessibilityAddTraits(.isModal)
            .interactiveDismissDisabled()
            .onAppear { titleFocused = true }
    }
}

struct PolicyDocument: Identifiable, Hashable {
    let title: String
    let url: URL
    var showsNavigation = false
    var id: String { url.absoluteString }
}

struct PolicyLinks: View {
    enum Style: Equatable { case buttons, settings }

    var style: Style = .buttons
    var navigate: ((PolicyDocument) -> Void)? = nil
    @EnvironmentObject private var api: APIClient
    @State private var document: PolicyDocument?

    var body: some View {
        Group {
            switch style {
            case .buttons:
                PulsePlayerGlassGroup { linkLayout.buttonStyle(CompactActionStyle()) }
            case .settings:
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        website
                        links
                    }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 0) {
                        website
                        linkLayout
                    }
                }
                .buttonStyle(PressStyle())
                .pulsePlayerKeepControlsTogether()
            }
        }
        .sheet(item: $document) { PolicyBrowser(document: $0) }
    }

    private func open(_ target: PolicyDocument) {
        if let navigate { navigate(target) } else { document = target }
    }

    @ViewBuilder private var website: some View {
        if let url = api.configuration.websiteURL {
            Button { open(PolicyDocument(title: "Official website", url: url, showsNavigation: true)) } label: {
                HStack(spacing: 8) {
                    Glyph(symbol: .link, size: 16, tint: PulsePlayerStyle.accent)
                    LocalizedText("Official website").font(.capture(.subheadline, weight: .semibold))
                }
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(PulsePlayerStyle.accent)
                .padding(.horizontal, 14).frame(minHeight: 44)
                .pulsePlayerGlass(in: Capsule(), fallback: PulsePlayerStyle.surface)
                .contentShape(Capsule())
            }
            .accessibilityIdentifier("account.officialWebsite")
        }
    }

    private var linkLayout: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: style == .settings ? 20 : 10) { links }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: style == .settings ? 0 : 10) { links }
        }.font(.capture(.footnote, weight: .medium)).foregroundStyle(PulsePlayerStyle.accent)
    }
    @ViewBuilder private var links: some View {
        if let url = api.configuration.termsURL {
            policyLink("Terms of Use", url: url)
        }
        if let url = api.configuration.privacyURL {
            policyLink("Privacy Policy", url: url)
        }
    }

    private func policyLink(_ title: String, url: URL) -> some View {
        Button { open(PolicyDocument(title: title, url: url)) } label: {
            switch style {
            case .settings:
                LocalizedText(title)
                    .font(.capture(.footnote, weight: .semibold))
                    .foregroundStyle(PulsePlayerStyle.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            case .buttons:
                LocalizedText(title)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
    }
}

struct AccountLinkLabel: View {
    let title: String
    var symbol: PulsePlayerGlyph? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Glyph(symbol: symbol, size: 16, tint: PulsePlayerStyle.accent)
                    .frame(width: 28, height: 28)
                    .background(PulsePlayerStyle.raised, in: RoundedRectangle(cornerRadius: 7))
            }
            LocalizedText(title).font(.capture(.subheadline, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Glyph(symbol: .back, size: 10, tint: PulsePlayerStyle.secondary).rotationEffect(.degrees(180))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .foregroundStyle(PulsePlayerStyle.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PulsePlayerStyle.line).frame(height: 1)
                .padding(.horizontal, 12)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

@MainActor
final class PolicyBrowserState: ObservableObject {
    @Published var loading = true
    @Published var error: String?
    @Published var requestID = 0
    @Published var canGoBack = false
    @Published var currentURL: URL?
    var retryURL: URL?
    weak var webView: WKWebView?
    func retry() { error = nil; loading = true; requestID += 1 }
    func goBack() { webView?.goBack() }
}

struct PolicyBrowser: View {
    let document: PolicyDocument
    var webSearch = false
    var pushed = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = PolicyBrowserState()
    private var showsBrowserNavigation: Bool { webSearch || document.showsNavigation }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if pushed {
                    IconButton(symbol: .back, label: "Back", glass: true) { dismiss() }
                        .accessibilityValue(Text(LocalizedStringKey(document.title)))
                }
                if showsBrowserNavigation && !pushed {
                    IconButton(symbol: .back, label: "Back", glass: true) { state.goBack() }
                        .disabled(!state.canGoBack)
                }
                Text(verbatim: state.currentURL?.host ?? document.url.host ?? "")
                    .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if !pushed {
                    IconButton(symbol: .close, label: "Close", glass: true) { dismiss() }
                        .accessibilityValue(Text(LocalizedStringKey(document.title)))
                } else if showsBrowserNavigation && state.canGoBack {
                    Button { state.goBack() } label: { LocalizedText("Back") }
                        .buttonStyle(CompactActionStyle())
                        .accessibilityValue(Text(verbatim: state.currentURL?.host ?? ""))
                }
            }
            .pulsePlayerKeepControlsTogether()
            .pageHorizontalMargins().padding(.vertical, 6)
            ZStack {
                PolicyWebView(url: document.url, state: state, webSearch: webSearch)
                    .accessibilityHidden(state.loading || state.error != nil)
                if let error = state.error {
                    PulsePlayerStyle.background
                    ScrollView {
                        MessagePanel(title: "Couldn’t open this page", message: error,
                                     actionTitle: "Try again", action: { state.retry() }).padding(24)
                    }
                } else if state.loading {
                    PulsePlayerStyle.background
                    AccountLoadingIndicator(title: showsBrowserNavigation ? "Opening page…" : "Opening document…").padding(24)
                }
            }
        }.pulsePlayerScreenBackground().foregroundStyle(PulsePlayerStyle.paper)
    }
}

struct PolicyWebView: UIViewRepresentable {
    let url: URL
    @ObservedObject var state: PolicyBrowserState
    var webSearch = false
    func makeCoordinator() -> Coordinator { Coordinator(state: state, webSearch: webSearch) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.allowsLinkPreview = !webSearch
        view.isOpaque = false
        state.webView = view
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.requestID != state.requestID else { return }
        context.coordinator.requestID = state.requestID
        context.coordinator.load(URLRequest(url: state.retryURL ?? url, timeoutInterval: 30), in: view)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.stopLoading()
        coordinator.state.webView = nil
    }
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let state: PolicyBrowserState
        let webSearch: Bool
        var requestID: Int?
        private var appNavigationURL: URL?
        init(state: PolicyBrowserState, webSearch: Bool) { self.state = state; self.webSearch = webSearch }
        func load(_ request: URLRequest, in webView: WKWebView) {
            appNavigationURL = request.url
            state.retryURL = request.url
            webView.load(request)
        }
        // Documents and search results have no camera or microphone use case.
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.loading = true
            state.error = nil
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            state.currentURL = webView.url
            state.canGoBack = webView.canGoBack
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.loading = false
            state.currentURL = webView.url
            state.canGoBack = webView.canGoBack
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            state.loading = false
            state.error = "The document was interrupted. Please try again."
        }
        private func fail(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            state.loading = false
            state.error = "Check your connection and try again."
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if !webSearch, url.scheme == "mailto", navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else if url.scheme == "https" || (webSearch && url.scheme == "http") || url.absoluteString == "about:blank" {
                if navigationAction.targetFrame?.isMainFrame != false { state.retryURL = url }
                if webSearch, navigationAction.targetFrame?.isMainFrame != false {
                    // Reissue page navigations as app loads so web links stay in this view.
                    if navigationAction.navigationType == .backForward ||
                        (navigationAction.targetFrame != nil && appNavigationURL == url) {
                        appNavigationURL = nil
                        decisionHandler(.allow)
                    } else {
                        decisionHandler(.cancel)
                        load(navigationAction.request, in: webView)
                    }
                    return
                }
                if navigationAction.targetFrame == nil {
                    webView.load(navigationAction.request)
                    decisionHandler(.cancel)
                } else { decisionHandler(.allow) }
            } else { decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame,
               let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
                state.loading = false
                state.error = "This document is temporarily unavailable. Please try again."
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
    }
}

struct AccountSettingsSection: View {
    @AppStorage(AppLanguage.preferenceKey) private var languageCode = AppLanguage.defaultSelection
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var ads: RewardedAds
    let unavailable: Bool
    let openLanguage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            languagePreference
            if ads.privacyOptionsRequired {
                Button { Task { await ads.privacyOptions() } } label: {
                    AccountLinkLabel(title: "Advertising privacy", symbol: .settings)
                }
                .buttonStyle(PressStyle())
                .disabled(unavailable || ads.isPreparingPrivacy)
                .accessibilityIdentifier("account.adPrivacy")
                if let message = ads.privacyOptionsError { ErrorNote(message: message) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { metadata }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 4) { metadata }
            }
            .font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.secondary)
            .padding(.top, 6)
        }
    }

    @ViewBuilder private var metadata: some View {
        LocalizedText("Version %@", api.configuration.version)
        if let id = api.session?.userId.value {
            LocalizedText("ID · %@", id).monospacedDigit().textSelection(.enabled)
        }
    }

    private var languagePreference: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button(action: openLanguage) {
            HStack(spacing: 12) {
                Glyph(symbol: .settings, size: 17, tint: PulsePlayerStyle.accent)
                    .frame(width: 30, height: 30)
                    .background(PulsePlayerStyle.raised, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    LocalizedText("App language").font(.capture(.subheadline, weight: .semibold))
                        .foregroundStyle(PulsePlayerStyle.paper)
                    Group {
                        if let language = AppLanguage(rawValue: languageCode) {
                            Text(verbatim: language.nativeName)
                        } else {
                            LocalizedText("Follow system")
                        }
                    }
                    .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Glyph(symbol: .back, size: 11, tint: PulsePlayerStyle.secondary).rotationEffect(.degrees(180))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .pulsePlayerGlass(in: shape)
            .contentShape(.interaction, shape)
        }
        .buttonStyle(PressStyle())
        .accessibilityIdentifier("account.language")
    }
}
