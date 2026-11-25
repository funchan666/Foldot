import SwiftUI
import UIKit

enum PulsePlayerStyle {
    static let background = Color("LaunchBackground")
    static let surface = Color.white
    static let raised = Color(red: 0.910, green: 0.941, blue: 0.992)
    static let accent = Color(red: 0.141, green: 0.345, blue: 0.749)
    static let ink = Color.white
    static let secondary = Color(red: 0.294, green: 0.361, blue: 0.459)
    static let paper = Color(red: 0.082, green: 0.141, blue: 0.239)
    static let paperSecondary = secondary
    static let mist = Color(red: 0.863, green: 0.918, blue: 1)
    static let line = Color(red: 0.800, green: 0.851, blue: 0.914)
    static let danger = Color(red: 0.62, green: 0.18, blue: 0.17)
    static let onDark = Color(red: 0.961, green: 0.973, blue: 0.996)
    static let mediaBackdrop = Color(red: 0.039, green: 0.063, blue: 0.114)
    static let mediaSurface = Color(red: 0.090, green: 0.137, blue: 0.220)
    static let mediaSecondary = Color(red: 0.737, green: 0.800, blue: 0.886)
    static let mediaAccent = Color(red: 0.663, green: 0.835, blue: 1)
    static let mediaError = Color(red: 1, green: 0.72, blue: 0.70)
    static let pageMargin: CGFloat = 20

    static func pageContentWidth(in container: GeometryProxy) -> CGFloat {
        if #available(iOS 27.1, *) {
            let margins = container.contentMargins(for: .container, edges: .horizontal)
            return max(0, container.size.width - margins.leading - margins.trailing)
        }
        return max(0, container.size.width - pageMargin * 2)
    }

    static func intersectsReservedRegion(_ frame: CGRect, in container: GeometryProxy) -> Bool {
        guard #available(iOS 27.1, *) else { return false }
        let regions = container.reservedRegions(kind: .division) + container.reservedRegions(kind: .occlusion)
        return regions.contains { $0.isActive && frame.intersects($0.frame) }
    }

    static func largestPane(in area: CGRect, excluding obstruction: CGRect) -> CGRect {
        let candidates = [
            CGRect(x: area.minX, y: area.minY, width: obstruction.minX - area.minX, height: area.height),
            CGRect(x: obstruction.maxX, y: area.minY, width: area.maxX - obstruction.maxX, height: area.height),
            CGRect(x: area.minX, y: area.minY, width: area.width, height: obstruction.minY - area.minY),
            CGRect(x: area.minX, y: obstruction.maxY, width: area.width, height: area.maxY - obstruction.maxY)
        ]
        return candidates.max { $0.width * $0.height < $1.width * $1.height } ?? area
    }
}

// MARK: - Original raster artwork (Asset Catalog). Missing art never blocks layout or touch.

enum ArtworkCatalog {
    private static var cache: [String: Bool] = [:]
    static func has(_ name: String) -> Bool {
        if let known = cache[name] { return known }
        let found = UIImage(named: name) != nil
        cache[name] = found
        return found
    }
}

struct ScenePage<Opening: View, PageContent: View>: View {
    let depth: CGFloat
    let openingGap: CGFloat
    let scrollsBehindTabBar: Bool
    let opening: (CGFloat) -> Opening
    let content: (GeometryProxy) -> PageContent

    init(depth: CGFloat, openingGap: CGFloat = 16, scrollsBehindTabBar: Bool = false,
         @ViewBuilder opening: @escaping (CGFloat) -> Opening,
         @ViewBuilder content: @escaping (GeometryProxy) -> PageContent) {
        self.depth = depth
        self.openingGap = openingGap
        self.scrollsBehindTabBar = scrollsBehindTabBar
        self.opening = opening
        self.content = content
    }

