# App Store 首次上架就绪检查

## 当前补充：2026-09-11 App 备案号已由用户提供

用户确认工信部审批通过，并提供 App 备案号 **粤ICP备20060024号-3A**。
此信息已纳入准备材料；尚未独立核验备案名称/主体，也未写入或通过 Apple 后台验证。
App 名称保持“Hi，梳子”，开发者名称沿用 Apple 认证实名。
详见 [备案资料补充记录](Server/releases/v1.4.0-build6-appstore-preflight2.md)。
下方“备案申请中/未取得号码”均为历史快照，不代表当前用户提供信息。
正式审核实时状态待恢复官方访问后核查；不能把取得备案号等同于已送审或已上架。

## 当前状态：2026-09-09 正式审核准备

本段优先于下方历史快照。[Build 6 正式审核准备记录](Server/releases/v1.4.0-build6-appstore-preflight1.md)：
TestFlight 1.4.0 (6) 已上传并通过处理；用户要求正式送审后，已将该构建关联到正式版本并回读。
正式版本仍为 PREPARE_FOR_SUBMISSION，**尚未提交正式审核**。商店截图集、支持网址、版权主体为空；
需确认 App 备案及内容权利申报，补全审核说明并复核隐私/价格/发行地区，不擅自改变大陆首发意图。
下面的旧构建号和“未上传”描述仅表示对应历史阶段，不代表当前 TestFlight 状态。

## 最新证据更新：2026-09-08（UTC+8）

本段优先于下方历史快照，正式上架目标仍未完成，未上传新的 TestFlight 包。

- **正式注销保留修复已部署，新包待完整回归**：[preview36](Server/releases/v1.4.0-build4-review-env-preview36.md)
  备用、上海依次部署 PHP 1.5.13.12，完整清单、服务、HTTP 和任务恢复均回读，备份保留。
  下方“正式未部署”描述为历史状态。最新 b912868 的 1.4.0 (4) 已归档、导出，发行包和
  Apple 上传前校验通过；未上传。用户已授权无重大问题后直接上传 TestFlight，当前完整
  本地回归仍在运行，不应将正式上架资料的未完成混同于构建已上传或已可测试。
- **浅色相册文字已修正，完整回归已启动**：[preview35](Server/releases/v1.4.0-build4-review-env-preview35.md)
  使用既有主题文字颜色改善照片留白上的可读性，不恢复黑色蒙版，不改布局/图片/播放器。
  两端各 252 单元和六次选定 UI 执行通过；首轮 iPad 色值表示误判已修正，新的完整矩阵
  单元阶段零失败、1 个真实服务 opt-in 跳过，UI 仍在运行；不将原失败结果改记为通过。
  两节点的候选预检均已通过，未替换正式插件或停止服务，不能解除正式注销保留的发布阻塞。
- **主流布局专项已复验**：[preview34](Server/releases/v1.4.0-build4-review-env-preview34.md)
  两端各 250 单元及 iPhone 22/iPad 34 次选定 UI 执行通过；另有月白主题七个页面状态的
  边缘像素检查，两端各四次真实横竖屏/系统明暗执行通过。首次通知授权均单独先行验证。
  正式主节点候选 dry-run 通过，但正式插件未替换。已识别相册白字在浅色留白上的可读性问题，
  必须保留透明背景单独改善；不能把边缘检查通过视为完整 UI 或上架就绪。
  文稿下 Git 对象读取停顿后，已保留原目录，并将同提交与本轮修改恢复到 Library 下独立副本。
- **相册透明文字层候选**：移除卡片 82% 黑底、详情底部 96% 渐变和序号黑色胶囊，
  仅保留文字轮廓的小范围阴影，不改相册、标题、图片内容或播放器。透明度渲染回归已通过；
  新增两端明暗主题的相册进入/打开照片/关闭回归。见 [preview30](Server/releases/v1.4.0-build4-review-env-preview30.md)。
- **作品保留规则已获确认**：管理员注销时，已发布的艺人作品保留并解除上传者关联，
  个人账号资料与未发布且未使用的上传素材删除。[preview31](Server/releases/v1.4.0-build4-review-env-preview31.md)
  已实现候选并通过真实数据库 434 项断言，包括故障后重试和核心删号。
  [preview32](Server/releases/v1.4.0-build4-review-env-preview32.md) 已补 App/WordPress REST 发布/上传
  与删号互斥，双 MySQL 连接测试覆盖锁后撤权、令牌缓存与实际文件生命周期，最终 460 项断言通过。
  后续已部署到独立审核站，精确清单、PHP/API、匿名管理 401 和隔离策略均回读。
  iPhone 17 Pro Max / iPad Pro 13-inch M5 原生真实注册、审批、管理员绑定、上传发布、撤权、
  主动注销及作品保留各 1 通过/0 失败/0 跳过；临时账号/素材/维护凭据均清理。
  测试先纠正未签名包的 Keychain -34018 以及文稿构建缓存的 Finder 属性签名错误，
  再用正常 ad-hoc 签名复验，详见 [preview33](Server/releases/v1.4.0-build4-review-env-preview33.md)。
  正式节点尚未升级，不能解除全部发布阻塞。
- **云端 #135 已终态通过，覆盖范围已核实**：2026-09-07 09:57（UTC+8）结束，
  源码为 `3808d1151c63d1864e772f19ddc99d7be3a6c1c9`，不是最新候选。
  iPhone 唯一用例 308 通过/4 跳过，iPad 311 通过/1 跳过，均零失败；两端首次通知授权各 1 通过。
  SAST/SCA、SBOM、来源检查和 Release 分析/包检查成功。公网照片专项在该运行未启用。
  详见 [云端验收记录](QA_CI_135.md)。下方历史“仍在运行”不再是当前状态；
  这个绿灯不能覆盖后续环境入口、照片-only 管理协议或 preview28 的真实删号误删问题。
- **重启恢复**：已从保留的 Git 提交恢复干净源码到文稿下的独立持久目录，原项目未提交改动未触碰。
  NAS 重新挂载后，最新 Build 4 IPA 的 SHA-256 与包预检 2 一致，归档版本为 1.4.0 (4)。
  原 `/tmp` 工作目录和本机测试结果已不可访问；未把旧结果路径标成仍可打开，后续必须重新生成所需原始证据。
  此次只恢复文件访问与保存测试记录，不代表重新构建、部署或上传完成。
- **新发现 P0：管理员注销导致已发布相册图片丢失**：独立审核环境真实原生上传/建相册/改顺序成功，
  撤销管理员后注销该账号，相册仍在、两张图片变成零张。两次实际复现；不是 UI 加载超时。
  当前删号调用 `wp_delete_user($user_id)`，未传重新归属目标，会触发 WordPress 对该用户所建媒体的删除。
  旧代码保留回归失败，preview31/32 候选已通过隔离回归并部署审核站；正式节点仍未修复，暂停发布。
  原有审核相册未修改，临时素材/账号/管理访问码均已独立确认清理。详见
  [preview28](Server/releases/v1.4.0-build4-review-env-preview28.md)。不能再用 preview27 的窄流程通过代表此完整场景通过。
