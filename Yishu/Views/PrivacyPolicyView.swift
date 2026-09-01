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
                        Text("生效日期：2026 年 9 月 1 日")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                    }

                    policySection("适用范围", text: "本政策说明“Hi，梳子”App 如何处理注册申请、管理员审批、账号访问、天气和必要安全数据。查看 App 的首页、作品、影视、收藏和关于内容前，需要注册账号并获得管理员批准。")

                    policySection("我们处理的数据", bullets: [
                        "粉丝账号：昵称、必填的抖音 ID、服务器生成的 UUID 和粉丝身份码。",
                        "通过 Apple 登录：登录时将 Apple 签名的短时身份令牌和授权码通过 HTTPS 交给服务器完成验证；验证完成后不写入本地存储或日志。服务器保留经验证的 Apple 账号关联标识，并加密保存 Apple 换取的刷新令牌，只用于维持登录关联及在删号时撤销 Apple 授权，保存至你撤销 Apple 授权或删除账号。App 不请求 Apple 姓名或邮箱。本机 Keychain 可保留 Apple 凭据状态查询所需的账号标识，退出或删号时清除。",
                        "管理员邀请：在你本人完成首次设置前，仅保存随机临时身份、邀请有效期和审批记录；临时密码只在创建时展示一次，服务器仅保存标准密码哈希。",
                        "账号安全：密码哈希、随机安装记录的哈希、会话令牌哈希、不可用于登录的会话 ID、安装记录码、登录/到期时间和权限状态。",
                        "密码恢复：管理员创建短时恢复凭据时，服务器保存密码哈希，以及恢复记录的生成标识、创建/过期时间、创建者、首次领取时间、领取安装记录哈希和恢复会话 ID。临时密码只在创建时显示一次，不持久化为可读明文。",
                        "管理员内容上传：仅内容管理员登录后，可主动通过系统照片选择器或文件选择器选取照片、视频和封面并上传发布。这些媒体与管理员账号及发布记录关联，用于向已获批用户提供 App 内容；普通粉丝功能不读取或上传设备照片。",
                        "天气：仅在你主动开启时使用前台粗略位置，由 Apple WeatherKit 提供天气；App 不持久保存坐标。",
                        "安全与诊断：服务器基础设施可在安全日志中处理 IP 地址，应用限流使用哈希化网络指纹。请求时间、错误状态和有限运行日志可能与已验证账号或会话关联，仅用于防止滥用、保障服务和排查故障，不用于跟踪或广告。",
                    ])

                    policySection("使用目的", text: "上述数据只用于创建和验证账号、密码恢复与修改、让你查看和撤销其他登录设备、发出一次性账号邀请、由本人完成账号设置、提交和处理访问申请、由管理员核对抖音 ID、批准或拒绝 App 访问、远程分配权限、让内容管理员上传和发布授权影像、提供你主动请求的天气、保护服务安全及排查故障。我们不使用这些数据进行跨 App 跟踪、定向广告或出售给数据经纪商。")

                    policySection("共享与处理者", text: "账号数据和管理员主动发布的影像保存在用于运行本服务的云服务器上；已发布影像仅向具有相应权限的用户展示。管理员创建邀请或密码恢复时只能看到一次临时凭据，无法再次查询，也无法查看你本人设置的新密码。管理员日常仅能查看核验和权限分配必需的昵称、抖音 ID、身份码和权限。通过 Apple 登录的身份验证与授权撤销由 Apple 处理，天气请求由 Apple WeatherKit 处理。我们要求所有为本服务处理用户数据的服务提供方遵守与本政策相同或同等的保护要求。")

                    policySection("保存与删除", bullets: [
                        "账号和权限数据保存至你在 App 内主动删除账号，或者服务依法终止。",
                        "会话最长 30 天；退出、暂停或删除账号时会撤销。",
                        "密码恢复凭据只在 15 分钟内有效；完成恢复、重新生成或删除账号时会移除恢复记录。未完成的过期状态可随账号保留至下次生成或删号，仅用于拒绝过期凭据，不能获得内容访问。",
                        "未完成设置的邀请在 24 小时后失效并删除临时记录；完成设置时会立即撤销临时凭据和旧会话。",
                        "管理员上传的照片、视频和封面保存至内容管理员替换或删除，并按服务器备份周期清理隔离副本。",
                        "若删除 Apple 账号时 Apple 的授权撤销服务暂时不可用，账号资料仍会立即删除；仅无法回链用户或抖音 ID 的加密令牌进入最多 7 天、最多 8 次的有界重试队列，并在成功、到期或达到次数上限时销毁。",
                        "在登录后的账号页，或尚未获批的申请状态页点击“永久删除账号与个人资料”，密码账号通过近期密码验证，Apple 账号通过一次原生 Apple 重新授权后，即可由你自己发起完整删除，不需要联系客服或等待审批。",
                        "删除会立即移除账号、昵称、抖音 ID、身份码、权限、恢复记录、安装记录和会话，并清除本机该账号的收藏与最近浏览。隔离备份中的残留数据随备份周期删除，且不用于日常业务。",
                    ])

                    policySection("你的选择", text: "收到管理员邀请后，你可以选择不完成设置；此时不会填写或保存你的真实抖音 ID，也不能进入受限内容页面。你也可以不开启天气、退出账号、要求管理员更正不准确资料，或随时在首次设置页、申请页或账号页删除账号来撤回后续处理同意。待审批、被拒绝或被暂停均不影响主动删除。依法必须保留的安全或法律记录除外。")

                    policySection("安全", text: "App 使用 HTTPS、Keychain、有效期会话、令牌哈希、设备安装绑定、限流和最小权限管理来减少未授权访问风险。App 不读取硬件 UDID，也不使用 IDFA。")

                    policySection("联系与政策更新", text: "如需更正账号资料或询问隐私事项，请联系 369476120@qq.com。政策发生实质变化时，会更新生效日期，并在适用时重新获取同意。")

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
        .toolbarBackground(AppTheme.ink, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
    }

    private func policySection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(.title2, design: .serif))
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.body)
                .lineSpacing(6)
                .foregroundStyle(.white.opacity(0.72))
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
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
