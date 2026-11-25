import SwiftUI

extension Font {
    static func capture(_ style: Font.TextStyle, weight: Font.Weight = .regular, display: Bool = false) -> Font {
        return .system(style, design: .default, weight: display && weight == .regular ? .semibold : weight)
    }
}

struct SceneTitle: View {
    @ScaledMetric private var size: CGFloat
    let title: String

    init(_ title: String, size: CGFloat = 40) {
        self.title = title
        _size = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
    }

    var body: some View {
        LocalizedText(title)
            .font(.system(size: size, weight: .medium, design: .serif))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}