- **最新源码的实际 Build 4 已重新准备**：干净 `4ad7d09` 归档/导出及实际包检查通过，
  包含 Release 环境入口和照片-only 管理协议；Apple 上传前校验退出 0、有成功消息且无 product-errors。
  IPA/归档已保存 NAS 并逐文件核对。见 [包预检 2](Server/releases/v1.4.0-build4-package-preflight2.md)。
  旧 `32d7a9f` 归档仅保留为历史候选，不能再用来代替最新源码。此次没有上传或关联构建。
- **独立后台相册固定链接已修正，原生全流程复验通过**：审核站默认空 permalink 设置
  返回根路径链接，被 App 既有 `/portfolio/` 来源规则拒绝。仅修正独立站的该选项，
  不放宽 App 校验、不开放网页相册。真实目录内容摘要保持一致；注册/审批/HS 密码重新登录/绑定管理员/
  照片-only 完整清单/撤销/主动删号在 iPhone 17 Pro Max 原生服务集成复验 1 通过、0 失败、0 跳过。
  临时账号、维护访问码、自有模拟器已清理。见 [preview27](Server/releases/v1.4.0-build4-review-env-preview27.md)。
  此结果不替代最终 Test1/Test2 完整 UI 或 Apple/APNs/SMTP 验收。
- **照片-only 管理协议已部署到独立审核实例**：真实审核配置为 2 本完整相册（5/3 张）、
  无视频。App 不再对明确 administrator 范围要求视频存在；明确 viewer 不可编辑，仍检查会话与相册完整性。
  Swift 单元 249 通过/1 跳过，独立 WordPress/MySQL 395 项断言通过，包含同 token 撤销后的范围降级。
  源码验证见 [preview25](Server/releases/v1.4.0-build4-review-env-preview25.md)，实际隔离部署见
  [preview26](Server/releases/v1.4.0-build4-review-env-preview26.md)。演示插件现为 1.5.13.10，
  精确清单及真实 PHP/API 健康检查通过；生产仍是 1.5.13.7，最终账号完整编辑 UI 仍待验收。
- **Release 候选已加入显式环境入口，但还不能交付审核**：登录页、设置页可手动选择独立环境，
  确认后退出旧会话，演示根界面及全屏页面显示持续标识。iPhone 门禁/取消/切换/重启/标识回归通过。
  详见 [preview24](Server/releases/v1.4.0-build4-review-env-preview24.md)。Apple/APNs/邮件与最终
  账号完整 UI 仍待验收；旧 `32d7a9f` Build 4 IPA 不包含此入口，不能作为当前源码发行包。
  本候选 iPhone 250 通过/1 跳过，另 2 项布局通过；iPad 4 用例/10 次配置执行全部通过，
  Release analyze/build 与本机仓库检查通过。云端 #135 仍在运行且使用旧源码，不能视作本候选全量通过。
- **最终展示名称已确认，独立审核账号已准备**：用户确认 Test1/Test2 只是展示名称，实际用 HS 登录。
  已通过正常注册、审批与绑定流程建立两组演示账号；Test1 普通、Test2 App 管理员，
  实际 HS/密码登录、相册读取及管理权限边界均通过。临时会话/维护访问码已清理，
  最终凭据只留服务器 root:root 0600 私有记录。详见
  [preview23](Server/releases/v1.4.0-build4-review-env-preview23.md)。尚未交给 Apple，
  当前 TestFlight 没有演示入口，不能直接使用这两组独立账号；原生产普通审核账号未改动。
- **Build 4 实际发行包已准备并通过 Apple 上传前校验**：以干净 `32d7a9f` 归档并导出
  `1.4.0 (4)`，实际签名/profile、生产 APNs、Apple 登录、WeatherKit、包内照片/密钥/测试内容
  检查通过，`altool --validate-app` 退出 0。IPA 及归档已复制到用户 NAS 并核对一致。
  详见 [实际包预检](Server/releases/v1.4.0-build4-package-preflight1.md)。
  未上传 TestFlight，未过期旧包；ASC 正式构建仍未关联，支持 URL、审核说明仍缺。
- **原生账号服务已连接独立后台验收**：`FanAccountStore` 与 `AdminSessionStore` 通过实际 HTTPS
  完成合成用户注册待审、正式审批、管理员绑定、旧管理会话撤销后立即拒绝、主动删号和删后登录拒绝。
  最终测试包括抖音留空拒绝、删后错误必须为凭据无效；iPhone 17 Pro Max / iOS 26.5 的 1 项
  集成用例通过，0 失败、0 跳过。两轮临时用户和一次性管理访问码均经独立回读确认清理，
  未使用生产用户。详见 [preview22](Server/releases/v1.4.0-build4-review-env-preview22.md)。
  这是原生服务集成，不是完整 UI 操作、最终审核账号或 Apple/邮件/APNs 验收；演示入口仍未启用。
- **真实公网图片连续性专项**：新增 iPad 同一 App 进程横屏→竖屏检查，不用重启隐藏状态问题。
  iPad Pro 13-inch / iOS 26.5 两项真实网络用例共 48 次正反翻图均通过，0 失败、0 跳过，
  包含横屏实际照片边界在窗口内的断言；证据为
  `/tmp/yishu-review-environment.5a0FSm/preview21-ipad-live-media.xcresult`。
  同一最终测试代码在 iPhone 17 Pro Max / iOS 26.5 的 1 项用例、16 次正反翻图也通过，
  0 失败、0 跳过，结果为同目录 `preview21-phone-live-media.xcresult`。
  该专项暂停自动轮播、使用 DEBUG 访问与截图保护测试开关，不替代真实登录、保护机制或弱网验收。
  生产页面未改动，详细范围见 [preview21](Server/releases/v1.4.0-build4-review-env-preview21.md)。
  云端 #135 的全部前置阶段现已通过，iPhone 全量测试正在运行，仍未取得完整通过结果。
