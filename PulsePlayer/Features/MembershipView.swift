import SwiftUI
import StoreKit

struct PlusEntryButton: View {
    let action: () -> Void

    var body: some View {
        let shape = Capsule()
        return Button(action: action) {
            HStack(spacing: 6) {
                Glyph(symbol: .pass, size: 15, tint: PulsePlayerStyle.accent)
                LocalizedText("Plus").font(.capture(.footnote, weight: .semibold))
            }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .frame(minHeight: 32)
                .foregroundStyle(PulsePlayerStyle.accent)
                .pulsePlayerGlass(in: shape, tint: PulsePlayerStyle.accent.opacity(0.12), fallback: PulsePlayerStyle.raised)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(LocalizedStringKey("PulsePlayer Plus"))
        .accessibilityIdentifier("membership.tabEntry")
    }
}

struct MembershipView: View {
    var exportRequired = false
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
        ScrollViewReader { scroll in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    IconButton(symbol: .close, label: "Close", glass: true) { dismiss() }
                        .disabled(purchasing || ads.isPresenting)
                    Spacer(minLength: 0)
                    restoreButton { scroll.scrollTo("purchaseStatus", anchor: .top) }
                }
                .pageHorizontalMargins().frame(maxWidth: 640).frame(maxWidth: .infinity)
                .padding(.vertical, 4)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            SceneTitle("PulsePlayer Plus", size: 36)
                            if exportRequired {
                                LocalizedText("Export is included with Plus.")
                                    .font(.capture(.subheadline, weight: .semibold))
                                    .foregroundStyle(PulsePlayerStyle.accent)
                            }
                        }
                        if commerce.premium { activeMembership }
                        benefits
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            if purchaseAction != nil || commerce.canRetryPurchaseConfirmation { purchaseFeedback }
                            if !commerce.premium { planSelection }
                            purchaseControls
                        }
                        .pulsePlayerKeepControlsTogether()
                        .id("purchaseStatus")
                        PolicyLinks(style: .inline)
                    }
                    .pageHorizontalMargins().frame(maxWidth: 640)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.top, 18).padding(.bottom, 26)
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
            if !loadingCatalog, let selectedPlan { renewalDisclosure(for: selectedPlan) }
            checkoutButton
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 8) {
            benefit(.edit, "Export edited videos and audio")
            benefit(.download, "No daily viewing or download limits")
            benefit(.play, "Skip opening ads")
        }
    }

    private func benefit(_ symbol: PulsePlayerGlyph, _ title: String) -> some View {
        HStack(spacing: 10) {
            Glyph(symbol: symbol, size: 15, tint: PulsePlayerStyle.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            LocalizedText(title).font(.capture(.subheadline))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
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
        .pulsePlayerPanel(cornerRadius: 18)
    }

    @ViewBuilder private var purchaseFeedback: some View {
        if let error = commerce.error {
            ErrorNote(message: error)
        } else if let message = commerce.message {
            LocalizedText(message).font(.capture(.subheadline)).foregroundStyle(PulsePlayerStyle.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var planSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LocalizedText("Subscription plans").font(.capture(.headline))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if configuredPlans.isEmpty {
                LocalizedText("Subscription setup is incomplete. Please contact support.")
                    .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(configuredPlans) { entry in
                        planOption(entry)
                        if entry.id != configuredPlans.last?.id { Divider() }
                    }
                }
                if plans.count < configuredPlans.count {
                    LocalizedText("USD reference prices. Apple confirms your local price before payment.")
                        .font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !loadingCatalog, plans.count < configuredPlans.count {
                    LocalizedText(commerce.plansError ?? "This plan isn’t available from Apple yet. Please try again later.")
                        .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        return selectedPlan == nil ? "Check price" : "Subscribe"
    }

    @ViewBuilder private func planOption(_ entry: CommerceConfiguration.Product) -> some View {
        let product = plans.first { $0.productIdentifier == entry.id }
        let selected = selectedPlan?.productIdentifier == entry.id
        let name = VStack(alignment: .leading, spacing: 4) {
            planName(product, fallback: entry.label)
            if let product {
                planPeriod(commerce.period(product, locale: locale))
            } else {
                LocalizedText(entry.period == .month ? "Billed monthly" : "Billed yearly")
                    .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
            }
        }
        let price = VStack(alignment: .leading, spacing: 2) {
            planPrice(product.map { commerce.price($0) } ?? "USD \(entry.displayPriceUSD)", selected: selected)
            if selected {
                LocalizedText("Selected").font(.capture(.caption, weight: .semibold)).foregroundStyle(PulsePlayerStyle.accent)
            }
        }
        let label = ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                name.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                price.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 8) { name; price }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(selected ? PulsePlayerStyle.mist : Color.clear, in: .rect(cornerRadius: 10))
        .contentShape(Rectangle())
        if let product {
            Button { selectedID = product.productIdentifier } label: { label }
                .buttonStyle(PressStyle()).disabled(interactionLocked)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("membership.plan.\(entry.id)")
        } else {
            label.accessibilityElement(children: .combine)
        }
    }

    private func planName(_ product: SKProduct?, fallback: String) -> some View {
        Group {
            if let period = product?.subscriptionPeriod, period.numberOfUnits == 1, period.unit == .month {
                LocalizedText("Monthly")
            } else if let period = product?.subscriptionPeriod, period.numberOfUnits == 1, period.unit == .year {
                LocalizedText("Yearly")
            } else if let product {
                Text(verbatim: product.localizedTitle)
            } else {
                LocalizedText(fallback)
            }
        }.font(.capture(.headline, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func planPeriod(_ period: String) -> some View {
        LocalizedText("Billed every %@", period).font(.capture(.footnote))
            .foregroundStyle(PulsePlayerStyle.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func planPrice(_ price: String, selected: Bool) -> some View {
        Text(verbatim: price).environment(\.layoutDirection, .leftToRight)
            .font(.capture(.title2, weight: .semibold)).monospacedDigit()
            .foregroundStyle(selected ? PulsePlayerStyle.accent : PulsePlayerStyle.paper)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func renewalDisclosure(for plan: SKProduct) -> some View {
        LocalizedText("%@ every %@. Renews automatically until canceled.",
                      commerce.price(plan), commerce.period(plan, locale: locale))
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
            .foregroundStyle(PulsePlayerStyle.paper)
            .pulsePlayerGlass(in: Capsule(), tint: PulsePlayerStyle.accent.opacity(0.22), fallback: PulsePlayerStyle.mist)
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
                .font(.capture(.footnote, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(PulsePlayerStyle.accent)
                .pulsePlayerGlass(in: Capsule(), fallback: PulsePlayerStyle.raised)
                .contentShape(.interaction, Capsule())
        }.disabled(interactionLocked).buttonStyle(PressStyle())
            .accessibilityIdentifier("membership.restore")
    }
}

struct AccountView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var ads: RewardedAds
    @EnvironmentObject private var accountAccess: AccountAccessFlow
    let openFavorites: () -> Void
    let openHistory: () -> Void
    let openFolders: () -> Void
    @AppStorage(LocalPlaybackResume.enabledKey) private var resumesPlayback = true
    @AppStorage(LocalPlaybackPreferences.speedKey) private var defaultLocalSpeed = 1.0
    @AppStorage(LocalPlaybackPreferences.loopKey) private var loopsLocalPlayback = false
    @State private var paywall = false
    @State private var allowancePrompt: AllowanceKind?
    @State private var showingStorage = false
    @State private var showingSpeedPicker = false
    private var unavailable: Bool {
        accountAccess.isBusy || commerce.busy || commerce.preparingPurchase || ads.busy || ads.isPresenting
    }

    var body: some View {
        ScenePage(depth: 44, openingGap: 14) { _ in
            VStack(alignment: .leading, spacing: 12) {
                SceneTitle("Settings", size: 26)
                membershipEntry
            }
        } content: { container in
            accountContent(in: container)
        }
        .fullScreenCover(isPresented: $paywall) { MembershipView() }
        .fullScreenCover(item: $allowancePrompt) { kind in AllowanceLimitPrompt(kind: kind) }
        .sheet(isPresented: $showingStorage) { VideoStorageView() }
        .sheet(isPresented: $showingSpeedPicker) { localSpeedPicker }
    }

    private func accountContent(in container: GeometryProxy) -> some View {
        let bounds = CGRect(origin: .zero, size: container.size)
        let width = min(640, PulsePlayerStyle.pageContentWidth(in: container))
        let hasReservedRegion = PulsePlayerStyle.intersectsReservedRegion(bounds, in: container)
        let wide = api.session != nil && width >= 620 && typeSize <= .xLarge && !hasReservedRegion
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                          : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))

        return layout {
            VStack(alignment: .leading, spacing: 12) {
                if api.session != nil {
                    allowance
                    accountDetails
                } else { ConnectionPanel() }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 14) {
                libraryShortcuts
                playbackSettings
                AccountSettingsSection()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var libraryShortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Library").accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                Button(action: openHistory) {
                    AccountLinkLabel(title: "Recently opened", symbol: .play)
                }
                Button(action: openFavorites) {
                    AccountLinkLabel(title: "Favorites", symbol: .bookmark)
                }
                Button(action: openFolders) {
                    AccountLinkLabel(title: "Folders", symbol: .folder)
                }
                Button { showingStorage = true } label: {
                    AccountLinkLabel(title: "Video storage", symbol: .library)
                }
                .accessibilityIdentifier("settings.videoStorage")
            }
            .buttonStyle(PressStyle())
            .pulsePlayerGlass(in: RoundedRectangle(cornerRadius: 12), interactive: false)
        }
    }

    private var playbackSettings: some View {
        let selected = LocalPlaybackPreferences.label(LocalPlaybackPreferences.speed(defaultLocalSpeed), locale: locale)

        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Local playback").accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                Button { showingSpeedPicker = true } label: {
                    HStack(spacing: 10) {
                        LocalizedText("Default speed").font(.capture(.subheadline, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Text(verbatim: selected).font(.capture(.subheadline)).monospacedDigit()
                            .foregroundStyle(PulsePlayerStyle.secondary)
                        Glyph(symbol: .back, size: 10, tint: PulsePlayerStyle.secondary).rotationEffect(.degrees(180))
                    }
                    .padding(12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(LocalizedStringKey("Default speed"))
                .accessibilityValue(Text(verbatim: selected))
                .accessibilityIdentifier("settings.defaultLocalSpeed")

                Divider().padding(.horizontal, 12)

                Toggle(isOn: $resumesPlayback) {
                    VStack(alignment: .leading, spacing: 4) {
                        LocalizedText("Resume playback").font(.capture(.subheadline, weight: .medium))
                        LocalizedText("Continue local videos from the last position.")
                            .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(minHeight: 44)
                .accessibilityIdentifier("settings.resumePlayback")

                Divider().padding(.horizontal, 12)

                Toggle(isOn: $loopsLocalPlayback) {
                    LocalizedText("Loop playback").font(.capture(.subheadline, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(minHeight: 44)
                .accessibilityIdentifier("settings.loopLocalPlayback")
            }
            .tint(PulsePlayerStyle.accent)
            .pulsePlayerGlass(in: .rect(cornerRadius: 12), interactive: false)
        }
    }

    private var localSpeedPicker: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Default speed") { showingSpeedPicker = false }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(LocalPlaybackPreferences.speeds, id: \.self) { rate in
                        let selected = LocalPlaybackPreferences.speed(defaultLocalSpeed) == rate
                        Button {
                            defaultLocalSpeed = Double(rate)
                            showingSpeedPicker = false
                        } label: {
                            HStack(spacing: 12) {
                                Text(verbatim: LocalPlaybackPreferences.label(rate, locale: locale))
                                    .font(.capture(.subheadline, weight: selected ? .semibold : .regular))
                                    .monospacedDigit()
                                Spacer(minLength: 0)
                                if selected {
                                    LocalizedText("Selected").font(.capture(.caption))
                                        .foregroundStyle(PulsePlayerStyle.accent)
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle())
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .pulsePlayerGlass(in: .rect(cornerRadius: 12), interactive: false)
                .pulsePlayerPage()
            }
        }
        .foregroundStyle(PulsePlayerStyle.paper)
        .pulsePlayerScreenBackground()
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var accountDetails: some View {
        if let id = api.session?.userId.value {
            LocalizedText("ID · %@", id).monospacedDigit().textSelection(.enabled)
                .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var membershipEntry: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let title = VStack(alignment: .leading, spacing: 6) {
            LocalizedText("PulsePlayer Plus")
                .font(.capture(.title2, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            if api.session != nil, commerce.premium || commerce.rightsVerified {
                LocalizedText(commerce.premium ? "Plus active" : "Free plan")
                    .font(.capture(.subheadline))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        let action = HStack(spacing: 8) {
            LocalizedText(commerce.premium ? "View membership" : "View plans")
                .font(.capture(.subheadline, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Glyph(symbol: .back, size: 12, tint: .white).rotationEffect(.degrees(180))
        }

        return Button { paywall = true } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    title.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    action.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 12) {
                    title
                    action
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            .multilineTextAlignment(.leading)
            .foregroundStyle(.white)
            .background(PulsePlayerStyle.accent, in: shape)
            .contentShape(.interaction, shape)
        }.buttonStyle(PressStyle()).disabled(unavailable)
            .accessibilityIdentifier("account.membership")
    }

    private var allowance: some View {
        let eligibleRewards = AllowanceKind.allCases.filter { quota.canRequestReward(for: $0, premium: commerce.premium) }
        return VStack(alignment: .leading, spacing: 8) {
            AllowanceStatusPanel()
            if commerce.premium {
                LocalizedText("Included with your membership")
                    .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if eligibleRewards.isEmpty {
                    allowanceButton("Get more") { paywall = true }
                        .accessibilityLabel("Get more daily views and downloads")
                } else {
                    ForEach(eligibleRewards) { kind in
                        allowanceButton(kind == .watch ? "Get more views" : "Get more downloads") {
                            allowancePrompt = kind
                        }
                    }
                }
            }
        }
    }

    private func allowanceButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                LocalizedText(title).font(.capture(.footnote, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Glyph(symbol: .back, size: 11, tint: PulsePlayerStyle.accent).rotationEffect(.degrees(180))
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(PulsePlayerStyle.accent)
            .pulsePlayerGlass(in: Capsule(), fallback: PulsePlayerStyle.raised)
            .contentShape(.interaction, Capsule())
        }
        .buttonStyle(PressStyle()).disabled(unavailable)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct VideoStorageView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var offline: OfflineStore
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

        ScenePage(depth: 44, openingGap: 0) { _ in
            HStack(spacing: 10) {
                IconButton(symbol: .back, label: "Back", glass: true) { dismiss() }
                SceneTitle("Video storage", size: 26)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } content: { _ in
            VStack(alignment: .leading, spacing: 16) {
                if let removalError { ErrorNote(message: removalError) }
                if files.isEmpty {
                    EmptyStateScene(title: "No stored files")
                } else if measuring {
                    AccountLoadingIndicator(title: "Loading…")
                } else {
                    storageSummary(hasUnreadableFiles: files.contains { sizes[$0.url] == nil })
                    LazyVStack(spacing: 0) {
                        ForEach(files.sorted(by: storageOrder)) { file in
                            storageRow(file)
                            Divider().overlay(PulsePlayerStyle.line).accessibilityHidden(true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: urls) { await measure(urls) }
        .sheet(item: $removing) { file in removalSheet(file) }
    }

    private func storageSummary(hasUnreadableFiles: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LocalizedText("Stored files").font(.capture(.subheadline, weight: .semibold))
                .foregroundStyle(PulsePlayerStyle.secondary)
                .accessibilityAddTraits(.isHeader)
            if sizes.isEmpty {
                LocalizedText("Size unavailable").font(.capture(.headline))
            } else {
                Text(verbatim: displaySize(sizes.values.reduce(0, +)))
                    .font(.capture(.title2, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if hasUnreadableFiles {
                    LocalizedText("Some file sizes could not be read.")
                        .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulsePlayerPanel(cornerRadius: 12)
    }

    private func storageRow(_ file: StoredFile) -> some View {
        HStack(spacing: 12) {
            Glyph(symbol: file.isDownload ? .download : .feed, size: 18, tint: PulsePlayerStyle.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: file.title).font(.capture(.subheadline, weight: .semibold))
                LocalizedText(file.category).font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.secondary)
                Group {
                    if let bytes = sizes[file.url] { Text(verbatim: displaySize(bytes)) }
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
                SheetHeading(title: file.isDownload ? "Remove offline video?" : "Delete this local copy?") {
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
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @State private var showsUsageDetails = false

    private var hasUsage: Bool { quota.usage != nil && quota.error == nil }
    private var canShowDetails: Bool { api.session != nil && hasUsage && !commerce.premium }
    private var detailsVisible: Bool { canShowDetails && showsUsageDetails }
    private var primaryText: Color { onMedia ? PulsePlayerStyle.onDark : PulsePlayerStyle.paper }
    private var secondaryText: Color { onMedia ? PulsePlayerStyle.mediaSecondary : PulsePlayerStyle.secondary }
    private var accent: Color { onMedia ? PulsePlayerStyle.mediaAccent : PulsePlayerStyle.accent }
    private var errorTint: Color { onMedia ? PulsePlayerStyle.mediaError : PulsePlayerStyle.danger }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            allowanceHeading
            if api.session == nil {
                LocalizedText("Connect to refresh your allowance.")
                    .font(.capture(.subheadline)).foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if commerce.premium || hasUsage {
                    statusRows
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

    @ViewBuilder private var statusRows: some View {
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(kinds) { kind in
                if kind != kinds.first { rule }
                allowanceStatus(kind)
            }
            if detailsVisible {
                rule
                AllowanceResetText(tint: secondaryText).padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 14)
        if onMedia {
            rows.background(PulsePlayerStyle.onDark.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        } else {
            rows.pulsePlayerPanel(cornerRadius: 14)
        }
    }

    private var rule: some View {
        Rectangle().fill(onMedia ? PulsePlayerStyle.onDark.opacity(0.14) : PulsePlayerStyle.line)
            .frame(height: 1).accessibilityHidden(true)
    }

    @ViewBuilder private var allowanceHeading: some View {
        let title = LocalizedText(kinds == [.download] ? "Daily limits" : "Online video")
            .font(.capture(onMedia ? .subheadline : .headline, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)

        if canShowDetails {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    title.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    usageDetailsButton.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 0) {
                    title
                    usageDetailsButton
                }
            }
        } else {
            title
        }
    }

    private var usageDetailsButton: some View {
        let down = layoutDirection == .leftToRight ? -90.0 : 90.0
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) {
                showsUsageDetails.toggle()
            }
        } label: {
            let label = HStack(spacing: 6) {
                LocalizedText(showsUsageDetails ? "Hide details" : "Usage details")
                    .font(.capture(.footnote, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Glyph(symbol: .back, size: 10, tint: accent)
                    .rotationEffect(.degrees(showsUsageDetails ? -down : down))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.interaction, Capsule())
            if onMedia {
                label
            } else {
                label.pulsePlayerGlass(in: Capsule(), fallback: PulsePlayerStyle.raised)
            }
        }
        .buttonStyle(PressStyle())
        .accessibilityIdentifier("account.usageDetails")
    }

    private func allowanceStatus(_ kind: AllowanceKind) -> some View {
        let isWatch = kind == .watch
        let unlimited = commerce.premium || quota.isUnlimited(kind)
        let remaining = quota.remaining(kind)
        let available = unlimited || remaining > 0
        let title = LocalizedText(isWatch ? "Online viewing" : "Offline downloads")
            .font(.capture(.subheadline, weight: .medium))
            .foregroundStyle(primaryText)
            .fixedSize(horizontal: false, vertical: true)
        let status = LocalizedText(unlimited ? "Unlimited" : (available ? "Available today" : "Daily limit reached"))
            .font(.capture(.footnote, weight: .medium))
            .foregroundStyle(available ? accent : errorTint)
            .fixedSize(horizontal: false, vertical: true)

        return HStack(alignment: .top, spacing: 10) {
            Glyph(symbol: isWatch ? .play : .download, size: 16, tint: secondaryText)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        title.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        status.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        title
                        status
                    }
                }
                if detailsVisible, !unlimited {
                    LocalizedText("%@ left · %@ total today", remaining.formatted(.number.locale(locale)),
                                  quota.totalAllowance(for: kind).formatted(.number.locale(locale)))
                        .font(.capture(.footnote)).monospacedDigit()
                        .foregroundStyle(secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
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