    var body: some View {
        GeometryReader { container in
            if scrollsBehindTabBar {
                GeometryReader { viewport in
                    // Return only the space gained below the safe area to the scroll margins.
                    let overlap = max(0, viewport.size.height - container.size.height)
                    let page = scrollingPage(in: container).contentMargins(.bottom, overlap)
                    if #available(iOS 26.0, *) {
                        page.scrollEdgeEffectHidden(for: .bottom)
                    } else {
                        page
                    }
                }
                .ignoresSafeArea(.container, edges: .bottom)
            } else {
                scrollingPage(in: container).clipped()
            }
        }
        .pulsePlayerScreenBackground()
        .foregroundStyle(PulsePlayerStyle.paper)
    }

    private func scrollingPage(in container: GeometryProxy) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                if depth > 0 {
                    let height = max(44, depth)
                    opening(height)
                        .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
                        .pageHorizontalMargins()
                        .frame(maxWidth: 680)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                        .padding(.bottom, openingGap)
                }
                content(container).pulsePlayerPage()
            }
        }
    }
}

extension ScenePage where Opening == EmptyView {
    init(depth: CGFloat = 0, scrollsBehindTabBar: Bool = false,
         @ViewBuilder content: @escaping (GeometryProxy) -> PageContent) {
        self.init(depth: depth, openingGap: 0, scrollsBehindTabBar: scrollsBehindTabBar,
                  opening: { _ in EmptyView() }, content: content)
    }
}

// MARK: - Glyphs