- **最新复验与云端启动**：原代码在全新 iPad Pro 13-inch / iOS 26.5 专项复验的两项
  用例、八次横竖屏/明暗执行全部通过，无失败或跳过，命令退出 0。证据为
  `/tmp/yishu-review-environment.5a0FSm/preview19-ipad-interruption-recheck.xcresult`。
  这不证明原模拟器退出根因已解决，也不覆盖最终全量测试或真实公网媒体。
  07:12 使用 3808d11 / preview20 启动 [#135](https://github.com/Saruika/shuzi/actions/runs/34066201816)，
  已回读 In progress，非完成证明；运行前预算核对 USD 9.90 / USD 20、Stop usage Yes。
- **#134 前置修正已验证，但又在 PHP 夹具失败**：011d690 / preview19 的运行器来源、
  指纹契约、静态分析、SBOM、Python/Composer 依赖审计全部通过。仓库检查随后在
  “私有密钥文件加载”测试失败，iPhone/iPad/Release 未执行。已在独立 Linux 临时目录
  用软链接 TMPDIR 复现旧夹具失败；[preview20](Server/releases/v1.4.0-build4-review-env-preview20.md)
  仅规范化正向夹具目录，保留生产拒绝软链接的行为，并新增软链接祖先拒绝断言。
  修正后普通/软链接 TMPDIR 的 543 项断言均通过，其余 PHP 门禁在软链接 TMPDIR 下通过。
- **最新云端 #133 已终态失败**：2026-09-07 06:51 使用 a6d9a0d / preview18 启动，
  工具链安装及来源采集成功，依赖策略验证成功，但当前工作流的指纹仍由契约引用
  Build 2 preflight13 旧记录，导致后续静态分析、iPhone/iPad/Release 全部跳过。
  这不是 GitHub 无法启动，也不是 App 页面测试已通过。候选
  [preview19](Server/releases/v1.4.0-build4-review-env-preview19.md) 保留旧记录，更新当前材料
  引用并添加明确的文件指纹错误信息；本地实际 Python 3.13.15 的完整供应链契约和 Ruff 已通过。
  06:50 账单核对为已用 USD 9.70 / USD 20、Stop usage Yes；该值是 #133 前快照。
- **审核资料**：隐私网址已写入 ASC 并回读。用户确认的审核联系人与普通审核账号登录凭据
  已写入审核专用字段并回读；不在 Git 中记录密码、身份码、私人联系方式或会话信息。
  普通审核账号经公开 HTTPS 注册、审批后登录确认有效，当前免费内容接口返回 10 组相册，
  普通账号访问管理员接口为 403；这不等于最终候选 App 的交互登录已验收。
- **管理员审核账号**：用户已明确批准独立演示后台与显式环境入口。实现位于独立的
  `codex/review-environment` 分支。独立后台现已部署，`review.shuzijun.com.cn` 的 HTTPS、
  证书续期演练、8 张演示照片/2 组相册和正常注册/审批/管理员绑定/撤销/删号接口已验证。
  Release 候选已加入环境入口，但尚未上传；Test1/Test2 已准备但尚未交付，不向审核账号授予生产数据管理权。
  后台外部邮件、Apple 和 APNs 仍主动阻断，不能将媒体/API 验收等同于完整审核环境已就绪。
  具体结果见 [审核实例记录](Server/operations/review/README.md)。
- **preview14 专项已完成，完整矩阵未完成**：`6d03fb4` 的 iPad 245 单元 + 8 次相册 UI 配置执行、
  iPhone 245 单元 + 1 项基础相册 UI 均通过；Release analyze 通过。
  修正的是完整照片中重试按钮的辅助功能命中顺序，未改页面视觉或播放器。
  9 月 7 日 04:58（UTC+8）另启全量 iPhone 测试，使用同一新建模拟器先验证首次通知授权，
  再运行完整用例。该轮已终态失败（退出 65）：309 个唯一用例中 304 通过、1 失败、4 跳过；
  参数化执行为 349 通过、4 失败、10 跳过，不能与唯一用例相加。245 单元全部通过。
  唯一失败为关于页画布边界用例的四种配置：图片失败后，旧辅助功能标识实际指向中央重试按钮，
  而非整个图片画布。跳过项是三个 iPad 专项及未启用的真实公网图片专项。
  原始编译版本为 `6d03fb4`，不包含之后的修正，保留失败原件，不将本轮改记为通过。
  证据：本机 `/tmp/yishu-review-environment.5a0FSm/full-preview14-phone.log` 与同名前缀结果包。
- **自动合作通知尚未交付**：本轮对主节点只读检查确认合作邮件就绪、收件地址和独立数据密钥配置
  均未配置；未发现 `phpmailer_init`、`pre_wp_mail` 钩子或所检查的两类常见 SMTP 插件选项。
  这不证明系统完全没有邮件能力，但目前没有已验证的认证发信通道；代码发布开关仍关闭，
  管理员自动消息也未接通。没有发送真实邀约邮件、打印配置值或擅自启用生产功能。
  后续候选 [preview17](Server/releases/v1.4.0-build4-review-env-preview17.md) 修正邮件任务和删号并发：
  113 项替身断言、132 项带真实双 MySQL 连接账号锁的断言通过；未部署，不代表自动邮件已经可用。
- **云端失败已再次核实**：GitHub 完整运行 #132（34016872419）为终态失败，Python/PHP 工具链、
  来源记录、SAST/SCA、SBOM 和仓库检查通过，失败发生在 iPhone 页面测试；后续 iPad 与 Release 分析跳过。
  因此不能将该次失败解释为全部都是 GitHub 账单或基础设施问题，也不能以已跳过阶段作为通过证据。
  后续 [preview15](Server/releases/v1.4.0-build4-review-env-preview15.md)（`2dff22c`）已推送 GitHub：
  前置检查通过后独立采集 iPad/Release，新增可读摘要；10 项本地测试及真实历史结果包解析通过，
  未启动新的付费云端运行，尚无新版本云端通过证明。
- **preview16 候选专项**：普通管理员查询/审批/权限变更原先共用上传的 120/180 秒传输设置。
  已分离普通 JSON 请求（30/45 秒）和媒体上传（120/180 秒），切换环境时同时取消两个旧传输。
  新增超时不自动重试权限写入、不误报成功及无磁盘缓存检查。
  关于页测试改测现有 DEBUG 画布标识，并分别强制验证内存图片成功解码和失败占位两种状态，
  没有修改生产页面布局、照片或播放器。iPhone 17 Pro Max / iOS 26.5 的 247 单元 + 10 次 UI 执行
  已通过；正常分支确认对象为 Image，失败分支确认对象为重试 Button，均保留角色文字边界断言。
  iPad Pro 13-inch / iOS 26.5 的 247 单元 + 14 次 UI 执行也已通过，包含横竖屏左图固定、右栏滚动。
  仓库检查通过（7 项 Linux 专用测试跳过，本机 PHP/Composer 条件分支未执行）。
  Release analyze/build 与发行包检查通过；没有照片原图、私钥文件或所检查的 DEBUG 测试标记。
  变更记录见 [preview16](Server/releases/v1.4.0-build4-review-env-preview16.md)。
  专项结果不能替代最终全量矩阵，未上传 TestFlight。
- **最新 iPad 全量矩阵已终态失败**：`24905f2` / preview16 在新建 iPad Pro 13-inch 模拟器通过首次
  系统通知授权，随后在同一设备执行完整矩阵。247 单元通过；最终 312 个唯一用例中
  309 通过、2 失败、1 跳过；参数化执行为 363 通过、3 失败、1 跳过，退出 65。
  06:29–06:30 期间设备变为 shutdown，runner 被 signal term 结束，Xcode 自动恢复后有两次
  主题配置在 setup 获取活跃应用时出现 AX -25218。最终失败用例为完整 iPad 首页构图
  `testHomeHeroKeepsTheFullIPadCompositionAndNeverTurnsBlank` 和
  `testHomeIndigoAndIvoryMatchThePage`。关闭原因仍未证实，不归因布局或直接当作可忽略。
  已保存原始失败结果；同代码、同硬件/系统的新建模拟器专项复验八次执行已通过，见本段顶部。
  preview17–19 不改变该轮 Swift 产物；专项复验不能将这轮完整失败改记为通过。
- **发行签名已单独核对**：历史实际导出包 `1.4.0 (3)` 的生产 APNs、Apple 登录、WeatherKit 与签名
  检查通过，不代表 Build 4 已导出。新增 [preview18](Server/releases/v1.4.0-build4-review-env-preview18.md)
  校验命令并用预期 Build 4 拒绝同一旧包；未接管上传工具，不把包校验成功当作上架就绪。
- **完整本地矩阵 6760788 已结束**：iPhone 17 Pro Max / iOS 26.5 唯一用例 266 通过、4 跳过、
  0 失败；iPad Pro 13-inch (M5) / iOS 26.5 唯一用例 261 通过、1 跳过、8 失败。
  iPad 参数化执行合计 309 通过、1 跳过、11 失败。两台新建模拟器的首次系统通知授权测试各 1 项通过。
  不再把该矩阵标为运行中或通过。后续已针对全部 8 个失败用例及新增故障用例复验，iPad
  12 次配置执行通过；iPhone 210 单元 + 4 UI 通过，Release 分析通过。关于边界两项证实是
  错把重试按钮当作图片测量，其余交互/可读性修复见 [preview4](Server/releases/v1.4.0-build4-preview4.md)。
  这些专项不能替代合并所有未完成功能后的最终完整矩阵和真机验收。
- **存储已验证**：两个完整结果与首次授权结果均归档至用户 NAS 专用构建目录；逐文件大小与
  SHA-256 验证，iPhone 862 个文件、iPad 2484 个文件全部匹配。保留本地原件，未声称腾出空间，
  未移动活跃构建缓存、未修改 SMB 权限、未接触 Time Machine 数据。
- **仍待完成**：支持 URL、最终截图/构建关联/审核说明、独立管理员演示端到端验收、Apple 登录与
  删号最终包验收、合作自动邮件与通知链路、ICP备案及权利/隐私申报事实核对。
  GitHub 完整云端矩阵尚未证明通过，仍遵守每月 USD 20 上限；当前运行见本段顶部，未并行追加付费运行。

## 当前状态快照：2026-09-06（全屏背景候选更新，UTC+8）

此快照优先于下方保留的历史审计。最新 TestFlight 为 **1.4.0 (3)**，Apple 确认
`VALID` / `IN_BETA_TESTING`；用户否定的画廊样式已撤回，恢复 1.3 经典大图。
发行及专项证据见 [Build 3](Server/releases/v1.4.0-build3.md)。正式上架目标仍未完成。

- **管理员绑定服务端已部署**：两节点 1.5.13.7，发布清单及健康检查一致，旧代码恢复单元保留。
  生产绑定路由未登录拦截通过。用户随后明确指定的一个已审批账号已通过受控维护通道绑定，
  原处理流程返回 200，独立回读确认角色、三项 App 管理能力和审计版本 1；未授予网站超级管理员。
  不在公开仓库记录真实身份码、昵称或用户 UUID；真实 App 管理链路仍待验收。
  合作自动邮件继续硬关闭。详见 [部署记录](Server/releases/v1.4.0-build3-preflight3.md)。
- **用户更新本轮目标**：优先管理员绑定、主流 iPhone/iPad 连续体验及上下黑边遮挡，保留免费、
  抖音 ID、审批和现有页面内容。全屏背景与原生栏位修复已进入 Build 4 候选，代码示例和设备专项见
  [候选报告](Server/releases/v1.4.0-build4-preview1.md)；未上传新包。下列商店资料保留为历史待办，不代表本轮已提交。

- **ASC 草稿实际已写入并回读一致**：正式版本 `1.0 → 1.4.0`；名称 `Hi 梳子 → Hi，梳子`；
  副标题、简体中文描述与关键词已填，精确文案保存在 [商店文案](Server/app-store/zh-Hans.json)。
  写入前后均核对 `PREPARE_FOR_SUBMISSION`；没有提交审核、关联最终审核构建或修改法律问卷。
- **仍未填**：支持 URL、隐私 URL、截图、审核详情及审核构建关联。支持邮箱用途已向用户确认中；
  商务合作 `369476120@qq.com`、隐私请求 `sariki@me.com` 分工不变，不擅自扩大邮箱用途。
  备案申请、版权/身份事实和真实 Apple 登录验收仍待完成。
- **GitHub**：Build 3 的轻量同步回归 [#25](https://github.com/Saruika/shuzi/actions/runs/34035295987)
  已成功。完整 iOS [#132](https://github.com/Saruika/shuzi/actions/runs/34016872419) 已终态失败，
  不是仍在等待：环境安装、SAST、SCA、SBOM 与源码检查均通过，失败发生在 iPhone 测试，
  后续 iPad 与发行分析被跳过。额度和 Python ARM64 的“测试前失败”已单独修正，
  不等于完整矩阵已通过；本轮未启动额外付费 macOS Actions。
- **当前完整本地回归**：Build 3 完整运行已终态失败，历史与修复见 Build 4 preview1 记录。
  全屏修复基线 `9618d9c` 的完整 iPhone 回归（`/tmp/yishu-build4-full-phone.xcresult`）
  已终态失败：209 单元通过，UI 99 次通过、10 次跳过、1 次天气文字对比度失败；退出 65。
  单独复测复现同一失败；胶囊局部底色修正后三项专项通过，但完整候选仍需再次验收。
  独立管理员身份校验补丁的 210 单元已通过；不把前一个基线的完整运行冒充该增量已全量验证。
  首次通知授权仍需干净设备单独验证。
  不因 TestFlight 可下载、专项通过或重复执行就宣称全部功能无问题。

以下是历史审计及仍需逐项核对的要求，旧版本号、“未写入”等原始观察不能覆盖上述最新回读。

---

检查更新：2026-09-06。最新内部测试版为 **`1.4.0 (1)`**，于 01:27 上传成功；Apple 返回 `VALID`、内部 `IN_BETA_TESTING`。本次保留旧 `1.3.41 (53)`，43 个历史构建仍已过期，没有新增过期操作。1.4.0 修正首页主题、iPad 相册返回跳动、轮播与标题对比度，继续包含此前的海报同步、共享管理员预览、相册手势及 Apple 授权生命周期与粗略位置修正；生产 Apple 密钥配置已另行恢复并验证，但没有完成商店元数据、正式审核或真实 Apple 登录端到端验收。最初就绪审计源码基线为 `1e95af2`。服务端消息箱 `1.5.13` 已部署两节点，真实 HTTPS 的零设备接收、账号隔离和已读验收通过。本文件是上线决策清单，**不是“已合规”、审核通过或可以直接提交的证明**。

**`1.4.0 (1)` 已进行两端全套及专项体验回归；用户了解小屏自动文字裁切审计未通过、暂无真机条件后，批准先发 TestFlight。** 修正、失败复验和发布证据见 [QA_1.4.0.md](QA_1.4.0.md) 与 [发布记录](Server/releases/v1.4.0-build1.md)。2026-09-06 已通过 GitHub 官方注释和账单确认云端未启动的原因：当月免费分钟数耗尽、超额预算为零且停止使用。用户批准有限预算后，轻量 Linux 回归实际通过；完整 iOS 云端矩阵仍待验收，不能据此标记全部通过。Build 53 继续保留供内部测试。

## 本轮目标与外部待办（2026-09-06）

- 用户确认 **App 备案申请中**，未取得最终号码；不得使用网站备案号代替。继续准备大陆及其他地区首发资料，备案仍为待补事实。
- 本轮做到具备提交条件，不自动提交审核。免费、抖音 ID 必填、管理员审批、现有页面/播放器边界不变。
- 用户决定不将小屏专项作为本轮发布阻塞；保留既有失败证据，重点验收主流 iPhone 和 iPad。
- 巡检已迁至独立“乖乖网站每日巡检”任务，本 App 任务不重复改动巡检配置。
- Actions 每月预算按用户最新授权提高为 USD 20，达到上限停止使用及预算邮件提醒均保留；保存后账单显示已用 USD 4.84。恢复运行后发现独立的 Python ARM64 安装包缺失，已修正精确版本及依赖锁，见 [CI 工具链记录](Server/releases/v1.4.0-build2-preflight2.md)。旧云端运行的通知权限隔离、消息详情返回已修正；当前候选 `c89692e` 的完整云端运行 [#132](https://github.com/Saruika/shuzi/actions/runs/34016872419) 已手动启动，结果尚未确认。
- 合作自动邮件/管理员提醒尚未投入生产。候选 1.5.13.4 已将认证加密接入真实保存、管理员读取与邮件队列，隔离 WordPress 回归 168 项通过，见 [加密存储接入记录](Server/releases/v1.4.0-build2-preflight10.md)。邮件为模拟传输，不是实际送达；日志/保留、发信通道、管理员通知及端到端门槛仍必须完成。

### 2026-09-06 本地完整回归与专项复验

- 相同已授权新模拟器上的 iPhone 完整回归：188 项单元测试通过；UI 共 104 次配置运行，其中 87 通过、7 失败、10 跳过。失败涉及混合比例轮播 3 次、手动翻页、触摸暂停、浅色主题搜索焦点、注册同意状态。该完整结果为失败，不能用此前单项通过代替。
- 保持 App 源码不变，以上用例独立串行复验共 8 次运行全部通过（混合比例用例有四种配置）。失败具有间歇性，尚未证明根因或完成修复；不能删除失败用例或降低断言。
- 触摸观察器移除对照仍有 1/4 失败，已完整撤销该临时诊断改动，保留按住暂停功能。主机实测为 16 GB 内存、约 16.6 GB 已用交换空间；已关机两台闲置 QA 模拟器，未删除其数据。资源压力是待验证因素，不是已证实的唯一原因。
- iPad 单设备完整回归已终态通过：188 项单元测试 + 103 次 UI 配置运行通过，0 失败，1 项真实公网图片测试未启用而跳过；首次通知授权另行通过。覆盖的是轮播计时修正前的 App 源码，不能代替最新候选验收。云端 #132 仍待结果。
- 最新 `895f9a9` 将触摸计时失效同步到状态变化；新增 XCTest 已在 iPhone 17 Pro Max 模拟器通过，单元测试共 189 项通过，完整 UI 仍在运行。完整依据及跳过边界见 [preflight12 验证记录](Server/releases/v1.4.0-build2-preflight12.md)。本轮没有上传 TestFlight、过期构建、部署服务器或提交 App Store 审核。

该次就绪审计检查本地源码、已有导出包元数据、Apple 官方资料，并于 **2026-09-05 11:58（UTC+8）** 对 App `6806714461` 执行 ASC 只读 GET 核验。审计本身没有提交审核或修改 ASC；其后消息箱的独立实现、服务器部署与客户端测试记录见 Build 47 发布说明。密码、私钥、JWT、审核账号口令不写入本文件；审核登录信息只记录存在性布尔值。

## 已核实的 ASC 直接缺项

2026-09-06 10:48（UTC+8）再次通过只读 ASC 核验：下表缺项仍存在。用户已确认首发包含中国大陆和其他地区、全部免费、保留抖音 ID 必填及人工审批。商店描述和 URL 尚未写入；App 备案申请中，审核联系人及已审批审核账号仍待补齐。不得把本次确认或本地修复当成已提交审核。

### Apple 登录服务端配置：已恢复，真机登录待验收

**2026-09-05 后续恢复结果**：用户明确批准恢复找到的原始密钥。上海 authority 与新加坡 standby 均已备份 `wp-config.php`，原字节保留的签名私钥/数据密钥放在 Web 根目录之外，密钥为 PHP worker 所有且 `0400`，配置 include 为 root:www-data `0640`。未生成、轮换或撤销 Apple 密钥，未改变角色标记或用户账号。两节点实际 `fpm-fcgi` 进程已验证 JWT 库、签名生成和数据密钥加载正常；临时非公开探针已移除。官网 HTTP 200，主节点与备用转发账号接口未登录均为 `401 fan_session_required`。以下记录为恢复前的诊断历史，不再表示配置仍缺失；仍不能代替真实 Apple ID 授权、授权码交换和删号端到端验收。

2026-09-05 16:00 左右，对上海实际 WordPress 运行环境执行只读检查：JWT 库可加载，Bundle ID 匹配，测试模式关闭；但 `YISHU_APPLE_TEAM_ID`、`YISHU_APPLE_KEY_ID`、`YISHU_APPLE_PRIVATE_KEY_PATH`、`YISHU_APPLE_DATA_KEY_PATH` 均未定义。客户端签名/描述文件包含 Apple 登录能力不等于服务端配置就绪。签名与数据密钥检查返回 `fan_apple_configuration_unavailable`。FPM 的 `auto_prepend_file` 为空，已检查的 FPM 配置与 wp-config 中没有上述配置项。此轮未使用真实 Apple 授权码执行端到端登录。

需核对/配置已关联本 App 的 Sign in with Apple 私钥及稳定的数据密钥；不能用 App Store Connect 上传密钥替代，也不能覆盖可能存在的旧数据密钥。当前未生成或轮换密钥、未改账号、未部署服务器代码。客户端另修复了 inactive 阶段误取消授权、迟到回调误清理新请求，详见源修正版记录。已有身份码账号与 Apple 新账号不会仅凭抖音 ID 自动合并；若重复登记会要求使用原账号，这不是审批旁路。

[Apple：创建 Sign in with Apple 私钥](https://developer.apple.com/help/account/capabilities/create-a-sign-in-with-apple-private-key/)

后续只读核对：Apple Developer 中已存在关联本 App 的登录密钥，本机受限权限目录也找到原有 `.p8` 与原始数据密钥，因此没有直接新建/撤销密钥。随后用户批准恢复既有凭据，结果见本节开头。

下列接口均返回 HTTP 200；空数据来自实际成功响应，不是把 API 不可读误判为缺失。

| 检查项 | 实际读取结果 | 提交前处理 |
| --- | --- | --- |
| App 名称与正式版本 | 名称 `Hi 梳子`；Bundle ID `cn.com.shuzijun.yishu`；正式 iOS 版本只有 `1.0`，状态 `PREPARE_FOR_SUBMISSION` | 核对名称是否保留当前空格形式；最新内部测试包为 `1.4.0 (1)`，本地候选为 `1.4.0 (2)`，须统一正式版本与最终候选包 |
| 发布方式 | `AFTER_APPROVAL` | 审核通过后自动发布；提交前确认是否需要改为人工控制发布，不擅改 |
| 正式版关联构建 | `build.data = null` | 尚未选择正式版构建；TestFlight 存在构建不等于这项已经完成 |
| 正式版审核资料 | `appStoreReviewDetail.data = null`；`hasCredentials=false`、`hasNotes=false`、`hasContact=false` | 填写审核账号、进入/删除路径、说明和审核联系方式 |
| 简体中文商店文案 | 描述、关键词、支持 URL 均为空 | 补齐首发实际功能描述和可访问支持页面 |
| 截图 | 简体中文 `appScreenshotSets=[]`，已上传截图集数量为 0 | 上传真实对应最终 UI 的 iPhone/iPad 截图 |
| 公开隐私政策 | 简体中文 `privacyPolicyUrl` 为空 | 在 ASC 填写并验证正式隐私 URL；App 内已有链接不能替代此字段 |
| 年龄分级 | `ageRatingDeclaration` 记录存在；`ageRatingOverride=NONE`、`ageRatingOverrideV2=NONE` | 本次未断言最终分级或全部问卷答案已正确；不能将 `NONE` 误读为未填问卷 |
| 内容版权声明 | `DOES_NOT_USE_THIRD_PARTY_CONTENT` | 核对摄影作品、肖像及平台内容的实际权利归属；“获得授权”不必然等于“没有第三方内容”，由权利人确认事实 |

副标题、营销 URL、隐私选择 URL 也为空，但本表不把所有可选字段都列作必填阻塞。隐私营养标签、目标地区、备案、协议、税务等未由本次接口核验，继续保留待核对状态。API 读取类别：`apps`、`appStoreVersions`、`appStoreReviewDetail`、`appStoreVersionLocalizations`、`appScreenshotSets`、`appInfos`、`ageRatingDeclaration`、`appInfoLocalizations`；没有调用写接口。

## 提交前的阻塞项与决策

### 1. 截图兼容层：必须作正式版风险决策

- **当前代码已验证**：`ArtworkImage.swift:1179` 遍历安全文本框的内部层级，`:1195` 选择名称含 `canvas` 的视图；`:1379` 设置 `isSecureTextEntry`，`:1480` 将页面放入该容器。探测失败会显示隐私遮罩（`:1495`），不是保证正文仍然可用的降级。
- **正式版风险**：Apple DTS 明确表示，安全文本框承载任意 UI 防截图不是该 API 的预期用途，也不是有文档保证的能力；系统更新可能改变行为。DTS 不预判具体审核结果，因此不能将此表述为“必拒”，更不能承诺必过或永久防截图。[Apple DTS 官方说明](https://developer.apple.com/forums/thread/824922)
- **关闭条件**：产品负责人确认正式版采用哪种保护范围及风险；重新执行支持系统的真机截屏、录屏、切后台、图片浏览和 iPad 窗口切换验收。不得为了审核临时隐藏真实功能，审核通过后再偷偷恢复。当前没有擅自移除用户要求的保护层。

代码：[ArtworkImage.swift](Yishu/Components/ArtworkImage.swift)。

### 2. 审核入口：必须能进入真正的完整功能

- **当前代码已验证**：`RootView.swift:93` 在审批通过前只显示访问门禁；`:334` 要求已批准账号。`FanAccountStore.swift:166` 还要求必填抖音 ID、有效会话和一致的账号设置状态。Release 的测试旁路固定为 `false`（`RootView.swift:346`）。
- **ASC 已核对缺失**：正式版本目前没有审核详情记录，`hasCredentials=false`。需要提供稳定、已预审批、可查看完整相册和影视的普通粉丝测试账号，以及登录、账号删除、管理员功能的准确说明。不要提供最高权限生产管理员账号，也不要让审核人员等待人工审批或借用真实粉丝身份。
- **产品说明待确认**：强制填写抖音 ID、人工审批、全内容登录门禁需要解释其与受限粉丝会员服务核心功能的关系。不能只凭“已经写进隐私政策”认定该必要性已被 Apple 接受；也不应未经产品同意取消必填项。Apple 对无显著账号功能的应用、非必要个人信息和社交服务依赖有明确限制。[审核指南 2.1、5.1.1(v)](https://developer.apple.com/app-store/review/guidelines/)

代码：[RootView.swift](Yishu/Views/RootView.swift)、[FanAccountStore.swift](Yishu/Services/FanAccountStore.swift)。

### 3. 合作邀约：当前不满足“自动邮件 + 管理员必收消息”的产品要求

- **当前代码已验证**：服务端 `COLLABORATION_PHASE1_RELEASE_FUSE = false`，新邀约提交、管理收件箱和发件队列不启用。`CollaborationInquiryView.swift:252` 使用用户主动发送邮件的回退流程，不等于服务器自动投递或管理员已收到通知。
- **产品阻塞而非自动拒审结论**：若首发必须实现自动邮件及管理员消息，该功能仍未交付；需要按已有 Phase 1 门槛完成实现和真实送达/失败/删号验收。若允许首发仅提供手动邮件合作入口，须由产品确认，并让商店描述、截图和审核说明保持一致。
- **当前邮箱已核对**：合作邮箱 `369476120@qq.com`；隐私/资料请求邮箱 `sariki@me.com`，两者职责不得互换。

证据：[服务端主类](Server/vendor/shuzijun/app-content/class-shuzijun-app-content-api.php)、[合作页面](Yishu/Views/CollaborationInquiryView.swift)、[邮箱常量](Yishu/Models/Portfolio.swift)、[Phase 1 门槛](Server/COLLABORATION_PHASE1.md)。

### 4. 首发收费决策：已确认全部免费

- **当前代码已验证**：App 内订阅代码已移除；当前权限来自管理员审批及分配，不是有效 StoreKit 订阅。以前的“人民币 3 元/月”仅保留为未来恢复方案。
- **2026-09-05 产品确认**：首发全部免费，保留审批；商店文案不得宣传月订阅或付费解锁。未来如改变收费方案，必须另行评估并完成 StoreKit 等要求，不能直接用人工授权替代内购。[Apple App 内购买](https://developer.apple.com/in-app-purchase/)

证据：[SUBSCRIPTION_SETUP.md](SUBSCRIPTION_SETUP.md)、[README.md](README.md)。

## 高优先级：代码与披露一致性

### 定位精度承诺需要收紧或改准确

**已随 Build 49 进入 TestFlight**：默认请求降低精度；进入反向地理编码与 WeatherKit 前按固定 0.05° 网格降低经纬度精度，丢弃高度、速度与方向。新位置测试覆盖邻近点、世界边界、无效输入与重复处理；本轮共 166 项单元测试通过（含 Apple 登录回归）。以下是修正前的审计依据，不能再当成当前源码状态；真机城市与天气展示仍需验收。

**当前代码已验证**：`LocalWeatherStore.swift:50` 设置约 3 公里期望精度，但 `:170`、`:231` 将返回的原始 `CLLocation` 交给反向地理编码和 WeatherKit；`:326` 并不排除更高精度位置。`Info.plist` 和隐私政策则描述仅使用约 3 公里/粗略位置。

**风险推断**：期望精度不等于隐私精度上限。Apple 说明系统可能因其他应用已获取位置而提供比请求更精确的数据。应评估默认仅请求降低精度、在发送前真正降低坐标精度，或将用途说明改为准确描述；不要在缺少传输及保留事实时直接断言必须申报“精确位置”。[Apple WWDC：位置精度](https://developer.apple.com/videos/play/wwdc2020/10660/)、[位置精度最佳实践](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)

证据：[LocalWeatherStore.swift](Yishu/Services/LocalWeatherStore.swift)、[Info.plist](Yishu/Info.plist)、[隐私政策](Yishu/Views/PrivacyPolicyView.swift)。

### 隐私清单不等于 ASC 隐私问卷已经完成

- **当前代码已验证**：`PrivacyInfo.xcprivacy` 声明昵称、用户 ID、设备 ID、管理员媒体、粗略位置、诊断及其他数据；未启用广告跟踪，UserDefaults 理由为 `CA92.1`。App 内注册、Apple 登录和账号页均有隐私及删除说明。
- **Build 47 增量**：新增只接收的云端消息箱披露：正文、收件关系与已读时间最长保留 30 天，不提供粉丝互发或回复；退出/换号清除内存消息，不将正文持久存入本机。隐私清单新增 `NSPrivacyCollectedDataTypeEmailsOrTextMessages` 和 `NSPrivacyCollectedDataTypeProductInteraction`（已读状态），均为关联身份、App 功能用途、不跟踪。见 [PrivacyInfo.xcprivacy](Yishu/Resources/PrivacyInfo.xcprivacy)、[App 内政策](Yishu/Views/PrivacyPolicyView.swift)、[网站政策源文件](Server/app-privacy-policy.html)。网站政策已同步两节点并从公网核对；服务器真实 HTTPS 的隔离与已读验证通过。清理与账号删除边界有隔离回归覆盖，但这仍不是 App Store 隐私标签或全部真实账号端到端删除已完成的证明。
- **ASC 已核对/待核对边界**：公开隐私 URL 字段已确认未填；隐私标签、关联身份、用途、保留/删除及管理员上传媒体仍须按实际数据流核对。Apple 的“收集”判断涉及离开设备后能否被开发者/合作方超出实时请求需要而访问；不要把仅本地处理自动等同服务器收集，也不要遗漏后端日志或管理员上传。
- **候选 Build 47 提交前**：ASC 隐私标签仍待填，尤其新增消息内容、已读交互数据与关联身份/功能用途，不得将修改本地清单误报为已更新 ASC。最终构建还须验证匿名/他人消息隔离、显式及幂等已读、换号清空、30 天清理、删号关联清理和推送通用提示不泄露正文。
- **若启用合作服务**：重新核对联系方式、联系人、项目描述等数据类别及邮箱副本保留，不能沿用目前硬关闭状态的回答。

官方：[App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)、[管理 App 隐私](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)、[Required Reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)。

### WeatherKit 标注：保留用户已明确选择，不改首页

**当前代码已验证**：关于页 `AboutView.swift:445` 已提供 Apple Weather 标识及数据来源/许可链接；`LocalWeatherStore.swift:239` 读取官方归属信息并保留官方链接回退。首页不显示归属入口，是产品方明确决定，不是本轮要擅自改变的布局。

**审核风险保留**：Apple 要求清晰显示 Apple Weather 商标与其他数据来源法律链接；仅位于关于页能否满足当前展示方式，不能由本项目自行宣布已获豁免。提交说明应如实标明入口，最终以 Apple 审核为准。[WeatherKit 归属要求](https://developer.apple.com/weatherkit/)

## 当前已有代码路径，但真实账号验收仍须单独留证

| 项目 | 已核实代码/已有证据 | 不能据此宣称完成的部分 |
| --- | --- | --- |
| App 内永久删号 | `FanAccountView.swift:175/196/434/805` 覆盖密码、Apple、未完成申请和账号页；`FanAccountStore.swift:1665/1727` 调用真正删除接口 | 密码账号与 Apple 账号在待审批、已审批、暂停等状态的生产端到端删除；删除后旧会话、通知绑定、个人数据不可再用 |
| Sign in with Apple | 原生授权、nonce/state、服务端验证与资料补全；不请求 Apple 姓名/邮箱（`AppleSignInService.swift:163`）；服务端包含刷新令牌撤销及有界失败重试 | 使用专用测试 Apple ID 实际走首次登录、重复登录、取消、重新授权删号、Apple 撤销事件；原生按钮可见不等于这一整条链已通过 |
| 密码登录与会话 | 本线程部署 `1.5.12.3` 后，短命无权限 QA 账号真实 canonical HTTPS 登录/重登/会话读取/退出通过，关联数据与 cron 残留核对为 0 | 这不是 Apple OAuth、真实 APNs、审批操作或永久删号的验收替代品 |
| 通知权限及开关 | 首次 active 请求系统授权；拒绝不阻止账号使用；账号页可关闭、重连或提示重新登录（`PushNotificationService.swift:288`，`FanAccountView.swift:674`） | 真机接收、换号不串号、拒绝/关闭/删号后不再投递；若以后发促销/直接营销，需对应的明确同意和退出机制，不能只靠系统授权弹窗 |
| iPhone / iPad 与系统兼容 | 仓库已有横竖屏、窗口化、辅助功能字号等回归用例 | 最后一次源代码变更后的最终 IPA 真机/模拟器验收；尤其截图兼容层、iPad 关闭大图、关于页文字和 IPv6-only 网络 |

官方依据：[App 内删除账号](https://developer.apple.com/support/offering-account-deletion-in-your-app/)、[通知 HIG](https://developer.apple.com/design/human-interface-guidelines/managing-notifications)、[审核指南 2.1、2.5.5、4.5.4](https://developer.apple.com/app-store/review/guidelines/)。

## ASC 关闭清单：按最终版本逐项完成

前两项已有明确缺项；后续未读取的项目不推断为缺失或已配置：

- [ ] 补齐正式版 `1.0` 目前为空的构建关联，并与最终版本号统一；不是仅有 TestFlight 构建即可。
- [ ] 补齐已确认为空的描述、关键词、支持 URL、隐私 URL、截图及审核详情；核对名称、分类、年龄分级和内容版权答案。
- [ ] 首发定价/订阅决定、地区范围及需要的协议、税务/收款信息；不存在当前并未交付的功能宣传。
- [ ] 目标包含中国大陆时，按 App 类型确认并提供 Apple 要求的 App ICP 备案/有关材料，备案名称及元数据一致；不能用网站可访问或网站已有备案代替 App 资料核验。不面向该地区时，不把这项泛化为全球上架阻塞。[Apple 中国大陆 App 信息要求](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- [ ] 若选择欧盟等有特定要求的地区，核对相应身份/交易者声明；由账号持有人确认事实，不代填未核实身份。
- [ ] 核实加密出口申报是否与仅使用 Apple 系统密码学/HTTPS 的实际实现一致，不把 plist 的 `ITSAppUsesNonExemptEncryption=false` 当成 Apple 已确认豁免。[Apple 加密出口说明](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)

官方元数据清单：[必填及可编辑属性](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties)。

## 非阻塞的已确认基础

- 已导出的 Build 46 元数据显示 `DTSDKName=iphoneos26.5`、`DTXcode=2660`，满足自 2026-04-28 起上传需使用 iOS/iPadOS 26 SDK 或更新版本的最低工具要求；这不代表业务功能或审核已通过。[Apple SDK 最低要求](https://developer.apple.com/news/?id=ueeok6yw)
- 项目声明 Apple 登录、WeatherKit、推送能力；最终分发签名应以导出 IPA 的 entitlement 为准，不能只看源码里用于开发的 `aps-environment=development`。
- 当前不需要为了显得“功能丰富”临时加入社区、用户评论、广告或第三方 SDK。首发优先关闭以上阻塞与真实链路验证，不擅自改现有页面内容。

## 首发商店资料草案（未写入 App Store Connect）

以下按当前可用功能准备，不包含尚未开启的服务器合作邀约、自动抓取第三方动态、互发消息或订阅。最终构建和功能范围确定后须再次对照；草案不是已填写或已提交的证明。

### 简体中文

- 名称建议：`Hi，梳子`，与用户指定名称一致；ASC 当前为 `Hi 梳子`，修改前核对名称可用性。
- 副标题：`易姝的影像作品与粉丝空间`
- 关键词：`摄影作品,古风写真,演员履历,影像相册,作品收藏,粉丝动态`

描述草案：

```text
Hi，梳子是易姝的影像作品与粉丝空间，在 iPhone 和 iPad 上浏览按拍摄主题整理的照片、观看影视作品，了解镜头背后的表达。

注册与访问
本 App 面向获批的粉丝用户。首次使用需注册或通过 Apple 登录，填写昵称和抖音 ID，并等待管理员审批；批准后，才可进入首页、作品、影视等内容。注册和使用免费，没有订阅或 App 内购买。

作品与影像
按相册浏览不同造型与拍摄主题，放大查看照片细节；通过收藏和最近浏览继续欣赏喜欢的作品。照片与内容通过网络加载，App 不提供照片保存或导出功能。

影视与关于
在 App 内观看 Showreel，查看影视履历、艺人介绍与合作联系方式。

消息与设置
在消息箱接收管理员发送的消息，不提供粉丝互发、回复或私聊。系统通知和当地天气均可由你选择是否开启；不允许通知或定位，不影响获批后的作品浏览。可在关于页的设置中选择喜欢的界面主题。

账号与隐私
可在 App 内管理登录设备，并主动发起删除账号与个人资料。待审批期间也可删除申请，无需等待批准后再提出删除请求。
```

描述保持纯文本；关键词按 UTF-8 字节计数，不含其他 App 的商标、不重复名称。限额核对依据：[Apple 平台版本信息](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)。

### URL 与联系人分工

| 字段 | 草案/既有地址 | 写入前的条件 |
| --- | --- | --- |
| 隐私政策 URL | `https://www.shuzijun.com.cn/app-privacy/` | 客户端既有地址；最终发布前再核对公开 HTTPS 内容、无需登录及实际数据流 |
| 营销 URL（可选） | `https://www.shuzijun.com.cn/` | 最终发布前核对公开可访问性及 App 介绍，不以营销页替代支持页 |
| 支持 URL | 尚未确认已上线的专用 App 支持页 | 应提供注册审批、账号删除、通知、加载问题等说明，以及可处理 App 问题的有效联系渠道；不填不存在的网址 |
| 商务合作收件人 | `369476120@qq.com` | 仅用于商务合作；不擅自改成隐私联系邮箱 |
| 隐私与资料请求收件人 | `sariki@me.com` | 用于个人信息查阅、更正、删除及隐私问题；不擅自扩展为通用客服承诺 |

公开页面在本轮网页读取中未成功返回正文，因此这里只记录源码使用的地址，不宣称本轮已通过公网检查。支持 URL 的实际联系方式要求见 [Apple 官方说明](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)。

### 审核说明草案与待填事实

- 说明这是免费、需注册和审批的粉丝作品 App。抖音 ID 是当前产品规定的申请字段，并不代表已完成抖音平台身份认证。仍需解释此字段与受限内容服务的必要关系，不将说明文本当作 Apple 已接受的证明。
- 提供一个独立、预先批准的普通粉丝审核账号，授予最终版本所需内容权限，不授予管理员能力；其身份码和口令只能通过 ASC 审核专用字段安全交付，不放入 Git、截图或日志。目前尚未核实这样的审核账号可用于最终包。
- 审核路径：使用专用审核账号登录 → 首页/作品/影视/收藏/关于；账号管理与删除位于粉丝账号页，待审批用户的申请状态页也有删除入口。删除测试需另用可销毁测试账号，不能删除仍供审核登录的唯一账号。
- 通知与定位均为可选权限。真实 Apple 登录、删除授权、APNs 和 WeatherKit 链路仍须分别验收；模拟器通过不能替代未进行的真机验证。
- 不声称服务器自动合作邮件或第三方作品/直播自动通知已上线；如果最终发布开启这些功能，先完成对应门槛并更新描述和隐私披露。
- 审核联系人真实姓名、电话、邮箱，版权所有人及授权归属，App 备案结果、隐私标签和地区合规事实仍需核实，不能由本草案代填。现有截屏兼容实现和 WeatherKit 署名位置的审核风险保持单独记录，不伪装为已获豁免。
- 截图应来自最终候选版的真实 iPhone/iPad 页面，覆盖注册审批提示、作品、影视及关于等关键状态；不以旧布局、包含他人资料的管理页或概念图替代。当前 ASC 截图集仍为空。
