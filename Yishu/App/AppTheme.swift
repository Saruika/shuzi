import SwiftUI
import UIKit

enum AppTheme {
    static let ink = Color(red: 0.025, green: 0.023, blue: 0.022)
    static let elevatedInk = Color(red: 0.075, green: 0.071, blue: 0.067)
    static let warmWhite = Color(red: 0.95, green: 0.93, blue: 0.88)
    static let gold = Color(red: 0.78, green: 0.65, blue: 0.45)
    static let muted = Color.white.opacity(0.58)
}

@MainActor
enum AppWindowMetrics {
    static func topInsetForLayout(measured: CGFloat) -> CGFloat {
        if measured > 0 { return measured }
        return activeWindow?.safeAreaInsets.top ?? 0
    }

    static func bottomInsetForLayout(measured: CGFloat) -> CGFloat {
        if measured > 0 { return measured }
        return activeWindow?.safeAreaInsets.bottom ?? 0
    }

    private static var activeWindow: UIWindow? {
        let foregroundScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter {
                $0.activationState == .foregroundActive
                    || $0.activationState == .foregroundInactive
            }

        return foregroundScenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? foregroundScenes
                .flatMap(\.windows)
                .first(where: { !$0.isHidden && $0.alpha > 0 })
    }
}

private struct FloatingTabBarScrollClearance: ViewModifier {
    let height: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom == .phone {
            content.padding(.bottom, 24)
        } else {
            content.contentMargins(.bottom, height, for: .scrollContent)
        }
    }
}

extension View {
    func floatingTabBarScrollClearance(_ height: CGFloat = 84) -> some View {
        modifier(FloatingTabBarScrollClearance(height: height))
    }
}
