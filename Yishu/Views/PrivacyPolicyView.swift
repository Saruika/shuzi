import SwiftUI

struct PrivacyPolicyView: View {
    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("PRIVACY")
                            .font(.caption2.weight(.semibold))
                            .tracking(3)
                            .foregroundStyle(AppTheme.gold)
                        Text("隐私政策")
                            .font(.system(.largeTitle, design: .serif))
                            .accessibilityIdentifier("privacy-policy-heading")
                            .accessibilityAddTraits(.isHeader)
                        Text("生效日期：2026 年 9 月 5 日 · 说明更新：2026 年 9 月 14 日")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                    }

                    policySection("适用范围", text: "本政策说明“Hi，梳子”App 如何处理注册申请、管理员审批、账号访问、消息通知、天气和必要安全数据。查看 App 的首页、作品、影视、收藏和关于内容前，需要注册账号并获得管理员批准。")

                    policySection("我们处理的数据", bullets: [
                        "联系方式与客户支持：合作表单可填写邮箱、电话号码或微信等联系方式，这些资料与联系人及邀约关联。你通过隐私邮箱主动发送的支持请求，可包含发件邮箱、问题描述及你主动附加的材料；用于答复和处理请求，与可识别的发件人关联。发送失败不会自动复制表单，只有你主动点击复制才会写入剪贴板。",
                        "粉丝账号：昵称、抖音 ID、服务器生成的 UUID 和粉丝身份码。抖音 ID 是注册、Apple 登录资料补全和邀请账号首次设置的必填项，仅用于管理员核验账号身份，不向其他粉丝公开。",
                        "通过 Apple 登录：登录时将 Apple 签名的短时身份令牌和授权码通过 HTTPS 交给服务器完成验证；验证完成后不写入本地存储或日志。服务器保留经验证的 Apple 账号关联标识，并加密保存 Apple 换取的刷新令牌，只用于维持登录关联及在删号时撤销 Apple 授权，保存至你撤销 Apple 授权或删除账号。App 不请求 Apple 姓名或邮箱。本机 Keychain 可保留 Apple 凭据状态查询所需的账号标识，退出或删号时清除。",
                        "管理员邀请：在你本人完成首次设置前，仅保存随机临时身份、邀请有效期和审批记录；临时密码只在创建时展示一次，服务器仅保存标准密码哈希。",
                        "账号安全：密码哈希、随机安装记录的哈希、会话令牌哈希、不可用于登录的会话 ID、安装记录码、登录/到期时间和权限状态。",
                        "消息通知：首次打开 App 时会请求系统通知授权。系统已允许通知且你没有主动关闭当前账号通知时，完成粉丝账号登录及必填资料、处于待审批或已通过状态后，App 会自动开启并连接消息通知，无需再手动打开 App 内开关；未登录或资料未完成时不会上传设备令牌。Apple 提供的不透明推送设备令牌只与当前账号及随机安装记录关联。你可随时在账号页关闭，或在 iOS 系统设置中撤销授权，拒绝通知不影响注册和浏览。切换账号时先停止原账号本机通知，新账号按系统授权及自身选择独立连接，不继承旧账号设备绑定或消息。本机按账号哈希保留通知开关选择以避免换号覆盖主动关闭，服务器确认账号删除后清除该账号本机偏好。服务器加密保存令牌并使用 HMAC 索引，管理员不能查看令牌原文。本机 Keychain 会与随机安装记录一起保存不含通知内容的单调绑定操作序号，用于拒绝迟到或乱序的绑定请求。该数据只用于向你的账号发送审批状态、合作进度和作品动态等通知。",
                        "云端消息箱：保存管理员向你发送的标题、正文、发送时间、收件关系和已读时间。消息箱只用于接收与查看，不提供粉丝之间发送、回复或私聊。你无需允许系统通知也能在登录并完成必填资料后查看本人消息；敏感消息的系统提醒只展示通用提示，原文经账号验证后在 App 内读取。",
                        "密码恢复：管理员创建短时恢复凭据时，服务器保存密码哈希，以及恢复记录的生成标识、创建/过期时间、创建者、首次领取时间、领取安装记录哈希和恢复会话 ID。临时密码只在创建时显示一次，不持久化为可读明文。",
                        "管理员内容上传：仅内容管理员登录后，可主动通过系统照片选择器或文件选择器选取照片、视频和封面并上传发布。这些媒体与管理员账号及发布记录关联，用于向已获批用户提供 App 内容；普通粉丝功能不读取或上传设备照片。",
                        "合作邀约：你可主动填写联系人姓名、联系方式、组织、项目类型、城市、意向日期、预算和项目说明。合作服务未启用服务器提交时，填写内容仅保留在当前页面；只有你主动点击“发送到工作邮箱”并在系统邮件应用中确认后，才由邮件服务交给合作邮箱。若未来明确启用服务器提交，只有你主动点击提交后，上述字段以及粉丝身份码和安装记录码才会通过 HTTPS 交给服务器，供获得合作邀约权限的管理员处理，并由邮件发件队列发送至配置的合作邮箱。系统分享或复制的接收对象仍由你决定。",
                        "天气：仅在你主动开启时使用前台粗略位置，由 Apple WeatherKit 提供天气；App 不持久保存坐标。",
                        "安全与诊断：服务器基础设施可在安全日志中处理 IP 地址，应用限流使用哈希化网络指纹。请求时间、错误状态和有限运行日志可能与已验证账号或会话关联，仅用于防止滥用、保障服务和排查故障，不用于跟踪或广告。",
                    ])

                    policySection("本机外观偏好", text: "你可以在注册时或关于页的设置中选择界面主题。只在本机保存所选主题的标识，不与账号关联、不上传服务器、不用于追踪或广告。主题选择是可选项，不影响注册审批或内容权限；可随时更换或选择黑金恢复默认外观。")

                    policySection("使用目的", text: "上述数据只用于创建和验证账号、密码恢复与修改、让你查看和撤销其他登录设备、发出一次性账号邀请、由本人完成账号设置、提交和处理访问申请、批准或拒绝 App 访问、远程分配权限、向开启通知的指定账号发送与 App 功能相关的消息、让内容管理员上传和发布授权影像、回复你主动发送的合作邀约并安排合作、提供你主动请求的天气、保护服务安全及排查故障。抖音 ID 仅用于管理员辅助核验；未填写时不能完成新账号申请或获得内容访问。我们不使用这些数据进行跨 App 跟踪、定向广告或出售给数据经纪商。")

                    policySection("共享与处理者", text: "账号数据和管理员主动发布的影像保存在用于运行本服务的云服务器上；App 根据已验证账号的状态和权限决定界面中可见的内容。管理员创建邀请或密码恢复时只能看到一次临时凭据，无法再次查询，也无法查看你本人设置的新密码。管理员日常仅能查看核验和权限分配必需的昵称、身份码、权限和抖音 ID，不能查看推送设备令牌。通过 Apple 登录的身份验证与授权撤销由 Apple 处理，通知交付由 Apple Push Notification service（APNs）处理，天气请求由 Apple WeatherKit 处理。我们要求所有为本服务处理用户数据的服务提供方遵守与本政策相同或同等的保护要求。")

                    policySection("保存与删除", bullets: [
                        "账号和权限数据保存至你在 App 内主动删除账号，或者服务依法终止。",
                        "会话最长 30 天；退出、暂停或删除账号时会撤销。",
                        "密码恢复凭据只在 15 分钟内有效；完成恢复、重新生成或删除账号时会移除恢复记录。未完成的过期状态可随账号保留至下次生成或删号，仅用于拒绝过期凭据，不能获得内容访问。",
                        "未完成设置的邀请在 24 小时后失效并删除临时记录；完成设置时会立即撤销临时凭据和旧会话。",
                        "管理员上传的照片、视频和封面保存至内容管理员替换或删除，并按服务器备份周期清理隔离副本。",
                        "推送设备绑定最长 90 天未刷新会自动过期，App 在持续使用时会至少每 24 小时重新确认一次绑定。你在 App 内关闭消息通知、退出、删除或切换账号时，App 会立即请求 iOS 撤销本机远程通知注册；服务器连接可用时，还会在正常会话与安装记录匹配后，全局清除该安装可能残留的旧账号设备绑定。为防止切换账号时的旧网络请求覆盖新账号，服务器会在当前会话期限内保留安装记录哈希、当前账号会话所有权、单调操作序号和期望绑定状态，不含通知内容，最长随登录会话在 30 天内到期。撤销相关会话、删除账号或 APNs 报告令牌无效时，服务器也会删除对应绑定。推送内容与投递状态最长保留 30 天后清理，用于防重复发送、有界重试和故障排查。",
                        "云端消息原文、收件关系和已读状态自创建起最长保留 30 天；已读时间只用于消息状态同步，不用于广告、画像或追踪。删除账号时移除你的收件关系和已读状态；当一条消息已无任何收件用户时清除其正文。App 不把消息正文写入本地持久存储，退出或切换账号时清空内存中的消息。关闭系统通知仅停止设备提醒，不会删除消息箱内容。",
                        "合作邀约信息仅用于回复和安排合作。邮件模式下由合作邮箱保留；若服务器提交功能未来启用，后台邀约、发件队列和关联审计会保留至事项处理完毕，但在你删除账号时会一并删除与该账号关联的在线记录。已经交给邮件服务的邮箱副本无法由 App 自动撤回，你可通过隐私邮箱请求查阅、更正或删除；在备份中的剩余副本随服务器备份周期清理，依法必须保留的记录除外。",
                        "若删除 Apple 账号时 Apple 的授权撤销服务暂时不可用，账号资料仍会立即删除；仅无法回链用户或抖音 ID 的加密令牌进入最多 7 天、最多 8 次的有界重试队列，并在成功、到期或达到次数上限时销毁。",
                        "在登录后的账号页，或尚未获批的申请状态页点击“永久删除账号与个人资料”，密码账号通过近期密码验证，Apple 账号通过一次原生 Apple 重新授权后，即可由你自己发起完整删除，不需要联系客服或等待审批。",
                        "删除会立即移除账号、昵称、已填写的抖音 ID、身份码、权限、恢复记录、与账号关联的安装记录和设备令牌、会话，以及服务器上与该账号关联的合作邀约、待发邮件记录和关联审计，并清除本机该账号的收藏与最近浏览。为阻止删号前的迟到请求重新绑定，仅保留已与账号断开关联、无法回链昵称或抖音 ID 的安装哈希、操作序号和“已解绑”状态，最长保留至原会话到期且不超过 30 天，之后自动删除。隔离备份中的残留数据随备份周期删除，且不用于日常业务。已经交给外部邮件服务的副本需通过隐私邮箱申请删除；依法必须保留的记录除外。",
                    ])

                    policySection("你的选择", text: "抖音 ID 是完成账号申请和访问内容的必需资料；如你不愿提供，可不完成注册或邀请设置，并可随时删除已创建的申请或账号。消息通知是可选功能；你可在账号页随时关闭并解绑设备，也可在 iOS 系统设置中更改通知权限。你还可以不开启天气、退出账号、要求管理员更正不准确资料，或随时在首次设置页、申请页或账号页删除账号来撤回后续处理同意。待审批、被拒绝、被暂停或旧账号等待资料升级，均不影响主动删除。依法必须保留的安全或法律记录除外。")

                    policySection("安全", text: "App 使用 HTTPS、Keychain、有效期会话、令牌哈希、设备安装绑定、限流和最小权限管理来减少未授权访问风险。App 不读取硬件 UDID，也不使用 IDFA。")

                    policySection(
                        "联系与政策更新",
                        text: "商务合作及邀约回复请联系合作邮箱 \(ContentCatalog.collaborationEmailAddress)。如需查阅、更正或删除个人信息、更正账号资料、询问隐私事项或反馈本政策，请联系隐私邮箱 \(ContentCatalog.privacyContactEmailAddress)。政策发生实质变化时，会更新生效日期，并在适用时重新获取同意。"
                    )

                    Link(destination: ContentCatalog.privacyEmailURL) {
                        Label("联系隐私邮箱", systemImage: "envelope")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(AppTheme.warmWhite)
                    }
                    .accessibilityIdentifier("privacy-contact-email")

                    Link(destination: ContentCatalog.privacyPolicyURL) {
                        Label("查看网页版隐私政策", systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(AppTheme.ink)
                    }
                    .accessibilityIdentifier("privacy-policy-web-link")
                }
                .padding(22)
                .padding(.bottom, 48)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("隐私政策")
        .navigationBarTitleDisplayMode(.inline)
        .themeNavigationChrome()
        .stableDetailTabBar()
    }

    private func policySection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(.title2, design: .serif))
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.body)
                .lineSpacing(6)
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func policySection(_ title: String, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.system(.title2, design: .serif))
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .top, spacing: 9) {
                    Circle()
                        .fill(AppTheme.gold)
                        .frame(width: 4, height: 4)
                        .padding(.top, 8)
                    Text(bullet)
                        .font(.body)
                        .lineSpacing(6)
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