enum PulsePlayerGlyph: String, CaseIterable {
    case feed, edit, library, link, search, bookmark, download
    case play, pause, close, back, sound, mute, folder, settings, fold, pass
    var assetName: String { "Glyph" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    // Shown only while the original glyph artwork is missing, so every control stays usable.
    var fallbackTitle: String {
        switch self {
        case .fold: "Practice"; case .pass: "Plus"; case .feed: "Watch"; case .edit: "Edit"; case .library: "Library"
        case .link: "Link"; case .search: "Search"; case .bookmark: "Saved"; case .download: "Download"
        case .play: "Play"; case .pause: "Pause"; case .close: "Close"; case .back: "Back"
        case .sound: "Sound"; case .mute: "Mute"; case .folder: "Folder"; case .settings: "Me"
        }
    }
}

/// Single-colour original glyph artwork, tinted at display time.
struct Glyph: View {
    @Environment(\.layoutDirection) private var direction
    let symbol: PulsePlayerGlyph
    var size: CGFloat = 25
    var tint: Color = PulsePlayerStyle.paper
    var body: some View {
        Group {
            if ArtworkCatalog.has(symbol.assetName) {
                Image(symbol.assetName).renderingMode(.template).resizable().interpolation(.high).scaledToFit()
                    .foregroundStyle(tint)
                    .scaleEffect(x: symbol == .back && direction == .rightToLeft ? -1 : 1, y: 1)
            } else { Color.clear }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Template artwork by asset name (player rail, tab-like controls).
struct TintedArtwork: View {
    let name: String
    var tint: Color = .white
    var body: some View {
        if ArtworkCatalog.has(name) {
            Image(name).renderingMode(.template).resizable().interpolation(.high).scaledToFit()
                .foregroundStyle(tint).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

struct IconButton: View {
    let symbol: PulsePlayerGlyph
    let label: String
    var selected = false
    var glass = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            let mark = Group {
                if ArtworkCatalog.has(symbol.assetName) {
                    Glyph(symbol: symbol, size: 21, tint: selected ? PulsePlayerStyle.accent : PulsePlayerStyle.paper)
                } else {
                    LocalizedText(symbol.fallbackTitle).font(.capture(.caption2, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 4)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(PulsePlayerStyle.paper)

            Group {
                if glass {
                    mark.pulsePlayerGlass(in: Capsule(), tint: selected ? PulsePlayerStyle.accent.opacity(0.14) : nil,
                                   fallback: selected ? PulsePlayerStyle.mist : PulsePlayerStyle.surface)
                        .environment(\.colorScheme, .light)
                } else {
                    mark.background { if selected { CaptureSurface(tone: .plum) } }
                }
            }
            .contentShape(.interaction, Rectangle())
        }.buttonStyle(PressStyle()).accessibilityLabel(LocalizedStringKey(label))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Controls

struct PressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(!isEnabled ? 0.55 : (configuration.isPressed ? 0.7 : 1))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
// Let long action names wrap with the surrounding content.
struct CompactActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.capture(.footnote, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).frame(minHeight: 44)
            .foregroundStyle(PulsePlayerStyle.paper)
            .pulsePlayerGlass(in: .rect(cornerRadius: 12), fallback: PulsePlayerStyle.raised)
            .environment(\.colorScheme, .light)
            .contentShape(.interaction, Rectangle())
            .opacity(!isEnabled ? 0.55 : (configuration.isPressed ? 0.7 : 1))
    }
}
struct ActionButton: View {
    let title: String
    var primary = true
    var busy = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            ActionLabel(title: busy ? "Please wait…" : title, primary: primary, busy: busy)
        }.buttonStyle(PressStyle()).disabled(busy)
    }
}

struct ActionLabel: View {
    let title: String
    var symbol: PulsePlayerGlyph? = nil
    var primary = true
    var busy = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let iconTint = PulsePlayerStyle.accent

        HStack(spacing: 10) {
            LocalizedText(title).font(.capture(.subheadline, weight: .semibold))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if busy {
                    ProgressView().tint(iconTint)
                } else if let symbol {
                    Glyph(symbol: symbol, size: 17, tint: iconTint)
                } else {
                    Glyph(symbol: .back, size: 13, tint: iconTint).rotationEffect(.degrees(180))
                }
            }
            .frame(width: 38, height: 36)
            .accessibilityHidden(true)
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
        .frame(minHeight: 50)
        .foregroundStyle(PulsePlayerStyle.paper)
        .pulsePlayerGlass(in: shape, tint: primary ? PulsePlayerStyle.accent.opacity(0.18) : nil,
                    fallback: primary ? PulsePlayerStyle.mist : PulsePlayerStyle.surface)
        .environment(\.colorScheme, .light)
        .contentShape(.interaction, shape)
    }
}

struct EmptyStateScene: View {
    var title: String? = nil
    var message: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title {
                LocalizedText(title).font(.capture(.headline))
                    .foregroundStyle(PulsePlayerStyle.paper)
                    .accessibilityAddTraits(.isHeader)
            }
            if let message {
                LocalizedText(message).font(.capture(.subheadline))
                    .foregroundStyle(PulsePlayerStyle.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

struct EmptyStateAction: View {
    let title: String
    let symbol: PulsePlayerGlyph
    var primary = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ActionLabel(title: title, symbol: symbol, primary: primary)
        }
        .buttonStyle(PressStyle())
    }
}

struct MessagePanel: View {
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LocalizedText(title).font(.capture(.headline)).foregroundStyle(PulsePlayerStyle.paper)
            LocalizedText(message).font(.capture(.subheadline)).foregroundStyle(PulsePlayerStyle.secondary).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action { ActionButton(title: actionTitle, primary: false, action: action) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(PulsePlayerStyle.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
struct ErrorNote: View {
    @Environment(\.locale) private var locale
    let message: String
    var onMedia = false
    var body: some View {
        LocalizedText(message).font(.capture(.subheadline))
            .foregroundStyle(onMedia ? PulsePlayerStyle.mediaError : PulsePlayerStyle.danger)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            .accessibilityLabel(Text(verbatim: L10n.display("Error: \(message)", language: AppLanguage.from(locale))))
    }
}
struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.capture(.subheadline)).foregroundStyle(PulsePlayerStyle.paper).padding(14)
            .pulsePlayerGlass(in: .rect(cornerRadius: 14), fallback: PulsePlayerStyle.raised, interactive: false)
            .tint(PulsePlayerStyle.accent)
    }
}
// Measure in the owning screen, so scrolling, keyboard avoidance and resizing
// keep the input exclusion region aligned. No global window or focus broadcast.
private struct KeyboardInputBounds: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $0.union($1) })
    }
}
private struct OutsideInputTap: ViewModifier {
    let focus: FocusState<Bool>.Binding
    let scope: String
    @State private var inputBounds: CGRect?
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle()) // Hit area only.
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named(scope)).onEnded { tap in
                guard focus.wrappedValue, let inputBounds, !inputBounds.contains(tap.location) else { return }
                focus.wrappedValue = false
            })
            .onPreferenceChange(KeyboardInputBounds.self) { inputBounds = $0[scope] }
            .coordinateSpace(name: scope)
    }
}

// Keep a small, interactive group in a usable pane when a vertical fold or camera
// actually crosses it. Horizontal obstructions can pass by in the surrounding ScrollView.
private struct FoldControlMargins: Equatable, Sendable {
    var left: CGFloat = 0
    var right: CGFloat = 0

