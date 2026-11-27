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

struct ScenePage<PageContent: View>: View {
    let scrollsBehindTabBar: Bool
    let content: (GeometryProxy) -> PageContent

    init(scrollsBehindTabBar: Bool = false, @ViewBuilder content: @escaping (GeometryProxy) -> PageContent) {
        self.scrollsBehindTabBar = scrollsBehindTabBar
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
            content(container).pulsePlayerPage()
        }
    }
}

// MARK: - Glyphs

enum PulsePlayerGlyph: String, CaseIterable {
    case feed, edit, library, link, search, bookmark, bookmarkFilled, download
    case play, pause, close, back, sound, mute, folder, settings, fold, pass
    var assetName: String { "Glyph" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    // Shown only while the original glyph artwork is missing, so every control stays usable.
    var fallbackTitle: String {
        switch self {
        case .fold: "Practice"; case .pass: "Plus"; case .feed: "Watch"; case .edit: "Edit"; case .library: "Library"
        case .link: "Link"; case .search: "Search"; case .bookmark, .bookmarkFilled: "Saved"; case .download: "Download"
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
    enum Appearance {
        case shelf(PulsePlayerGlyph)
        case screening(PulsePlayerGlyph)
        case notebook
        case inline(PulsePlayerGlyph)
    }

    let appearance: Appearance
    var title: String? = nil
    var message: String? = nil
    var onMedia = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var accent: Color { onMedia ? PulsePlayerStyle.mediaAccent : PulsePlayerStyle.accent }
    private var foreground: Color { onMedia ? PulsePlayerStyle.onDark : PulsePlayerStyle.paper }
    private var secondary: Color { onMedia ? PulsePlayerStyle.mediaSecondary : PulsePlayerStyle.secondary }
    private var surface: Color { onMedia ? PulsePlayerStyle.mediaSurface : PulsePlayerStyle.raised }
    private var row: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
    }

    var body: some View {
        composition
            .accessibilityElement(children: .combine)
            .pulsePlayerKeepControlsTogether()
    }

    @ViewBuilder private var composition: some View {
        switch appearance {
        case .shelf(let symbol):
            row {
                copy()
                Glyph(symbol: symbol, size: 42, tint: accent.opacity(0.72))
            }
            .padding(20)
            .background(surface, in: .rect(cornerRadius: 20))
        case .screening(let symbol):
            VStack(spacing: 12) {
                Glyph(symbol: symbol, size: 36, tint: PulsePlayerStyle.mediaAccent)
                copy(centered: true, inverse: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 124)
            .background(PulsePlayerStyle.mediaSurface, in: .rect(cornerRadius: 16))
        case .notebook:
            VStack(alignment: .leading, spacing: 12) {
                Glyph(symbol: .fold, size: 32, tint: accent)
                copy()
                Divider().overlay(accent.opacity(0.24)).accessibilityHidden(true)
            }
            .padding(.vertical, 10)
        case .inline(let symbol):
            row {
                Glyph(symbol: symbol, size: 21, tint: accent)
                    .frame(width: 38, height: 38)
                    .background(surface, in: Circle())
                copy(compact: true)
            }
            .padding(.vertical, 6)
        }
    }

    private func copy(centered: Bool = false, inverse: Bool = false, compact: Bool = false) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 5) {
            if let title {
                LocalizedText(title)
                    .font(.capture(compact ? .subheadline : .headline, weight: .semibold))
                    .foregroundStyle(inverse ? PulsePlayerStyle.onDark : foreground)
                    .accessibilityAddTraits(.isHeader)
            }
            if let message {
                LocalizedText(message).font(.capture(.subheadline))
                    .foregroundStyle(inverse ? PulsePlayerStyle.mediaSecondary : secondary)
            }
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
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

    func sceneBack(context: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            IconButton(symbol: .back, label: "Back", glass: true, action: action)
                .disabled(disabled)
                .accessibilityValue(Text(LocalizedStringKey(context)))
                .accessibilitySortPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pulsePlayerKeepControlsTogether()
                .pageHorizontalMargins()
                .padding(.top, 6)
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
struct ActionMenuItem: Identifiable {
    let title: String
    let symbol: PulsePlayerGlyph
    let selected: Bool
    let destructive: Bool
    let identifier: String?
    let action: () -> Void
    var id: String { identifier ?? title }

    init(_ title: String, _ symbol: PulsePlayerGlyph, selected: Bool = false, destructive: Bool = false,
         identifier: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.selected = selected
        self.destructive = destructive
        self.identifier = identifier
        self.action = action
    }
}

struct MenuGlyph: View {
    let symbol: PulsePlayerGlyph
    let tint: Color

    var body: some View {
        Glyph(symbol: symbol, size: 16, tint: tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.11), in: .rect(cornerRadius: 9))
            .accessibilityHidden(true)
    }
}

struct GlassActionMenu<Trigger: View>: View {
    let title: String
    var onDark = false
    let items: [ActionMenuItem]
    let label: () -> Trigger
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var presented = false
    @State private var afterDismiss: (() -> Void)?

    init(title: String, onDark: Bool = false, items: [ActionMenuItem], @ViewBuilder label: @escaping () -> Trigger) {
        self.title = title
        self.onDark = onDark
        self.items = items
        self.label = label
    }

    var body: some View {
        Button { presented = true } label: { label() }
            .buttonStyle(PressStyle())
            .sheet(isPresented: $presented, onDismiss: {
                // Present a picker or destination after UIKit releases the menu sheet.
                let action = afterDismiss
                afterDismiss = nil
                action?()
            }) {
                let ink = onDark ? PulsePlayerStyle.onDark : PulsePlayerStyle.paper
                let accent = onDark ? PulsePlayerStyle.mediaAccent : PulsePlayerStyle.accent
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Spacer(minLength: 8)
                            Button { presented = false } label: {
                                Glyph(symbol: .close, size: 14, tint: ink)
                                    .frame(width: 44, height: 44).contentShape(Circle())
                            }.buttonStyle(PressStyle()).accessibilityLabel(Text("Close"))
                                .accessibilityValue(Text(LocalizedStringKey(title)))
                        }
                        ForEach(items) { item in
                            let tint = item.destructive ? (onDark ? PulsePlayerStyle.mediaError : PulsePlayerStyle.danger) : accent
                            Button(role: item.destructive ? .destructive : nil) {
                                guard presented, afterDismiss == nil else { return }
                                afterDismiss = item.action
                                presented = false
                            } label: {
                                HStack(spacing: 12) {
                                    MenuGlyph(symbol: item.symbol, tint: tint)
                                    LocalizedText(item.title)
                                        .font(.capture(.body, weight: item.selected ? .semibold : .medium))
                                        .foregroundStyle(item.destructive ? tint : ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 2)
                                    if item.selected {
                                        LocalizedText("Selected").font(.capture(.caption, weight: .semibold))
                                            .foregroundStyle(accent)
                                    }
                                }
                                .multilineTextAlignment(.leading)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .background(tint.opacity(item.selected ? 0.16 : 0.05), in: .rect(cornerRadius: 13))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressStyle())
                            .accessibilityAddTraits(item.selected ? .isSelected : [])
                            .accessibilityIdentifier(item.id)
                        }
                    }
                    .foregroundStyle(ink)
                    .pulsePlayerKeepControlsTogether()
                    .padding(.horizontal, 20).padding(.vertical, 18)
                    .frame(maxWidth: 520).frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(CGFloat(88 + items.count * 56)), .large])
                .presentationDragIndicator(.visible)
                .presentationBackground {
                    Color.clear.pulsePlayerGlass(in: .rect(cornerRadius: 26),
                        fallback: onDark ? PulsePlayerStyle.mediaSurface : PulsePlayerStyle.surface,
                        interactive: false, onDark: onDark).ignoresSafeArea()
                }
                .preferredColorScheme(onDark ? .dark : .light)
            }
    }
}

