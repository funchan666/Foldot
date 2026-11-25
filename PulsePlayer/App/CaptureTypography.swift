import SwiftUI

extension Font {
    static func capture(_ style: Font.TextStyle, weight: Font.Weight = .regular, display: Bool = false) -> Font {
        return .system(style, design: .default, weight: display && weight == .regular ? .semibold : weight)
    }
}