    @available(iOS 27.1, *)
    static func measured(in proxy: GeometryProxy) -> Self {
        let bounds = CGRect(origin: .zero, size: proxy.size)
        let regions = proxy.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed)
            + proxy.reservedRegions(kind: .occlusion, layoutDirectionBehavior: .fixed)
        let blocks = regions.filter(\.isActive).map(\.frame).filter {
            $0.intersects(bounds) && $0.width < bounds.width / 2
        }.sorted { $0.minX < $1.minX }
        guard !blocks.isEmpty else { return Self() }
        var start: CGFloat = 0
        var available = [Range<CGFloat>]()
        for block in blocks {
            let end = max(0, block.minX - 6)
            if end > start { available.append(start..<end) }
            start = max(start, block.maxX + 6)
        }
        if bounds.width > start { available.append(start..<bounds.width) }
        guard let pane = available.max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }),
              pane.upperBound - pane.lowerBound >= 120 else { return Self() }
        return Self(left: pane.lowerBound, right: bounds.width - pane.upperBound)
    }
}

private struct FoldControlPlacement: ViewModifier {
    @Environment(\.layoutDirection) private var direction
    @State private var margins = FoldControlMargins()

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content
                .padding(.leading, direction == .leftToRight ? margins.left : margins.right)
                .padding(.trailing, direction == .leftToRight ? margins.right : margins.left)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: FoldControlMargins.self) { proxy in
                    FoldControlMargins.measured(in: proxy)
                } action: { margins = $0 }
        } else {
            content
        }
    }
}

extension View {
    func pulsePlayerKeepControlsTogether() -> some View { modifier(FoldControlPlacement()) }
}

extension View {
    func keyboardInputRegion(_ scope: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: KeyboardInputBounds.self,
                                       value: [scope: geometry.frame(in: .named(scope))])
            }.allowsHitTesting(false)
        }
    }
    func dismissKeyboardOnOutsideTap(_ focus: FocusState<Bool>.Binding, scope: String) -> some View {
        modifier(OutsideInputTap(focus: focus, scope: scope))
    }
    func pulsePlayerField() -> some View { modifier(FieldStyle()) }
    // Extend visual surfaces to every container edge, while preserving keyboard avoidance
    // and the foreground's safe area for interactive controls.
    func pulsePlayerScreenBackground(_ color: Color = PulsePlayerStyle.background) -> some View {
        background { color.ignoresSafeArea(.container, edges: .all) }
    }
    // A readable column follows the available container (outer or inner display) without resetting state.
    func pulsePlayerPage() -> some View {
        pageHorizontalMargins().padding(.top, 16).padding(.bottom, 24)
            .frame(maxWidth: 680).frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    func pageHorizontalMargins() -> some View {
        if #available(iOS 27.1, *) {
            contentMargins(for: .container, edges: .horizontal)
        } else {
            padding(.horizontal, PulsePlayerStyle.pageMargin)
        }
    }

    func pulsePlayerPanel(cornerRadius: CGFloat = 14) -> some View {
        modifier(PulsePlayerPanel(cornerRadius: cornerRadius))
    }

    func pulsePlayerGlass<S: InsettableShape>(in shape: S, tint: Color? = nil, fallback: Color? = nil,
                                       interactive: Bool = true, onDark: Bool = false) -> some View {
        modifier(PulsePlayerGlass(shape: shape, tint: tint, fallback: fallback, interactive: interactive, onDark: onDark))
    }

    func sceneDismiss(symbol: PulsePlayerGlyph = .close, label: String = "Close", edge: HorizontalEdge = .trailing,
                      disabled: Bool = false, action: @escaping () -> Void) -> some View {
        overlay(alignment: .top) {
            IconButton(symbol: symbol, label: label, glass: true, action: action)
                .disabled(disabled)
                .accessibilitySortPriority(1)
                .frame(maxWidth: .infinity, alignment: edge == .leading ? .leading : .trailing)
                .pageHorizontalMargins()
                .padding(.top, 8)
        }
    }
}

