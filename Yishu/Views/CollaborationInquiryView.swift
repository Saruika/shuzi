import SwiftUI
import UIKit

struct CollaborationInquiryView: View {
    @EnvironmentObject private var fanAccount: FanAccountStore
    @Environment(\.openURL) private var openURL
    @State private var contactName = ""
    @State private var contactMethod = ""
    @State private var organization = ""
    @State private var projectType = ProjectType.drama
    @State private var city = ""
    @State private var preferredDate = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
    @State private var budget = ""
    @State private var details = ""
    @State private var acceptsSubmissionNotice = false
    @State private var submissionID = UUID()
    @State private var isSubmitting = false
    @State private var notice: CollaborationNotice?
    @State private var serverSubmissionEnabled = false
    @State private var showMailFallback = false

    private let submissionClient = CollaborationSubmissionClient()

    private var canSend: Bool {
        !isSubmitting
            && CollaborationSubmissionValidation.isValidRequiredField(
                contactName,
                maximumLength: 80
            )
            && CollaborationSubmissionValidation.isValidRequiredField(
                contactMethod,
                maximumLength: 160
            )
            && (!serverSubmissionEnabled
                || (fanAccount.isApproved && acceptsSubmissionNotice))
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
        .stableDetailTabBar()
        .themeNavigationChrome()
        .alert(item: $notice) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("知道了")))
        }
        .alert("未找到可用的邮件应用", isPresented: $showMailFallback) {
            Button("复制邀约内容") { copyInquiry() }
            Button("打开 QQ 邮箱网页版") { openURL(ContentCatalog.qqMailWebURL) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("邀约尚未发送，也未自动复制。你可以选择复制，再粘贴到邮件中发送。")
        }
        .onChange(of: fanAccount.collaborationContext) { _, _ in
            serverSubmissionEnabled = false
            notice = nil
            showMailFallback = false
            resetSubmittedForm()
        }
        .task(id: fanAccount.collaborationContext) { await refreshSubmissionCapability() }
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
            Text(
                serverSubmissionEnabled
                    ? "填写简要信息后直接提交，管理员会在收件箱中处理。"
                    : "填写简要信息后，通过系统邮件应用发送。"
            )
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

            Divider().overlay(AppTheme.line)

            HStack {
                Label("浙江 · 杭州", systemImage: "location")
                Spacer()
                Button("复制艺人资料") {
                    UIPasteboard.general.string = artistProfileText
                    notice = .profileCopied
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
            if serverSubmissionEnabled {
                Toggle(isOn: $acceptsSubmissionNotice) {
                    Text("我同意将上述邀约信息提交至服务器，供管理员处理并发送到合作邮箱。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tint(AppTheme.gold)
                .accessibilityIdentifier("collaboration-consent")

                Button {
                    Task { await submitInquiry() }
                } label: {
                    HStack(spacing: 10) {
                        if isSubmitting {
                            ProgressView().tint(AppTheme.ink)
                        }
                        Label(
                            isSubmitting ? "正在提交" : "提交合作邀约",
                            systemImage: isSubmitting ? "hourglass" : "paperplane.fill"
                        )
                    }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(AppTheme.ink)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.45)
                .accessibilityIdentifier("collaboration-submit")
            } else {
                Button { sendEmail() } label: {
                    Label("发送到工作邮箱", systemImage: "envelope")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(AppTheme.ink)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.45)
                .accessibilityIdentifier("collaboration-email")
            }

            Button {
                copyInquiry()
                notice = .inquiryCopied(serverSubmissionEnabled: serverSubmissionEnabled)
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
        Label(
            serverSubmissionEnabled
                ? "点击提交前，填写内容只保留在当前页面。仅在服务器确认已保存后，App 才会显示提交成功；合作邮件由服务器可靠重试。"
                : "填写内容只保留在当前页面，发送前不会上传到服务器。",
            systemImage: "lock"
        )
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
            .foregroundStyle(AppTheme.muted)
    }

    private func valueOrPlaceholder(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未填写" : trimmed
    }

    private func submitInquiry() async {
        guard serverSubmissionEnabled, canSend,
              let context = fanAccount.collaborationContext else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let draft = try CollaborationSubmissionDraft(
                submissionID: submissionID,
                contactName: contactName,
                contactMethod: contactMethod,
                organization: organization,
                projectType: projectType.rawValue,
                city: city,
                preferredDate: preferredDate,
                budget: budget,
                details: details
            )
            let receipt = try await submissionClient.submit(draft, using: fanAccount)
            guard fanAccount.collaborationContext == context, !Task.isCancelled else { return }
            notice = .submitted(requestID: receipt.requestID)
            resetSubmittedForm()
        } catch {
            guard fanAccount.collaborationContext == context, !Task.isCancelled else { return }
            let message = (error as? LocalizedError)?.errorDescription
                ?? CollaborationSubmissionError.networkUnavailable.errorDescription
                ?? "合作邀约暂时无法提交。"
            notice = .submissionFailed(message)
        }
    }

    private func resetSubmittedForm() {
        contactName = ""
        contactMethod = ""
        organization = ""
        city = ""
        budget = ""
        details = ""
        projectType = .drama
        preferredDate = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
        acceptsSubmissionNotice = false
        submissionID = UUID()
    }

    private func refreshSubmissionCapability() async {
        serverSubmissionEnabled = false
        guard let context = fanAccount.collaborationContext,
              let capabilities = try? await submissionClient.fetchCapabilities(using: fanAccount),
              fanAccount.collaborationContext == context, !Task.isCancelled else { return }
        serverSubmissionEnabled = capabilities.collaborationSubmissionEnabled
    }

    private func copyInquiry() {
        UIPasteboard.general.string = inquiryText
    }

    private func sendEmail() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = ContentCatalog.collaborationEmailAddress
        components.queryItems = [
            URLQueryItem(
                name: "subject",
                value: "易姝合作邀约｜\(organization.isEmpty ? projectType.title : organization)"
            ),
            URLQueryItem(name: "body", value: inquiryText),
        ]
        guard let url = components.url else {
            showMailFallback = true
            return
        }
        openURL(url) { accepted in
            guard !accepted else { return }
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

private enum CollaborationNotice: Identifiable {
    case profileCopied
    case inquiryCopied(serverSubmissionEnabled: Bool)
    case submitted(requestID: UUID)
    case submissionFailed(String)

    var id: String {
        switch self {
        case .profileCopied: "profile-copied"
        case .inquiryCopied(let serverSubmissionEnabled):
            "inquiry-copied-\(serverSubmissionEnabled)"
        case .submitted(let requestID): "submitted-\(requestID.uuidString)"
        case .submissionFailed(let message): "failed-\(message)"
        }
    }

    var title: String {
        switch self {
        case .profileCopied: "艺人资料已复制"
        case .inquiryCopied: "邀约内容已复制"
        case .submitted: "合作邀约已收到"
        case .submissionFailed: "未能提交"
        }
    }

    var message: String {
        switch self {
        case .profileCopied:
            "可以直接粘贴到聊天或邮件中。"
        case .inquiryCopied(let serverSubmissionEnabled):
            serverSubmissionEnabled
                ? "这是本地副本；如需管理员收到，请仍点击“提交合作邀约”。"
                : "这是本地副本；如需发送，请点击“发送到工作邮箱”并在邮件应用中确认。"
        case .submitted(let requestID):
            "服务器已保存，并已进入管理员收件箱和合作邮件发送队列。请求编号：\(requestID.uuidString.lowercased())"
        case .submissionFailed(let message):
            message
        }
    }
}

enum CollaborationRequestStatus: String, Codable, CaseIterable, Identifiable {
    case received
    case reviewing
    case contacted
    case closed
    case spam

    var id: String { rawValue }

    var title: String {
        switch self {
        case .received: "待处理"
        case .reviewing: "跟进中"
        case .contacted: "已联系"
        case .closed: "已完成"
        case .spam: "无效邀约"
        }
    }
}

struct AppFeatureCapabilities: Decodable, Equatable {
    let collaborationSubmissionEnabled: Bool
    let collaborationInboxEnabled: Bool
    let pushNotificationsEnabled: Bool
    let canSendPushNotifications: Bool

    init(
        collaborationSubmissionEnabled: Bool,
        collaborationInboxEnabled: Bool,
        pushNotificationsEnabled: Bool = false,
        canSendPushNotifications: Bool = false
    ) {
        self.collaborationSubmissionEnabled = collaborationSubmissionEnabled
        self.collaborationInboxEnabled = collaborationInboxEnabled
        self.pushNotificationsEnabled = pushNotificationsEnabled
        self.canSendPushNotifications = canSendPushNotifications
    }

    private enum CodingKeys: String, CodingKey {
        case collaborationSubmissionEnabled
        case collaborationInboxEnabled
        case pushNotificationsEnabled
        case canSendPushNotifications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collaborationSubmissionEnabled = try container.decode(
            Bool.self,
            forKey: .collaborationSubmissionEnabled
        )
        collaborationInboxEnabled = try container.decode(
            Bool.self,
            forKey: .collaborationInboxEnabled
        )
        pushNotificationsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .pushNotificationsEnabled
        ) ?? false
        canSendPushNotifications = try container.decodeIfPresent(
            Bool.self,
            forKey: .canSendPushNotifications
        ) ?? false
    }

    var isConsistent: Bool {
        collaborationSubmissionEnabled == collaborationInboxEnabled
            && (!canSendPushNotifications || pushNotificationsEnabled)
    }
}

struct CollaborationSubmissionDraft: Encodable, Equatable {
    let submissionID: String
    let contactName: String
    let contactMethod: String
    let organization: String
    let projectType: String
    let city: String
    let preferredDate: String
    let budget: String
    let details: String

    init(
        submissionID: UUID,
        contactName: String,
        contactMethod: String,
        organization: String,
        projectType: String,
        city: String,
        preferredDate: Date,
        budget: String,
        details: String
    ) throws {
        let normalizedContactName = try CollaborationSubmissionValidation.requiredSingleLine(
            contactName,
            maximumLength: 80
        )
        let normalizedContactMethod = try CollaborationSubmissionValidation.requiredSingleLine(
            contactMethod,
            maximumLength: 160
        )
        guard ["drama", "commercial", "brand", "modeling", "event", "other"]
            .contains(projectType) else {
            throw CollaborationSubmissionError.invalidInput
        }

        self.submissionID = submissionID.uuidString.lowercased()
        self.contactName = normalizedContactName
        self.contactMethod = normalizedContactMethod
        self.organization = try CollaborationSubmissionValidation.optionalSingleLine(
            organization,
            maximumLength: 120
        )
        self.projectType = projectType
        self.city = try CollaborationSubmissionValidation.optionalSingleLine(
            city,
            maximumLength: 80
        )
        self.preferredDate = CollaborationSubmissionValidation.calendarDate(preferredDate)
        self.budget = try CollaborationSubmissionValidation.optionalSingleLine(
            budget,
            maximumLength: 80
        )
        self.details = try CollaborationSubmissionValidation.multilineDetails(details)
    }
}

enum CollaborationSubmissionValidation {
    static func isValidRequiredField(_ value: String, maximumLength: Int) -> Bool {
        (try? requiredSingleLine(value, maximumLength: maximumLength)) != nil
    }

    static func requiredSingleLine(_ value: String, maximumLength: Int) throws -> String {
        let normalized = try normalizedSingleLine(value, maximumLength: maximumLength)
        guard !normalized.isEmpty else { throw CollaborationSubmissionError.invalidInput }
        return normalized
    }

    static func optionalSingleLine(_ value: String, maximumLength: Int) throws -> String {
        try normalizedSingleLine(value, maximumLength: maximumLength)
    }

    static func multilineDetails(_ value: String) throws -> String {
        let normalizedNewlines = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedNewlines.count <= 4_000,
              !normalizedNewlines.unicodeScalars.contains(where: isDisallowedControl) else {
            throw CollaborationSubmissionError.invalidInput
        }
        return normalizedNewlines
    }

    static func calendarDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        // Preserve the calendar day selected by the user. Converting a local
        // midnight to UTC can otherwise move the date back one day in China.
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func isCanonicalUUIDv4(_ value: String) -> Bool {
        value.range(
            of: #"^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$"#,
            options: .regularExpression
        ) != nil && UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func normalizedSingleLine(
        _ value: String,
        maximumLength: Int
    ) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= maximumLength,
              !normalized.contains("\n"),
              !normalized.contains("\r"),
              !normalized.unicodeScalars.contains(where: isDisallowedControl) else {
            throw CollaborationSubmissionError.invalidInput
        }
        return normalized
    }

    private static func isDisallowedControl(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar)
            && scalar != "\n".unicodeScalars.first
            && scalar != "\t".unicodeScalars.first
    }
}

struct CollaborationSubmissionReceipt: Decodable, Equatable {
    let requestID: UUID
    let status: CollaborationRequestStatus
    let receivedAt: Date
    let duplicate: Bool

    private enum CodingKeys: CodingKey {
        case requestID
        case status
        case receivedAt
        case duplicate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .requestID)
        guard CollaborationSubmissionValidation.isCanonicalUUIDv4(rawID),
              let requestID = UUID(uuidString: rawID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .requestID,
                in: container,
                debugDescription: "Invalid collaboration request identifier"
            )
        }
        self.requestID = requestID
        status = try container.decode(CollaborationRequestStatus.self, forKey: .status)
        receivedAt = try container.decode(Date.self, forKey: .receivedAt)
        duplicate = try container.decode(Bool.self, forKey: .duplicate)
    }
}

enum CollaborationReceiptValidation {
    static func isAccepted(
        _ receipt: CollaborationSubmissionReceipt,
        now: Date = .now
    ) -> Bool {
        // A duplicate retry can legitimately observe an administrator-advanced
        // status. The canonical receipt ID, known status enum and timestamp are
        // the integrity boundary; only requiring `received` creates false
        // failures after the server has already persisted and processed it.
        receipt.receivedAt <= now.addingTimeInterval(5 * 60)
    }
}

enum CollaborationSubmissionError: LocalizedError {
    case invalidInput
    case sessionExpired
    case networkUnavailable
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            "请检查联系人、联系方式和邀约内容后重试。"
        case .sessionExpired:
            "登录已失效，请重新登录后提交。"
        case .networkUnavailable:
            "无法安全连接合作服务，请检查网络后重试。"
        case .invalidResponse:
            "合作服务返回了无法验证的结果，请稍后重试。"
        case .server(let message):
            message
        }
    }
}

