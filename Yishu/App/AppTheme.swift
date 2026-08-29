import SwiftUI

enum AppTheme {
    static let ink = Color(red: 0.025, green: 0.023, blue: 0.022)
    static let elevatedInk = Color(red: 0.075, green: 0.071, blue: 0.067)
    static let warmWhite = Color(red: 0.95, green: 0.93, blue: 0.88)
    static let gold = Color(red: 0.78, green: 0.65, blue: 0.45)
    static let muted = Color.white.opacity(0.58)
}

extension Font {
    static func editorial(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