struct SheetToolbar: View {
    let context: String
    var showsConfirmation = false
    var close: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if showsConfirmation {
                LocalizedText(context).font(.capture(.headline))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            IconButton(symbol: .close, label: "Close", glass: true, action: close)
                .accessibilityValue(showsConfirmation ? Text(verbatim: "") : Text(LocalizedStringKey(context)))
        }
        .pulsePlayerKeepControlsTogether()
        .pageHorizontalMargins().padding(.top, 6)
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
    var title: (String) -> String = { $0 }
    let select: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) { options }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 2) { options }.fixedSize(horizontal: true, vertical: false)
                    ScrollViewReader { scroll in
                        ScrollView(.horizontal) {
                            HStack(spacing: 2) { options }
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: selected, initial: true) { _, value in scroll.scrollTo(value) }
                    }
                }
            }
        }
        .padding(4)
        .background(PulsePlayerStyle.raised, in: .rect(cornerRadius: 17))
        .accessibilityElement(children: .contain)
    }

    private var options: some View {
        ForEach(values, id: \.self) { value in
            let active = selected == value
            Button { select(value) } label: {
                LocalizedText(title(value))
                    .font(.capture(.subheadline, weight: active ? .bold : .medium))
                    .foregroundStyle(active ? PulsePlayerStyle.accent : PulsePlayerStyle.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .frame(minWidth: 44, minHeight: 44)
                    .background {
                        if active {
                            Color.clear.pulsePlayerGlass(in: .rect(cornerRadius: 13),
                                tint: PulsePlayerStyle.surface.opacity(0.46), fallback: PulsePlayerStyle.surface)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(.interaction, Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(Text(LocalizedStringKey(value)))
            .accessibilityAddTraits(active ? .isSelected : [])
            .id(value)
        }
    }
}