@MainActor
protocol CollaborationAccount: AnyObject {
    var collaborationContext: FanNotificationContext? { get }
    func authorizeCollaborationRequest(_ request: inout URLRequest, context: FanNotificationContext) throws
}

@MainActor
struct CollaborationSubmissionClient {
    // View values are recreated frequently. Keep one stateless, cookie/cache-free
    // transport for the process rather than creating a retained delegate session
    // on every View initialization. Account authorization remains per request.
    private static let sharedSession = SecureURLSessionFactory.make(
        requestTimeout: 30, resourceTimeout: 45
    )
    private let send: (URLRequest) async throws -> (Data, URLResponse)

    init(session: URLSession? = nil) {
        let session = session ?? Self.sharedSession
        self.send = { try await session.data(for: $0) }
    }

    init(send: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.send = send
    }

    func fetchCapabilities(using account: any CollaborationAccount) async throws -> AppFeatureCapabilities {
        guard let context = account.collaborationContext else { throw CollaborationSubmissionError.sessionExpired }
        let endpoint = context.environment.apiRoot.appending(path: "shuzijun/v1/app-capabilities")
        let (data, http) = try await response(
            endpoint: endpoint,
            method: "GET",
            body: nil,
            account: account,
            context: context,
            maximumBytes: 16 * 1_024
        )
        guard (200..<300).contains(http.statusCode) else {
            throw responseError(data: data, http: http)
        }
        guard !data.isEmpty,
              AppNetworkSecurityPolicy.isJSONMIMEType(
                http.value(forHTTPHeaderField: "Content-Type")
              ),
              let capabilities = try? JSONDecoder().decode(
                AppFeatureCapabilities.self,
                from: data
              ),
              capabilities.isConsistent else {
            throw CollaborationSubmissionError.invalidResponse
        }
        return capabilities
    }

