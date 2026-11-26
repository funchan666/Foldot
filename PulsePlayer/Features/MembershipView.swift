import SwiftUI
import StoreKit

struct PlusEntryButton: View {
    enum Style { case compact, search, library }
    var style: Style = .compact
    let action: () -> Void
    @EnvironmentObject private var commerce: CommerceStore
    @Environment(\.dynamicTypeSize) private var typeSize

    private var active: Bool { commerce.hasVerifiedPlus }

    var body: some View {
        Button(action: action) {
            switch style {
            case .library:
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                    : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    HStack(spacing: 10) {
                        Glyph(symbol: .pass, size: 22, tint: PulsePlayerStyle.mediaAccent)
                        LocalizedText("PulsePlayer Plus").font(.capture(.headline, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        LocalizedText(active ? "Plus active" : "View plans")
                            .font(.capture(.subheadline, weight: .semibold))
                        Glyph(symbol: .back, size: 10, tint: PulsePlayerStyle.onDark)
                            .rotationEffect(.degrees(180))
                    }
                }
                .multilineTextAlignment(.leading)
                .foregroundStyle(PulsePlayerStyle.onDark)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 54)
                .pulsePlayerGlass(in: .rect(cornerRadius: 17), tint: PulsePlayerStyle.mediaSurface,
                                  fallback: PulsePlayerStyle.mediaSurface, onDark: true)
                .contentShape(.interaction, .rect(cornerRadius: 17))
            case .compact, .search:
                let prominent = style == .search
                let ink = prominent ? PulsePlayerStyle.onDark : PulsePlayerStyle.accent
                HStack(spacing: 7) {
                    Glyph(symbol: .pass, size: prominent ? 18 : 15, tint: ink)
                    LocalizedText(active ? "Plus active" : (prominent ? "Get Plus" : "Plus"))
                        .font(.capture(prominent ? .subheadline : .footnote, weight: .semibold))
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, prominent ? 15 : 12).padding(.vertical, 5)
                .frame(minHeight: prominent ? 44 : 32)
                .foregroundStyle(ink)
                .pulsePlayerGlass(in: Capsule(), tint: prominent ? PulsePlayerStyle.accent : PulsePlayerStyle.accent.opacity(0.12),
                                  fallback: prominent ? PulsePlayerStyle.accent : PulsePlayerStyle.raised, onDark: prominent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(Text("PulsePlayer Plus"))
        .accessibilityValue(active ? Text("Plus active") : Text(verbatim: ""))
        .accessibilityHint(Text(LocalizedStringKey(active ? "View membership" : "View plans")))
        .accessibilityIdentifier(style == .search ? "search.membership" : "membership.tabEntry")
    }
}

struct MembershipView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var ads: RewardedAds
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var planTask: Task<Void, Never>?
    @State private var purchaseAction: PurchaseAction?
    @State private var purchaseTask: Task<Void, Never>?

    private enum PurchaseAction { case subscribe, restore }

    private var configuredPlans: [CommerceConfiguration.Product] { commerce.policy?.products ?? [] }

    private var plans: [SKProduct] {
        configuredPlans.compactMap { entry in
            commerce.products.first { $0.productIdentifier == entry.id }
        }.filter { !commerce.period($0, locale: locale).isEmpty }
    }
    private var selectedPlan: SKProduct? {
        plans.first(where: { $0.productIdentifier == selectedID }) ?? plans.first
    }
    private var purchasing: Bool { commerce.preparingPurchase || commerce.busy || purchaseTask != nil }
    private var loadingCatalog: Bool { planTask != nil || commerce.loadingPlans }
    private var interactionLocked: Bool { purchasing || loadingCatalog || ads.busy || ads.isPresenting }

    var body: some View {
        GeometryReader { viewport in
            let bounds = CGRect(origin: .zero, size: viewport.size)
            let hasFold = PulsePlayerStyle.intersectsReservedRegion(bounds, in: viewport)
            let sideBySide = PulsePlayerStyle.pageContentWidth(in: viewport) >= 310 && typeSize <= .xLarge && !hasFold
            let dockCheckout = viewport.size.height >= 570 && typeSize <= .xxLarge && !hasFold
            ScrollViewReader { scroll in
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            membershipIntroduction(sideBySide: sideBySide)

                            VStack(alignment: .leading, spacing: 12) {
                                if purchaseAction != nil || commerce.canRetryPurchaseConfirmation { purchaseFeedback }
                                if commerce.premium {
                                    activeMembership
                                } else {
                                    planSelection(sideBySide: sideBySide)
                                }
                            }
                            .pulsePlayerKeepControlsTogether()
                            .id("purchaseStatus")

                            if !dockCheckout { purchaseControls }
                            VStack(alignment: .leading, spacing: 0) {
                                restoreButton { scroll.scrollTo("purchaseStatus", anchor: .top) }
                                PolicyLinks(style: .buttons)
                            }
                        }
                        .pulsePlayerPage()
                    }
                    if dockCheckout {
                        purchaseControls
                            .pageHorizontalMargins()
                            .frame(maxWidth: 680)
                            .padding(.bottom, 12)
                    }
                }
                .onChange(of: commerce.error ?? commerce.message) { _, feedback in
                    if feedback != nil, purchaseAction != nil || commerce.canRetryPurchaseConfirmation {
                        scroll.scrollTo("purchaseStatus", anchor: .top)
                    }
                }
            }
        }
        .pulsePlayerScreenBackground()
        .foregroundStyle(PulsePlayerStyle.paper).tint(PulsePlayerStyle.accent)
        .task { await commerce.refresh() }
        .task { await commerce.loadPlans() }
        .onDisappear {
            planTask?.cancel()
            planTask = nil
            purchaseTask?.cancel()
            purchaseTask = nil
        }
        .interactiveDismissDisabled(purchasing || ads.isPresenting)
    }

    @ViewBuilder private var purchaseControls: some View {
        if commerce.canRetryPurchaseConfirmation {
            ActionButton(title: "Retry purchase confirmation", primary: false, busy: purchasing) {
                purchaseAction = .subscribe
                purchaseTask = Task {
                    await commerce.retryPurchaseConfirmation()
                    purchaseTask = nil
                }
            }.disabled(interactionLocked).accessibilityIdentifier("membership.retryPurchase")
        } else if !commerce.premium, !configuredPlans.isEmpty {
            VStack(spacing: 10) {
                if !loadingCatalog, let selectedPlan { renewalDisclosure(for: selectedPlan) }
                checkoutButton
            }
            .multilineTextAlignment(.center)
            .pulsePlayerKeepControlsTogether()
        }
    }

    private func membershipIntroduction(sideBySide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Glyph(symbol: .pass, size: 21, tint: PulsePlayerStyle.mediaAccent)
                LocalizedText("PulsePlayer Plus")
                    .font(.capture(.headline, weight: .semibold))
                    .foregroundStyle(PulsePlayerStyle.onDark)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Button { dismiss() } label: {
                    Glyph(symbol: .close, size: 15, tint: PulsePlayerStyle.onDark)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(Text("Close"))
                .accessibilityValue(Text("PulsePlayer Plus"))
                .disabled(purchasing || ads.isPresenting)
            }

            Divider().overlay(PulsePlayerStyle.mediaSecondary.opacity(0.35))

            if sideBySide {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        viewingBenefit.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 20)
                        launchBenefit.fixedSize(horizontal: true, vertical: false)
                    }
                    stackedBenefits
                }
            } else {
                stackedBenefits
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 20)
        .pulsePlayerGlass(in: .rect(cornerRadius: 22), tint: PulsePlayerStyle.mediaSurface,
                          fallback: PulsePlayerStyle.mediaSurface, interactive: false, onDark: true)
        .pulsePlayerKeepControlsTogether()
    }

    private var stackedBenefits: some View {
        VStack(alignment: .leading, spacing: 14) {
            viewingBenefit
            launchBenefit
        }
    }

    private var viewingBenefit: some View {
        membershipBenefit(LocalizedText("Unlimited"), caption: "Daily views & downloads",
                          spokenLabel: "No daily viewing or download limits")
    }

    private var launchBenefit: some View {
        membershipBenefit(Text(0, format: .number), caption: "Ads at launch",
                          spokenLabel: "Skip opening ads")
    }

    private func membershipBenefit(_ value: some View, caption: String, spokenLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            value.font(.capture(.title, weight: .semibold)).foregroundStyle(PulsePlayerStyle.mediaAccent)
            LocalizedText(caption).font(.capture(.subheadline)).foregroundStyle(PulsePlayerStyle.onDark)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: L10n.display(spokenLabel, language: AppLanguage.from(locale))))
    }

    private var activeMembership: some View {
        VStack(alignment: .leading, spacing: 6) {
            LocalizedText("Plus active").font(.capture(.headline)).foregroundStyle(PulsePlayerStyle.accent)
            if let expiration = commerce.expiration {
                let date = expiration.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
                LocalizedText("Access through %@.", date)
                    .font(.capture(.subheadline)).foregroundStyle(PulsePlayerStyle.secondary)
            }
            if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                Link(destination: url) {
                    LocalizedText("Manage subscription").font(.capture(.footnote, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(PulsePlayerStyle.accent)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .pulsePlayerGlass(in: Capsule(), fallback: PulsePlayerStyle.raised)
                        .contentShape(.interaction, Capsule())
                }.buttonStyle(PressStyle())
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .pulsePlayerGlass(in: .rect(cornerRadius: 18), interactive: false)
    }

    @ViewBuilder private var purchaseFeedback: some View {
        if let error = commerce.error {
            ErrorNote(message: error)
        } else if let message = commerce.message {
            LocalizedText(message).font(.capture(.subheadline)).foregroundStyle(PulsePlayerStyle.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func planSelection(sideBySide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if configuredPlans.isEmpty {
                EmptyStateScene(appearance: .inline(.pass), message: "Subscription setup is incomplete. Please contact support.")
            } else {
                if !plans.isEmpty {
                    LocalizedText("Choose a plan")
                        .font(.capture(.headline)).accessibilityAddTraits(.isHeader)
                    let columnCount = sideBySide ? min(plans.count, 2) : 1
                    let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: columnCount)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(plans, id: \.productIdentifier) { product in planOption(product) }
                    }
                }
                if !loadingCatalog, plans.count < configuredPlans.count {
                    EmptyStateScene(appearance: .inline(.pass),
                                    message: commerce.plansError ?? "This plan isn’t available from Apple yet. Please try again later.")
                    if selectedPlan != nil {
                        Button(action: reloadPlans) {
                            LocalizedText("Reload plans")
                        }
                        .buttonStyle(CompactActionStyle())
                        .disabled(interactionLocked)
                    }
                }
            }
            if api.session == nil { ConnectionPanel() }
        }
    }

    private var purchaseButtonTitle: String {
        if commerce.preparingPurchase { return "Preparing purchase…" }
        if commerce.busy { return "Checking purchases…" }
        if loadingCatalog { return "Loading plans…" }
        return selectedPlan == nil ? "Check price" : "Subscribe to PulsePlayer Plus"
    }

    private func planOption(_ product: SKProduct) -> some View {
        let selected = selectedPlan?.productIdentifier == product.productIdentifier
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return Button { selectedID = product.productIdentifier } label: {
            VStack(alignment: .leading, spacing: 10) {
                planName(product)
                    .font(.capture(.subheadline, weight: .medium))
                Text(verbatim: commerce.price(product))
                    .font(.capture(.title, weight: .semibold))
                    .monospacedDigit()
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .foregroundStyle(selected ? PulsePlayerStyle.accent : PulsePlayerStyle.paper)
            .pulsePlayerGlass(in: shape, tint: selected ? PulsePlayerStyle.accent.opacity(0.15) : nil,
                              fallback: selected ? PulsePlayerStyle.mist : PulsePlayerStyle.raised)
            .overlay {
                if selected { shape.strokeBorder(PulsePlayerStyle.accent, lineWidth: 2).allowsHitTesting(false) }
            }
            .contentShape(.interaction, shape)
        }
        .buttonStyle(PressStyle())
        .disabled(interactionLocked)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("membership.plan.\(product.productIdentifier)")
    }

    private func billingCopy(for product: SKProduct) -> (name: String, renewal: String)? {
        guard let period = product.subscriptionPeriod else { return nil }
        switch (period.unit, period.numberOfUnits) {
        case (.week, 1), (.day, 7): return ("Weekly", "Renews automatically at %@ per week until canceled.")
        case (.month, 1): return ("Monthly", "Renews automatically at %@ per month until canceled.")
        case (.year, 1): return ("Yearly", "Renews automatically at %@ per year until canceled.")
        default: return nil
        }
    }

    @ViewBuilder private func planName(_ product: SKProduct) -> some View {
        if let copy = billingCopy(for: product) {
            LocalizedText(copy.name)
        } else {
            Text(verbatim: commerce.period(product, locale: locale))
        }
    }

    private func renewalDisclosure(for plan: SKProduct) -> some View {
        let price = commerce.price(plan)
        return Group {
            if let copy = billingCopy(for: plan) {
                LocalizedText(copy.renewal, price)
            } else {
                LocalizedText("%@ every %@. Renews automatically until canceled.", price, commerce.period(plan, locale: locale))
            }
        }
        .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var checkoutButton: some View {
        let canShowOffer = selectedPlan != nil && !loadingCatalog
        return Button { if canShowOffer { subscribe() } else { reloadPlans() } } label: {
            HStack(spacing: 8) {
                if purchasing || loadingCatalog { ProgressView().tint(PulsePlayerStyle.accent) }
                LocalizedText(purchaseButtonTitle).font(.capture(.headline, weight: .semibold))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(PulsePlayerStyle.ink)
            .pulsePlayerGlass(in: Capsule(), tint: PulsePlayerStyle.accent, fallback: PulsePlayerStyle.accent, onDark: true)
            .contentShape(.interaction, Capsule())
        }
        .buttonStyle(PressStyle())
        .disabled(interactionLocked || (canShowOffer && api.session == nil))
        .accessibilityIdentifier(canShowOffer ? "membership.subscribe" : "membership.retryPlans")
    }

    private func reloadPlans() {
        guard !interactionLocked else { return }
        planTask = Task {
            await commerce.loadPlans()
            planTask = nil
        }
    }

    private func subscribe() {
        guard !interactionLocked, let plan = selectedPlan else { return }
        purchaseAction = .subscribe
        purchaseTask = Task {
            await commerce.purchase(planID: plan.productIdentifier)
            purchaseTask = nil
        }
    }

    private func restoreButton(onRestore: @escaping () -> Void) -> some View {
        Button {
            purchaseAction = .restore
            commerce.restore()
            onRestore()
        } label: {
            LocalizedText("Restore purchases")
                .font(.capture(.subheadline, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .foregroundStyle(PulsePlayerStyle.accent)
                .contentShape(Rectangle())
        }.disabled(interactionLocked).buttonStyle(PressStyle())
            .accessibilityIdentifier("membership.restore")
    }
}

enum SettingsPage: Hashable {
    case storage, usage, language, history, browse
    case editor(UUID, VideoTool)
    case document(PolicyDocument)
}

struct AccountView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var ads: RewardedAds
    @EnvironmentObject private var accountAccess: AccountAccessFlow
    let openFavorites: () -> Void
    let openFolders: () -> Void
    let openSearch: () -> Void
    @EnvironmentObject private var library: LibraryStore
    @AppStorage(LocalPlaybackResume.enabledKey) private var resumesPlayback = true
    @AppStorage(LocalPlaybackPreferences.speedKey) private var defaultLocalSpeed = 1.0
    @AppStorage(LocalPlaybackPreferences.loopKey) private var loopsLocalPlayback = false
    @AppStorage(LocalPlaybackPreferences.rewindKey) private var rewindSeconds = LocalPlaybackPreferences.defaultRewind
    @AppStorage(LocalPlaybackPreferences.pauseBetweenFoldsKey) private var pauseBetweenFolds = false
    @Binding var path: [SettingsPage]
    @State private var pickingSpeed = false
    @State private var paywall = false

    private var unavailable: Bool {
        accountAccess.isBusy || commerce.busy || commerce.preparingPurchase || ads.busy || ads.isPresenting
    }

    var body: some View {
        ScenePage(scrollsBehindTabBar: true) { container in
            let width = min(640, PulsePlayerStyle.pageContentWidth(in: container))
            let hasFold = PulsePlayerStyle.intersectsReservedRegion(CGRect(origin: .zero, size: container.size), in: container)
            VStack(alignment: .leading, spacing: 24) {
                membershipEntry
                    .pulsePlayerKeepControlsTogether()
                if api.configuration.websiteURL != nil || api.configuration.termsURL != nil || api.configuration.privacyURL != nil {
                    PolicyLinks(style: .settings, navigate: { path.append(.document($0)) })
                        .disabled(unavailable || ads.isPreparingAppOpen)
                }
                playbackSettings(stacked: width < 300 || typeSize > .xLarge || hasFold)
                    .pulsePlayerKeepControlsTogether()
                libraryShortcuts(width: hasFold ? 0 : width)
                    .pulsePlayerKeepControlsTogether()
                VStack(alignment: .leading, spacing: 0) {
                    if api.session != nil {
                        settingsDestination("Daily limits", symbol: .download) { path.append(.usage) }
                            .accessibilityIdentifier("account.usageDetails")
                    } else {
                        ConnectionPanel()
                    }
                    AccountSettingsSection(unavailable: unavailable || ads.isPreparingAppOpen, openLanguage: { path.append(.language) })
                }
                .pulsePlayerKeepControlsTogether()
            }
        }
        .fullScreenCover(isPresented: $paywall) { MembershipView() }
        .sheet(isPresented: $pickingSpeed) { localSpeedPicker }
        .navigationDestination(for: SettingsPage.self) { page in
            Group {
                switch page {
                case .history:
                    VideoHistoryView(browseVideos: { path.append(.browse) },
                                     edit: { path.append(.editor($0.id, .studio)) },
                                     review: { path.append(.editor($0.id, .ranges)) })
                case .browse: BrowseVideoListView(returnToLinkInput: openSearch)
                case .editor(let id, let tool):
                    EditorSheet(initialMovie: library.movies.first { $0.id == id }, initialTool: tool, pushed: true)
                case .storage: VideoStorageView()
                case .usage: DailyLimitsView()
                case .language: LanguagePicker()
                case .document(let document): PolicyBrowser(document: document, pushed: true)
                }
            }
            .toolbar(.hidden, for: .navigationBar, .tabBar)
        }
    }

    private var membershipEntry: some View {
        let active = commerce.hasVerifiedPlus
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        return Button { paywall = true } label: {
            layout {
                Glyph(symbol: .pass, size: 30, tint: PulsePlayerStyle.accent)
                VStack(alignment: .leading, spacing: 3) {
                    LocalizedText("PulsePlayer Plus")
                        .font(.capture(.title3, weight: .bold))
                        .foregroundStyle(PulsePlayerStyle.paper)
                    LocalizedText(active ? "Plus active" : "View plans")
                        .font(.capture(.subheadline, weight: .medium))
                        .foregroundStyle(PulsePlayerStyle.accent)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !typeSize.isAccessibilitySize {
                    Glyph(symbol: .back, size: 12, tint: PulsePlayerStyle.ink)
                        .rotationEffect(.degrees(180))
                        .frame(width: 32, height: 32)
                        .background(PulsePlayerStyle.accent, in: Circle())
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .pulsePlayerGlass(in: .rect(cornerRadius: 20), tint: PulsePlayerStyle.accent.opacity(0.20),
                              fallback: PulsePlayerStyle.mist)
            .contentShape(.interaction, .rect(cornerRadius: 20))
        }
        .buttonStyle(PressStyle())
        .disabled(unavailable)
        .accessibilityLabel(Text("PulsePlayer Plus"))
        .accessibilityValue(active ? Text("Plus active") : Text(verbatim: ""))
        .accessibilityHint(Text(LocalizedStringKey(active ? "View membership" : "View plans")))
        .accessibilityIdentifier("account.membership")
    }

    private func playbackSettings(stacked: Bool) -> some View {
        let speed = LocalPlaybackPreferences.label(LocalPlaybackPreferences.speed(defaultLocalSpeed), locale: locale)
        let header = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                             : AnyLayout(HStackLayout(spacing: 12))
        return VStack(alignment: .leading, spacing: 4) {
            header {
                SectionLabel(title: "Local playback")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Button { pickingSpeed = true } label: {
                    HStack(spacing: 8) {
                        LocalizedText("Default speed").font(.capture(.footnote, weight: .medium))
                        Text(verbatim: speed).font(.capture(.subheadline, weight: .bold)).monospacedDigit()
                    }
                    .foregroundStyle(PulsePlayerStyle.accent)
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .pulsePlayerGlass(in: Capsule(), fallback: PulsePlayerStyle.mist)
                    .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(LocalizedStringKey("Default speed"))
                .accessibilityValue(Text(verbatim: speed))
                .accessibilityIdentifier("settings.defaultLocalSpeed")
            }
            VStack(spacing: 0) {
                rewindSetting(stacked: stacked)
                Divider()
                Toggle(isOn: $pauseBetweenFolds) {
                    VStack(alignment: .leading, spacing: 3) {
                        LocalizedText("Pause between folds")
                        LocalizedText("In hands-free practice, tap play to start the next fold.")
                            .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                }
                .frame(minHeight: 48)
                .accessibilityIdentifier("settings.pauseBetweenFolds")
                Divider()
                Toggle(isOn: $resumesPlayback) { LocalizedText("Resume playback") }
                    .frame(minHeight: 48)
                    .accessibilityHint("Continue local videos from the last position.")
                    .accessibilityIdentifier("settings.resumePlayback")
                Divider()
                Toggle(isOn: $loopsLocalPlayback) { LocalizedText("Loop playback") }
                    .frame(minHeight: 48)
                    .accessibilityIdentifier("settings.loopLocalPlayback")
            }
            .padding(.horizontal, 14)
            .background(PulsePlayerStyle.surface, in: .rect(cornerRadius: 16))
            .font(.capture(.subheadline, weight: .medium)).tint(PulsePlayerStyle.accent)
        }
    }

    private func rewindSetting(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                             : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            LocalizedText("Rewind by").frame(maxWidth: .infinity, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) { rewindChoices }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 2) { rewindChoices }
            }
        }
        .padding(.vertical, 4)
    }

    private var rewindChoices: some View {
        ForEach(LocalPlaybackPreferences.rewindChoices, id: \.self) { seconds in
            let selected = LocalPlaybackPreferences.rewindSeconds(rewindSeconds) == seconds
            Button { rewindSeconds = seconds } label: {
                Text(Duration.seconds(seconds), format: .units(allowed: [.seconds], width: .abbreviated))
                    .font(.capture(.subheadline, weight: selected ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(selected ? PulsePlayerStyle.accent : PulsePlayerStyle.secondary)
                    .padding(.horizontal, 8).frame(minWidth: 44, minHeight: 32)
                    .background(selected ? PulsePlayerStyle.mist : Color.clear, in: Capsule())
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(Text(verbatim: L10n.format("Back %@ seconds", [seconds.formatted(.number.locale(locale))],
                                                           language: .from(locale))))
        }
    }

    private func libraryShortcuts(width: CGFloat) -> some View {
        let count = width < 280 || typeSize.isAccessibilitySize ? 1 : (width >= 580 && typeSize <= .xLarge ? 4 : 2)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: count)
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Library").accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                shortcut("Recently opened", symbol: .play) { path.append(.history) }
                shortcut("Favorites", symbol: .bookmark, action: openFavorites)
                shortcut("Folders", symbol: .folder, action: openFolders)
                shortcut("Video storage", symbol: .library) { path.append(.storage) }
                    .accessibilityIdentifier("settings.videoStorage")
            }
        }
    }

    private func shortcut(_ title: String, symbol: PulsePlayerGlyph, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Glyph(symbol: symbol, size: 17, tint: PulsePlayerStyle.accent)
                LocalizedText(title).font(.capture(.subheadline, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .pulsePlayerGlass(in: .rect(cornerRadius: 14), fallback: PulsePlayerStyle.surface)
            .contentShape(.interaction, .rect(cornerRadius: 14))
        }
        .buttonStyle(PressStyle())
    }

    private func settingsDestination(_ title: String, symbol: PulsePlayerGlyph,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Glyph(symbol: symbol, size: 18, tint: PulsePlayerStyle.secondary)
                LocalizedText(title).font(.capture(.body, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Glyph(symbol: .back, size: 11, tint: PulsePlayerStyle.secondary).rotationEffect(.degrees(180))
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .overlay(alignment: .top) { Divider() }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private var localSpeedPicker: some View {
        VStack(spacing: 0) {
            SheetToolbar(context: "Default speed") { pickingSpeed = false }
            ScrollView {
                let columns = [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 134 : 84), spacing: 10)]
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(LocalPlaybackPreferences.speeds, id: \.self) { rate in
                        let selected = LocalPlaybackPreferences.speed(defaultLocalSpeed) == rate
                        Button {
                            defaultLocalSpeed = Double(rate)
                            pickingSpeed = false
                        } label: {
                            Text(verbatim: LocalPlaybackPreferences.label(rate, locale: locale))
                                .font(.capture(.headline, weight: selected ? .bold : .regular)).monospacedDigit()
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(8)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .foregroundStyle(selected ? PulsePlayerStyle.accent : PulsePlayerStyle.paper)
                                .pulsePlayerGlass(in: Capsule(), tint: selected ? PulsePlayerStyle.accent.opacity(0.18) : nil,
                                                  fallback: selected ? PulsePlayerStyle.mist : PulsePlayerStyle.raised)
                                .overlay {
                                    if selected {
                                        Capsule().strokeBorder(PulsePlayerStyle.accent, lineWidth: 1.5).allowsHitTesting(false)
                                    }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PressStyle())
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .pulsePlayerKeepControlsTogether()
                .pulsePlayerPage()
            }
        }
        .foregroundStyle(PulsePlayerStyle.paper)
        .pulsePlayerScreenBackground()
        .presentationDetents([.medium, .large])
    }
}

private struct DailyLimitsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var ads: RewardedAds
    @EnvironmentObject private var accountAccess: AccountAccessFlow
    @State private var reward: AllowanceKind?
    @State private var paywall = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if commerce.rightsVerified {
                        LocalizedText(commerce.premium ? "Plus active" : "Free plan")
                            .font(.capture(.subheadline, weight: .semibold))
                            .foregroundStyle(PulsePlayerStyle.secondary)
                    }
                    AllowanceStatusPanel(compact: false)
                    if !commerce.premium {
                        let kinds = AllowanceKind.allCases.filter { quota.canRequestReward(for: $0, premium: false) }
                        if kinds.isEmpty {
                            Button { paywall = true } label: { LocalizedText("Get more") }
                                .accessibilityLabel("Get more daily views and downloads")
                        } else {
                            ForEach(kinds) { kind in
                                Button { reward = kind } label: {
                                    LocalizedText(kind == .watch ? "Get more views" : "Get more downloads")
                                }
                            }
                        }
                    }
                }
                .buttonStyle(CompactActionStyle())
                .disabled(accountAccess.isBusy || commerce.busy || commerce.preparingPurchase || ads.busy || ads.isPresenting)
                .pulsePlayerKeepControlsTogether()
                .pulsePlayerPage()
            }
        }
        .foregroundStyle(PulsePlayerStyle.paper)
        .pulsePlayerScreenBackground()
        .sceneBack(context: "Daily limits") { dismiss() }
        .fullScreenCover(item: $reward) { kind in AllowanceLimitPrompt(kind: kind) }
        .fullScreenCover(isPresented: $paywall) { MembershipView() }
    }
}

private struct VideoStorageView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var offline: OfflineStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var importing = false
    @State private var sizes: [URL: Int64] = [:]
    @State private var measuredURLs: [URL]?
    @State private var removing: StoredFile?
    @State private var removalError: String?

    private enum StoredFile: Identifiable {
        case library(PracticeRecording, URL)
        case download(OfflineVideo, URL)

        var id: String {
            switch self {
            case .library(let movie, _): "library-\(movie.id)"
            case .download(let video, _): "download-\(video.owner)-\(video.id)"
            }
        }

        var url: URL {
            switch self {
            case .library(_, let url), .download(_, let url): url
            }
        }

        var title: String {
            switch self {
            case .library(let movie, _): movie.displayFilename
            case .download(let video, _): video.displayFilename
            }
        }

        var category: String {
            switch self {
            case .library(let movie, _): movie.isExport ? "Exports" : "Imports"
            case .download: "Offline"
            }
        }

        var isAudio: Bool {
            if case .library(let movie, _) = self { return movie.isAudio }
            return false
        }

        var isDownload: Bool {
            if case .download = self { return true }
            return false
        }
    }

    var body: some View {
        let files = library.movies.map { StoredFile.library($0, library.url(for: $0)) } + offline.videos
            .filter { !$0.relativePath.isEmpty || ($0.isHLS && $0.systemAssetURL?.isFileURL == true) }
            .map { StoredFile.download($0, $0.url) }
        let urls = files.map(\.url)
        let measuring = !files.isEmpty && measuredURLs != urls

        ScenePage { container in
            let width = PulsePlayerStyle.pageContentWidth(in: container)
            let divided = PulsePlayerStyle.intersectsReservedRegion(CGRect(origin: .zero, size: container.size), in: container)
            let stacked = width < 300 || divided || typeSize.isAccessibilitySize
            VStack(alignment: .leading, spacing: 18) {
                storageSummary(files, measuring: measuring, stacked: stacked)
                if let removalError { ErrorNote(message: removalError) }
                if files.isEmpty {
                    LocalizedText("No stored files")
                        .font(.capture(.subheadline)).foregroundStyle(PulsePlayerStyle.secondary)
                }
                VideoImportActions(onImported: { _ in }, importing: $importing,
                                   presentation: files.isEmpty ? .sources(stacked: stacked) : .menu(title: "Import"))
                LazyVStack(spacing: 0) {
                    ForEach(files.sorted(by: storageOrder)) { file in
                        storageRow(file, measuring: measuring)
                        Divider().accessibilityHidden(true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sceneBack(context: "Video storage", disabled: importing) { dismiss() }
        .navigationBarBackButtonHidden(importing)
        .task(id: urls) { await measure(urls) }
        .sheet(item: $removing) { file in removalSheet(file) }
    }

    private func storageSummary(_ files: [StoredFile], measuring: Bool, stacked: Bool) -> some View {
        let categories = ["Imports", "Offline", "Exports"]
        let counts = Dictionary(grouping: files, by: \.category).mapValues(\.count)
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                             : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Glyph(symbol: .library, size: 18, tint: PulsePlayerStyle.mediaAccent)
                LocalizedText("Stored files").font(.capture(.subheadline, weight: .medium))
            }
            if measuring {
                HStack(spacing: 8) {
                    ProgressView().tint(PulsePlayerStyle.mediaAccent).accessibilityHidden(true)
                    LocalizedText("Loading…").font(.capture(.subheadline))
                }
            } else if !files.isEmpty && sizes.isEmpty {
                LocalizedText("Size unavailable").font(.capture(.headline))
            } else {
                Text(verbatim: displaySize(files.isEmpty ? 0 : sizes.values.reduce(0, +)))
                    .font(.capture(.largeTitle, weight: .bold)).monospacedDigit()
                if files.contains(where: { sizes[$0.url] == nil }) {
                    LocalizedText("Some file sizes could not be read.").font(.capture(.footnote))
                }
            }
            Divider().overlay(PulsePlayerStyle.mediaSecondary.opacity(0.45)).accessibilityHidden(true)
            layout {
                ForEach(categories, id: \.self) { category in
                    let cell = stacked ? AnyLayout(HStackLayout(spacing: 8))
                                       : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    cell {
                        Text(counts[category, default: 0], format: .number)
                            .font(.capture(.headline, weight: .semibold)).monospacedDigit()
                        LocalizedText(category)
                            .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.mediaSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .foregroundStyle(PulsePlayerStyle.onDark)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PulsePlayerStyle.mediaSurface, in: .rect(cornerRadius: 22))
        .pulsePlayerKeepControlsTogether()
    }

    private func storageRow(_ file: StoredFile, measuring: Bool) -> some View {
        HStack(spacing: 12) {
            VideoFileThumbnail(url: file.url, isAudio: file.isAudio)
                .frame(width: 64, height: 48)
                .clipShape(.rect(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: file.title).font(.capture(.subheadline, weight: .semibold))
                LocalizedText(file.category).font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.secondary)
                Group {
                    if measuring { Text(verbatim: "…") }
                    else if let bytes = sizes[file.url] { Text(verbatim: displaySize(bytes)) }
                    else { LocalizedText("Size unavailable") }
                }
                .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            IconButton(symbol: .close, label: file.isDownload ? "Remove download" : "Delete local copy", glass: true) {
                removalError = nil
                removing = file
            }
            .accessibilityHint(Text(verbatim: file.title))
        }
        .padding(.vertical, 10)
    }

    private func removalSheet(_ file: StoredFile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SheetToolbar(context: file.isDownload ? "Remove offline video?" : "Delete this local copy?", showsConfirmation: true) {
                    removing = nil
                }
                Text(verbatim: file.title).font(.capture(.headline))
                    .fixedSize(horizontal: false, vertical: true)
                LocalizedText(file.isDownload ? "This removes the download from this device."
                                              : "This deletes the selected copy from your PulsePlayer library.")
                    .foregroundStyle(PulsePlayerStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ActionButton(title: file.isDownload ? "Remove download" : "Delete local copy") {
                    remove(file)
                    removing = nil
                }
                ActionButton(title: "Cancel", primary: false) { removing = nil }
            }
            .pulsePlayerPage()
        }
        .foregroundStyle(PulsePlayerStyle.paper)
        .pulsePlayerScreenBackground()
        .presentationDetents([.medium, .large])
    }

    private func remove(_ file: StoredFile) {
        let succeeded: Bool
        switch file {
        case .library(let movie, let url):
            guard library.movies.contains(where: { $0.id == movie.id && library.url(for: $0) == url }) else { return }
            library.delete(movie)
            succeeded = !library.movies.contains(where: { $0.id == movie.id })
                && !FileManager.default.fileExists(atPath: url.path)
        case .download(let video, _):
            succeeded = offline.remove(video)
        }
        if !succeeded { removalError = "Couldn’t remove the stored file." }
    }

    private func storageOrder(_ first: StoredFile, _ second: StoredFile) -> Bool {
        let firstSize = sizes[first.url] ?? -1
        let secondSize = sizes[second.url] ?? -1
        if firstSize == secondSize { return first.title.localizedStandardCompare(second.title) == .orderedAscending }
        return firstSize > secondSize
    }

    private func displaySize(_ bytes: Int64) -> String {
        bytes.formatted(ByteCountFormatStyle(style: .file, spellsOutZero: false, locale: locale))
    }

    private func measure(_ urls: [URL]) async {
        let scan = Task.detached(priority: .utility) {
            var result: [URL: Int64] = [:]
            for url in Set(urls) {
                if Task.isCancelled { break }
                result[url] = Self.storedBytes(at: url)
            }
            return result
        }
        let result = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
        guard !Task.isCancelled else { return }
        sizes = result
        measuredURLs = urls
    }

    private nonisolated static func storedBytes(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return nil }
        if values.isRegularFile == true { return values.fileSize.map { Int64($0) } }
        guard values.isDirectory == true, url.pathExtension.lowercased() == "movpkg" else { return nil }

        // An offline HLS asset stores its media in a package of several files.
        var unreadable = false
        guard let contents = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                           errorHandler: { _, _ in unreadable = true; return false }) else { return nil }
        var bytes: Int64 = 0
        for case let child as URL in contents {
            guard !Task.isCancelled, let childValues = try? child.resourceValues(forKeys: keys) else { return nil }
            if childValues.isSymbolicLink == true {
                contents.skipDescendants()
            } else if childValues.isRegularFile == true {
                guard let fileSize = childValues.fileSize else { return nil }
                bytes += Int64(fileSize)
            }
        }
        return unreadable ? nil : bytes
    }
}

struct AllowanceStatusPanel: View {
    var kinds = AllowanceKind.allCases
    var onMedia = false
    var compact = true
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @State private var showsUsageDetails = false

    private var hasUsage: Bool { quota.usage != nil && quota.error == nil }
    private var canShowDetails: Bool { api.session != nil && hasUsage && !commerce.premium }
    private var detailsVisible: Bool { canShowDetails && (!compact || showsUsageDetails) }
    private var primaryText: Color { onMedia ? PulsePlayerStyle.onDark : PulsePlayerStyle.paper }
    private var secondaryText: Color { onMedia ? PulsePlayerStyle.mediaSecondary : PulsePlayerStyle.secondary }
    private var accent: Color { onMedia ? PulsePlayerStyle.mediaAccent : PulsePlayerStyle.accent }
    private var errorTint: Color { onMedia ? PulsePlayerStyle.mediaError : PulsePlayerStyle.danger }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if api.session == nil {
                LocalizedText("Connect to refresh your allowance.")
                    .font(.capture(.subheadline)).foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if commerce.premium || hasUsage {
                    if compact { balanceSummary } else { detailedAllowance }
                } else if quota.error == nil {
                    HStack(spacing: 10) {
                        ProgressView().tint(accent).accessibilityHidden(true)
                        LocalizedText("Loading daily limits…")
                            .font(.capture(.subheadline)).foregroundStyle(secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(minHeight: 44)
                }
                if let error = quota.error { ErrorNote(message: error, onMedia: onMedia) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { quota.resetIfNeeded() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in quota.resetIfNeeded() }
    }

    private var detailedAllowance: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(kinds) { kind in
                let unlimited = commerce.premium || quota.isUnlimited(kind)
                let remaining = quota.remaining(kind)
                let total = quota.totalAllowance(for: kind)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Glyph(symbol: kind == .watch ? .play : .download, size: 16, tint: accent)
                        LocalizedText(kind == .watch ? "Online viewing" : "Offline downloads")
                            .font(.capture(.subheadline)).foregroundStyle(secondaryText)
                    }
                    Group {
                        if unlimited {
                            LocalizedText("Unlimited")
                        } else {
                            LocalizedText("%@ left · %@ total today", remaining.formatted(.number.locale(locale)),
                                          total.formatted(.number.locale(locale)))
                        }
                    }
                    .font(.capture(.title3, weight: .semibold)).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    if !unlimited && total > 0 {
                        ProgressView(value: Double(min(remaining, total)), total: Double(total))
                            .progressViewStyle(.linear).tint(accent).accessibilityHidden(true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PulsePlayerStyle.surface, in: .rect(cornerRadius: 16))
                .accessibilityElement(children: .combine)
            }
            if detailsVisible { AllowanceResetText(tint: secondaryText) }
        }
    }

    private var balanceSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if canShowDetails {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        showsUsageDetails.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        balances
                        Glyph(symbol: .back, size: 12, tint: accent)
                            .environment(\.layoutDirection, .leftToRight)
                            .rotationEffect(.degrees(showsUsageDetails ? 90 : -90))
                            .frame(width: 32, height: 32)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityHint(Text(LocalizedStringKey(showsUsageDetails ? "Hide details" : "Usage details")))
                .accessibilityValue(Text(LocalizedStringKey(showsUsageDetails ? "Expanded" : "Collapsed")))
                .accessibilityIdentifier("account.usageDetails")
            } else {
                balances
            }
            if detailsVisible {
                ForEach(kinds) { kind in
                    if !quota.isUnlimited(kind) {
                        LocalizedText("%@ left · %@ total today", quota.remaining(kind).formatted(.number.locale(locale)),
                                      quota.totalAllowance(for: kind).formatted(.number.locale(locale)))
                            .font(.capture(.footnote)).monospacedDigit()
                            .foregroundStyle(secondaryText)
                    }
                }
                AllowanceResetText(tint: secondaryText)
            }
        }
        .padding(.vertical, 8)
        .pulsePlayerKeepControlsTogether()
    }

    private var balances: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(kinds) { kind in
                let unlimited = commerce.premium || quota.isUnlimited(kind)
                let remaining = quota.remaining(kind)
                let total = quota.totalAllowance(for: kind)
                if unlimited {
                    LocalizedText(kind == .watch ? "Online viewing" : "Offline downloads")
                        .font(.capture(.footnote)).foregroundStyle(secondaryText)
                    LocalizedText("Unlimited").foregroundStyle(accent)
                } else {
                    LocalizedText(kind == .watch ? "%@ views left today" : "%@ downloads left today",
                                  remaining.formatted(.number.locale(locale)))
                        .foregroundStyle(remaining == 0 ? errorTint : primaryText)
                    if total > 0 {
                        ProgressView(value: Double(min(remaining, total)), total: Double(total))
                            .progressViewStyle(.linear)
                            .tint(accent)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .font(.capture(.subheadline, weight: .semibold)).monospacedDigit()
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}
struct AllowanceResetText: View {
    var tint: Color = PulsePlayerStyle.secondary
    @Environment(\.locale) private var locale
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let next = QuotaStore.nextReset(after: context.date)
            LocalizedText("Resets %@ (local time)", localTime(next))
                .font(.capture(.caption)).foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func localTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

}
