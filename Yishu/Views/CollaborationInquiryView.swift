import SwiftUI
import UIKit

struct CollaborationInquiryView: View {
    @Environment(\.openURL) private var openURL
    @State private var contactName = ""
    @State private var contactMethod = ""
    @State private var organization = ""
    @State private var projectType = ProjectType.drama
    @State private var city = ""
    @State private var preferredDate = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
    @State private var budget = ""
    @State private var details = ""
    @State private var copiedItem: CopiedItem?
    @State private var showMailFallback = false

    private var canSend: Bool {
        !contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !contactMethod.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inquiryText: String {
        """
        易姝合作邀约

        联系人：\(valueOrPlaceholder(contactName))
        联系方式：\(valueOrPlaceholder(contactMethod))
        公司 / 项目：\(valueOrPlaceholder(organization))
        合作类型：\(projectType.title)
        拍摄城市：\(valueOrPlaceholder(city))
        预计日期：\(preferredDate.formatted(date: .long, time: .omitted))
        预算范围：\(valueOrPlaceholder(budget))

        项目说明：
        \(valueOrPlaceholder(details))
        """
    }

    private var artistProfileText: String {
        """
        易姝｜短剧演员 / 模特 / 视频创作者
        所在地：浙江 · 杭州
        工作联系：\(ContentCatalog.collaborationEmailAddress)
        官方网站：\(ContentCatalog.websiteURL.absoluteString)
        """
    }

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    artistCard
                    inquiryForm
                    submitActions
                    privacyNote
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 60)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("合作邀约")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(AppTheme.ink, for: .navigationBar)
        .alert(item: $copiedItem) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("知道了")))
        }
        .alert("未找到可用的邮件应用", isPresented: $showMailFallback) {
            Button("打开 QQ 邮箱网页版") { openURL(ContentCatalog.qqMailWebURL) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("邀约内容已经复制，可在任意邮件或聊天应用中粘贴发送。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("COLLABORATION")
                .font(.caption2.weight(.semibold))
                .tracking(3)
                .foregroundStyle(AppTheme.gold)
            Text("合作邀约")
                .font(.system(.largeTitle, design: .serif))
                .accessibilityIdentifier("collaboration-heading")
                .accessibilityAddTraits(.isHeader)
            Text("填写简要信息后，可以通过邮件或任意聊天应用发送。")
                .font(.subheadline)
                .foregroundStyle(AppTheme.muted)
        }
    }

    private var artistCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("易姝")
                        .font(.system(.title, design: .serif))
                        .accessibilityAddTraits(.isHeader)
                    Text("短剧演员 · 模特 · 视频创作者")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Image(systemName: "person.text.rectangle")
                    .font(.title2.weight(.regular))
                    .foregroundStyle(AppTheme.gold)
            }

            Divider().overlay(.white.opacity(0.1))

            HStack {
                Label("浙江 · 杭州", systemImage: "location")
                Spacer()
                Button("复制艺人资料") {
                    UIPasteboard.general.string = artistProfileText
                    copiedItem = .profile
                }
                .foregroundStyle(AppTheme.gold)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .font(.caption)
        }
        .padding(16)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 8))
    }

    private var inquiryForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("邀约信息")
                .font(.system(.title2, design: .serif))
                .accessibilityAddTraits(.isHeader)

            field("联系人 / 称呼", text: $contactName, prompt: "必填")
            field("手机 / 微信 / 邮箱", text: $contactMethod, prompt: "必填")
            field("公司 / 项目名称", text: $organization, prompt: "选填")

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("合作类型")
                Picker("合作类型", selection: $projectType) {
                    ForEach(ProjectType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .tint(AppTheme.warmWhite)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13)
                .frame(minHeight: 48)
                .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
            }

            field("拍摄城市", text: $city, prompt: "选填")

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("预计开始日期")
                DatePicker("预计开始日期", selection: $preferredDate, in: Date()..., displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .tint(AppTheme.gold)
                    .padding(.horizontal, 13)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
            }

            field("预算范围", text: $budget, prompt: "选填，例如 5,000–10,000 元")

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("项目说明")
                ZStack(alignment: .topLeading) {
                    if details.isEmpty {
                        Text("角色、拍摄时长、发布平台及其他需求")
                            .font(.body)
                            .foregroundStyle(AppTheme.muted)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 15)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $details)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 130)
                        .padding(8)
                        .accessibilityLabel("项目说明")
                        .accessibilityHint("请填写角色、拍摄时长、发布平台及其他需求")
                }
                .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var submitActions: some View {
        VStack(spacing: 11) {
            ShareLink(item: inquiryText) {
                Label("分享邀约内容", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(AppTheme.ink)
            }
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.45)

            Button { sendEmail() } label: {
                Label("发送到工作邮箱", systemImage: "envelope")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(AppTheme.warmWhite)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.45)

            Button {
                UIPasteboard.general.string = inquiryText
                copiedItem = .inquiry
            } label: {
                Text("复制邀约内容")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var privacyNote: some View {
        Label("填写内容只保留在当前页面，发送前不会上传到服务器。", systemImage: "lock")
            .font(.caption2)
            .foregroundStyle(AppTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(label)
            TextField(label, text: text, prompt: Text(prompt))
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 13)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(label)
                .accessibilityHint(prompt)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.75))
    }

    private func valueOrPlaceholder(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未填写" : trimmed
    }

    private func sendEmail() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = ContentCatalog.collaborationEmailAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: "易姝合作邀约｜\(organization.isEmpty ? projectType.title : organization)"),
            URLQueryItem(name: "body", value: inquiryText)
        ]

        guard let url = components.url else {
            UIPasteboard.general.string = inquiryText
            showMailFallback = true
            return
        }

        openURL(url) { accepted in
            guard !accepted else { return }
            UIPasteboard.general.string = inquiryText
            showMailFallback = true
        }
    }
}

private enum ProjectType: String, CaseIterable, Identifiable {
    case drama
    case commercial
    case brand
    case modeling
    case event
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .drama: return "短剧 / 影视出演"
        case .commercial: return "商业拍摄"
        case .brand: return "品牌合作"
        case .modeling: return "平面 / 模特"
        case .event: return "活动出席"
        case .other: return "其他合作"
        }
    }
}

private enum CopiedItem: String, Identifiable {
    case profile
    case inquiry

    var id: String { rawValue }
    var title: String { self == .profile ? "艺人资料已复制" : "邀约内容已复制" }
    var message: String { self == .profile ? "可以直接粘贴到聊天或邮件中。" : "可以粘贴到任意聊天或邮件应用中发送。" }
}
