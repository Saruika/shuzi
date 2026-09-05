import SwiftUI

struct UserSettingsView: View {
    var body: some View {
        Form {
            Section("外观") {
                ThemePreferenceRow()
            }
            Section("账号与通知") {
                NavigationLink {
                    FanAccountView()
                } label: {
                    Label("账号、通知与登录设备", systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("settings-account")
            }
            Section("隐私") {
                NavigationLink {
                    PrivacyPolicyView()
                } label: {
                    Label("隐私政策与数据选择", systemImage: "hand.raised")
                }
                Text("如需删除个人资料，可在账号页主动永久删除账号。")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.muted)
            }
            Section("版本") {
                LabeledContent("Hi，梳子", value: versionLabel)
                Text("主题偏好只保存在这台设备，不上传、不用于追踪，也不改变账号权限。")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.ink.ignoresSafeArea())
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .themeNavigationChrome()
        .toolbar(.hidden, for: .tabBar)
        .accessibilityIdentifier("user-settings")
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "—")（\(info?["CFBundleVersion"] as? String ?? "—")）"
    }
}

/// The same optional choice is reachable before registration, during Apple
/// onboarding, and after approval. It never writes to an authentication payload.
struct ThemePreferenceRow: View {
    var body: some View {
        NavigationLink {
            AppearanceSettingsView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "paintpalette")
                    .font(.title3)
                    .foregroundStyle(AppTheme.gold)
                VStack(alignment: .leading, spacing: 4) {
                    Text("界面主题")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.warmWhite)
                    Text("\(AppearanceStore.shared.theme.name) · 随时可以更换")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("theme-preference-entry")
        .accessibilityValue(AppearanceStore.shared.theme.name)
    }
}

struct AppearanceSettingsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("选一个喜欢的颜色")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("轻点即可预览并保存。照片、海报和视频保留原本的色彩与深色展示区。")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: Array(
                    repeating: GridItem(.flexible(), spacing: 14),
                    count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
                ), spacing: 14) {
                    ForEach(AppColorTheme.allCases) { theme in
                        themeCard(theme)
                    }
                }

                Text("当前：\(AppearanceStore.shared.theme.name)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AppTheme.muted)
                    .accessibilityIdentifier("theme-current-selection")
                Text("这是可选的本机偏好，不影响注册、审批或浏览权限。换设备后可重新选择。")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.ink.ignoresSafeArea())
        .navigationTitle("外观与主题")
        .navigationBarTitleDisplayMode(.inline)
        .themeNavigationChrome()
        .toolbar(.hidden, for: .tabBar)
        .accessibilityIdentifier("appearance-settings")
    }

    private func themeCard(_ theme: AppColorTheme) -> some View {
        let palette = theme.palette
        let selected = AppearanceStore.shared.theme == theme
        return Button {
            AppearanceStore.shared.select(theme)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle().fill(palette.accent.color).frame(width: 20, height: 20)
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(palette.accent.color)
                    }
                    RoundedRectangle(cornerRadius: 4)
                        .fill(palette.surface.color)
                        .frame(height: 34)
                        .overlay(alignment: .leading) {
                            Capsule().fill(palette.text.color).frame(width: 45, height: 5).padding(10)
                        }
                }
                .accessibilityHidden(true)
                Text(theme.name)
                    .font(.headline)
                    .foregroundStyle(palette.text.color)
                Text(theme.detail)
                    .font(.caption)
                    .foregroundStyle(palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.background.color, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(selected ? palette.accent.color : AppTheme.line, lineWidth: selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.name)，\(theme.detail)")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("theme-choice-\(theme.rawValue)")
    }
}
