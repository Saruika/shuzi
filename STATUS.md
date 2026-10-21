# 当前版本与验证状态

整理日期：2026-10-21（Asia/Hong_Kong）。基线为公开 `main` 的
`50124bb11e45f2e40fe2e792d28de218c6c3bf4d`（提交日期 2026-09-30）。
本文区分源码、历史发布回执与本次实际检查；历史状态不视为今天的线上事实。

## 版本与发行

| 项目 | 已有证据 | 日期与边界 |
| --- | --- | --- |
| 当前源码版本 | Xcode 工程 Debug／Release 均为 `1.5 (3)`，最低 iOS 17 | 本次读取工程配置；不表示重新归档或上传 |
| 已记录发行包 | `v1.5-build3`，源码 `65329cd8d54492fba565779a6279311671328198` | [2026-09-26 发布回执](Docs/V1.5-BUILD3-RELEASE.md)；不等同于当前 main |
| TestFlight | 回执记载 `VALID`、内部／外部 `IN_BETA_TESTING`、Beta Review `APPROVED` | 2026-09-26 的历史回读；本次未访问 Apple 后台确认当前可安装性 |
| 正式 App Store | 回执记载 2026-09-26 12:49:20（UTC+8）为 `WAITING_FOR_REVIEW`；本次中国大陆／香港公开查询均无结果 | [正式重提回执](Docs/V1.5-BUILD3-FORMAL-RESUBMISSION.md)；后台审核状态未核实，查询无结果不能证明被拒或全球未上架 |
| 服务端源码 | 插件版本 `1.5.13.18` | 本次读取 `Server/shuzijun-app-content.php` |
| 服务端部署 | 主、备与审核环境已部署无游戏版本的记录 | [2026-09-26 退役记录](Docs/V1.5-BUILD3-NO-GAME.md)；本次未重新部署或读取服务器文件 |

## 功能边界

- 公开体验：独立匿名 `public-experience` 接口，只列出管理员明确选择的预览派生图。
  [2026-09-22 回执](Server/releases/public-experience-candidate.md)记录三个相册各两张，
  共六张；本次匿名读取再次确认六张图，六个图片 HEAD 均为 200。
  不是“每个相册自动公开前三张”。
- 审批专区：账号资料、审批状态及安装绑定会话核验通过后，按 `gallery_full`、
  `video_view` 等权限返回对应内容。公开精选不会授予完整相册或视频权限。
- 游戏与排行榜：已从当前客户端／服务端源码移除；线上退役及旧包过期见上述回执。
- 合作流程：服务端 `COLLABORATION_PHASE1_RELEASE_FUSE = false`，不能把代码存在
  或表单可见当作后台收件、邮件投递已经可用。基础合作联系方式与此流程分开。
- 媒体保护：目录鉴权与媒体文件鉴权分开；已知静态 URL 不具备账号级撤回保证。
  本次一个已知非预览尺寸照片与 Showreel 主清单的匿名 HEAD 均返回 200。
  没有下载照片或读取视频分片；详见 [媒体访问核查](Docs/MEDIA_ACCESS_AUDIT.md)。
- 新后台：Payload／Next.js／PostgreSQL／COS-CDN 是
  [分阶段架构方案](ARCHITECTURE_V2.md)，本文不将其记为已完成迁移。

## 本次检查与未完成项

本次只修改文档并增加匿名只读核查工具，没有更改业务接口、媒体文件、数据库、
云端权限、Apple 资料或部署状态。具体测试和网络结果见媒体核查报告。
最新提交的 GitHub 状态查询没有取得足以证明完整 CI 成功的记录；不沿用旧绿灯。
未在本机执行 Xcode 构建、iPhone／iPad 或 TestFlight 真机验收。

公开商店查询（2026-10-21）：App ID `6806714461` 的
[中国大陆查询](https://itunes.apple.com/lookup?id=6806714461&country=cn) 与
[香港查询](https://itunes.apple.com/lookup?id=6806714461&country=hk) 均返回 `resultCount: 0`。
此结果只反映这两个公开查询，不能代替 App Store Connect 或其他发行地区的状态。

维护者已选择暂不授权代码、先准备软著登记；现有元数据保持 `proprietary`。
素材来源及授权范围有待补证明，详见 [许可边界](LICENSING.md) 和 [素材清单](ASSET_RIGHTS.md)。
登记资料草稿见 [软著登记准备](Docs/COPYRIGHT_REGISTRATION_PREPARATION.md)，尚未提交申请。

## 后续更新规则

发布时更新本文件的版本、源码 SHA、时间及回执链接。源码合入、服务器部署、
TestFlight 可测试和正式上架分别记录，不合并为一个“已发布”。未核实的状态写“未核实”。
README 及旧文档中较早的 Build、候选、等待审核等内容均按所标日期解释，
不能覆盖本文件中有更新证据的项目；无法确认时保留未知状态。
