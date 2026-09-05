import SwiftUI
import UIKit
import Observation

struct ThemeRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xff) / 255
        green = Double((hex >> 8) & 0xff) / 255
        blue = Double(hex & 0xff) / 255
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }

    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrast(with other: ThemeRGB) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }
}

struct ThemePalette: Equatable, Sendable {
    let background: ThemeRGB
    let surface: ThemeRGB
    let text: ThemeRGB
    let secondary: ThemeRGB
    let accent: ThemeRGB
}

enum AppColorTheme: String, CaseIterable, Identifiable, Sendable {
    case blackGold, pine, indigo, ivory

    var id: String { rawValue }
    var name: String {
        switch self {
        case .blackGold: "黑金"
        case .pine: "松青"
        case .indigo: "黛蓝"
        case .ivory: "月白"
        }
    }
    var detail: String {
        switch self {
        case .blackGold: "经典深色 · 暖金点缀"
        case .pine: "沉静青绿 · 柔和松色"
        case .indigo: "深邃蓝调 · 清透银蓝"
        case .ivory: "温润浅色 · 纸感留白"
        }
    }
    var colorScheme: ColorScheme { self == .ivory ? .light : .dark }
    var palette: ThemePalette {
        switch self {
        case .blackGold:
            ThemePalette(
                background: .init(red: 0.025, green: 0.023, blue: 0.022),
                surface: .init(red: 0.075, green: 0.071, blue: 0.067),
                text: .init(red: 0.95, green: 0.93, blue: 0.88),
                secondary: .init(0xA4A19B),
                accent: .init(red: 0.78, green: 0.65, blue: 0.45)
            )
        case .pine:
            ThemePalette(background: .init(0x10201B), surface: .init(0x1B3028),
                         text: .init(0xECF3E9), secondary: .init(0xA2B8AA), accent: .init(0x9DD1B8))
        case .indigo:
            ThemePalette(background: .init(0x131E32), surface: .init(0x20304B),
                         text: .init(0xEEF2FA), secondary: .init(0xB0BED3), accent: .init(0xAEC7F0))
        case .ivory:
            ThemePalette(background: .init(0xF4F0E8), surface: .init(0xFFFCF5),
                         text: .init(0x292C29), secondary: .init(0x626761), accent: .init(0x705323))
        }
    }
}

/// One device-local, non-sensitive preference. Observation updates only the
/// views reading theme tokens; it never rebuilds RootView's navigation identity.
@MainActor @Observable
final class AppearanceStore {
    static let shared = AppearanceStore()
    static let preferenceKey = "cn.com.shuzijun.yishu.appearance.v1"
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var theme: AppColorTheme
    private(set) var usesDarkMediaCanvas = false

    var systemColorScheme: ColorScheme {
        usesDarkMediaCanvas ? .dark : theme.colorScheme
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = defaults.string(forKey: Self.preferenceKey).flatMap(AppColorTheme.init(rawValue:)) ?? .blackGold
    }

    func select(_ selection: AppColorTheme) {
        guard theme != selection else { return }
        theme = selection
        defaults.set(selection.rawValue, forKey: Self.preferenceKey)
    }

    func setDarkMediaCanvasVisible(_ visible: Bool) {
        guard visible != usesDarkMediaCanvas else { return }
        usesDarkMediaCanvas = visible
    }
}

/// Keep photographic canvases and capture notices independent of UI themes.
enum MediaTheme {
    static let ink = AppColorTheme.blackGold.palette.background.color
    static let elevatedInk = AppColorTheme.blackGold.palette.surface.color
    static let warmWhite = AppColorTheme.blackGold.palette.text.color
    static let gold = AppColorTheme.blackGold.palette.accent.color
    static let muted = Color.white.opacity(0.58)
}

@MainActor
enum AppTheme {
    private static var palette: ThemePalette { AppearanceStore.shared.theme.palette }
    static var ink: Color { palette.background.color }
    static var elevatedInk: Color { palette.surface.color }
    static var warmWhite: Color { palette.text.color }
    static var gold: Color { palette.accent.color }
    static var muted: Color { palette.secondary.color }
    static var line: Color { palette.text.color.opacity(0.16) }
    static var subtleFill: Color { palette.text.color.opacity(0.055) }
    static var warning: Color {
        AppearanceStore.shared.theme == .ivory ? ThemeRGB(0x874100).color : .orange
    }
}

struct ThemeInputChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).stroke(AppTheme.line, lineWidth: 0.5)
            }
    }
}

private struct AppAppearanceModifier: ViewModifier {
    var isAppRoot = false
    func body(content: Content) -> some View {
        let theme = AppearanceStore.shared.theme
        content
            .environment(\.colorScheme, theme.colorScheme)
            .preferredColorScheme(isAppRoot ? AppearanceStore.shared.systemColorScheme : theme.colorScheme)
            .foregroundStyle(theme.palette.text.color)
            .tint(theme.palette.accent.color)
    }
}

private struct ThemeNavigationChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbarColorScheme(AppearanceStore.shared.theme.colorScheme, for: .navigationBar)
            .toolbarBackground(AppTheme.ink, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

@MainActor
enum AppAppearanceCoordinator {
    static func updateLegacyTabBars() {
        guard #unavailable(iOS 26.0) else { return }
        let palette = AppearanceStore.shared.theme.palette
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = palette.background.uiColor
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance,
                       appearance.compactInlineLayoutAppearance] {
            layout.normal.iconColor = palette.secondary.uiColor
            layout.normal.titleTextAttributes = [.foregroundColor: palette.secondary.uiColor]
            layout.selected.iconColor = palette.accent.uiColor
            layout.selected.titleTextAttributes = [.foregroundColor: palette.accent.uiColor]
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        func update(_ view: UIView) {
            if let bar = view as? UITabBar {
                bar.standardAppearance = appearance
                bar.scrollEdgeAppearance = appearance
            }
            view.subviews.forEach(update)
        }
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).forEach(update)
    }
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
    func appAppearance(isAppRoot: Bool = false) -> some View {
        modifier(AppAppearanceModifier(isAppRoot: isAppRoot))
    }
    func themeNavigationChrome() -> some View { modifier(ThemeNavigationChrome()) }

    func floatingTabBarScrollClearance(_ height: CGFloat = 84) -> some View {
        modifier(FloatingTabBarScrollClearance(height: height))
    }
}