    func submit(_ draft: CollaborationSubmissionDraft, using account: any CollaborationAccount) async throws
        -> CollaborationSubmissionReceipt {
        guard let context = account.collaborationContext else { throw CollaborationSubmissionError.sessionExpired }
        let endpoint = context.environment.apiRoot.appending(path: "shuzijun/v1/collaboration-requests")
        let (data, http) = try await response(
            endpoint: endpoint,
            method: "POST",
            body: try JSONEncoder().encode(draft),
            account: account,
            context: context,
            maximumBytes: 64 * 1_024
        )
        guard (200..<300).contains(http.statusCode) else {
            throw responseError(data: data, http: http)
        }
        guard !data.isEmpty,
              AppNetworkSecurityPolicy.isJSONMIMEType(
                http.value(forHTTPHeaderField: "Content-Type")
              ) else {
            throw CollaborationSubmissionError.invalidResponse
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let receipt = try? decoder.decode(CollaborationSubmissionReceipt.self, from: data),
              CollaborationReceiptValidation.isAccepted(receipt) else {
            throw CollaborationSubmissionError.invalidResponse
        }
        return receipt
    }

    private func response(
        endpoint: URL,
        method: String,
        body: Data?,
        account: any CollaborationAccount,
        context: FanNotificationContext,
        maximumBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        guard context.environment.allowsAPIURL(endpoint),
              account.collaborationContext == context,
              !Task.isCancelled,
              ["GET", "POST"].contains(method) else {
            throw CollaborationSubmissionError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue(AppNetworkIdentity.userAgent(for: .collaboration), forHTTPHeaderField: "User-Agent")
        try account.authorizeCollaborationRequest(&request, context: context)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            guard account.collaborationContext == context, !Task.isCancelled else {
                throw CollaborationSubmissionError.sessionExpired
            }
            throw CollaborationSubmissionError.networkUnavailable
        }
        guard account.collaborationContext == context, !Task.isCancelled else {
            throw CollaborationSubmissionError.sessionExpired
        }
        guard data.count <= maximumBytes,
              let http = response as? HTTPURLResponse,
              http.url == endpoint,
              context.environment.allowsAPIURL(http.url) else {
            throw CollaborationSubmissionError.invalidResponse
        }
        return (data, http)
    }

    private func responseError(
        data: Data,
        http: HTTPURLResponse
    ) -> CollaborationSubmissionError {
        if http.statusCode == 401 { return .sessionExpired }
        let payload = AppNetworkSecurityPolicy.isJSONMIMEType(
            http.value(forHTTPHeaderField: "Content-Type")
        ) ? try? JSONDecoder().decode(CollaborationServerError.self, from: data) : nil
        return .server(
            CollaborationSubmissionClient.safeServerMessage(
                payload?.message,
                statusCode: http.statusCode
            )
        )
    }

    private static func safeServerMessage(_ raw: String?, statusCode: Int) -> String {
        guard (400..<500).contains(statusCode), let raw else {
            return "合作服务暂时不可用（HTTP \(statusCode)）。"
        }
        let withoutHTML = String(raw.prefix(300)).replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let printable = withoutHTML.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let normalized = String(String.UnicodeScalarView(printable))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.isEmpty
            ? "合作邀约提交失败（HTTP \(statusCode)）。"
            : String(normalized.prefix(180))
    }
}

private struct CollaborationServerError: Decodable {
    let message: String?
}