private struct PulsePlayerGlass<Surface: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    let shape: Surface
    let tint: Color?
    let fallback: Color?
    let interactive: Bool
    let onDark: Bool

    func body(content: Content) -> some View {
        let materialTint = tint ?? (onDark ? PulsePlayerStyle.mediaBackdrop.opacity(0.55) : nil)
        Group {
            if #available(iOS 26.0, *), !reduceTransparency {
                content.glassEffect(.regular.tint(materialTint).interactive(interactive && isEnabled && !reduceMotion),
                                    in: shape)
            } else {
                content.background {
                    if reduceTransparency {
                        shape.fill(fallback ?? (onDark ? PulsePlayerStyle.mediaSurface : PulsePlayerStyle.surface))
                    } else {
                        shape.fill(.regularMaterial)
                            .overlay { shape.fill(materialTint ?? .clear) }
                    }
                }
                .overlay {
                    shape.strokeBorder(onDark ? PulsePlayerStyle.onDark.opacity(0.18) : PulsePlayerStyle.line)
                        .allowsHitTesting(false)
                }
            }
        }
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(onDark ? PulsePlayerStyle.onDark.opacity(0.55) : PulsePlayerStyle.secondary)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .environment(\.colorScheme, onDark ? .dark : colorScheme)
    }
}

struct PulsePlayerGlassGroup<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let spacing: CGFloat
    let content: () -> Content

    init(spacing: CGFloat = 0, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

private struct PulsePlayerPanel: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.background(PulsePlayerStyle.surface, in: shape)
            .overlay { shape.strokeBorder(PulsePlayerStyle.line).allowsHitTesting(false) }
    }
}
struct MediaCover: View {
    let url: URL?
    var folder = false
    var onMedia = false
    var body: some View {
        let fallback = Glyph(symbol: folder ? .folder : .feed, size: onMedia ? 19 : 30,
                             tint: onMedia ? PulsePlayerStyle.mediaAccent : PulsePlayerStyle.paper)
        return (onMedia ? PulsePlayerStyle.mediaAccent.opacity(0.15) : PulsePlayerStyle.raised).overlay {
            GeometryReader { geometry in
                Group {
                    if let url {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                            else { fallback }
                        }
                    } else { fallback }
                }.frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
        }.clipped()
    }
}
struct SheetHeading: View {
    let title: String
    var close: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LocalizedText(title).font(.capture(.headline))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            IconButton(symbol: .close, label: "Close", glass: true, action: close)
        }.pageHorizontalMargins().padding(.top, 8)
    }
}

struct SectionLabel: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                LocalizedText(title).font(.capture(.headline))
                Spacer(minLength: 12)
                if let detail { LocalizedText(detail).font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.secondary) }
            }
            VStack(alignment: .leading, spacing: 6) {
                LocalizedText(title).font(.capture(.headline))
                if let detail { LocalizedText(detail).font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FeatureRow: View {
    let symbol: PulsePlayerGlyph
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 16) {
            Glyph(symbol: symbol, size: 20, tint: PulsePlayerStyle.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                LocalizedText(title).font(.capture(.subheadline, weight: .semibold)).foregroundStyle(PulsePlayerStyle.paper)
                LocalizedText(detail).font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

// MARK: - Surfaces (native fills; no drawn artwork)

struct CaptureSurface: View {
    enum Tone { case accent, plum, blush, mist }
    let tone: Tone
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        switch tone {
        case .accent: shape.fill(PulsePlayerStyle.accent)
        case .plum: shape.fill(PulsePlayerStyle.raised).overlay(shape.strokeBorder(PulsePlayerStyle.line))
        case .blush: shape.fill(PulsePlayerStyle.mist)
        case .mist: shape.fill(PulsePlayerStyle.surface).overlay(shape.strokeBorder(PulsePlayerStyle.line))
        }
    }
}

struct ChoiceStrip: View {
    let values: [String]
    let selected: String
    let select: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            PulsePlayerGlassGroup {
                HStack(spacing: 8) {
                    ForEach(values, id: \.self) { value in
                        let isSelected = selected == value
                        Button { select(value) } label: {
                            LocalizedText(value).font(.capture(.footnote, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .frame(minHeight: 44)
                                .foregroundStyle(isSelected ? PulsePlayerStyle.accent : PulsePlayerStyle.paper)
                                .pulsePlayerGlass(in: Capsule(), tint: isSelected ? PulsePlayerStyle.accent.opacity(0.17) : nil,
                                            fallback: isSelected ? PulsePlayerStyle.mist : PulsePlayerStyle.surface)
                                .environment(\.colorScheme, .light)
                                .contentShape(.interaction, Capsule())
                        }.buttonStyle(PressStyle())
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
        }
    }
}
