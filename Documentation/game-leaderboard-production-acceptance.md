# 排行榜生产部署记录

日期：2026-09-18（Asia/Shanghai）。授权：部署排行榜服务、创建数据表并更新隐私说明；继续 Build 10 内部 TestFlight 发布。随后另行授权“提交外部审核”，Build 10 已加入现有外测组并进入外部测试。保留旧包及正式审核版本，未更改外测组成员或公开链接配置。

## 已完成的生产变更

- 先备节点、再主节点部署服务端 1.5.13.16；两端完整 37 文件清单均为 `3adaebe7acbdeeb189a703c865f991935cf90a778a8151eaf85f272e7d053576`。部署器预检、备份、原子替换、离线校验及服务恢复均退出 0。
- 在插件发布前，为 www/img 两个 Nginx server 增加服务器规则 JSON 的精确 404 location。原敏感路径规则、webroot 校验器和服务端权限检查未放宽。公网该 JSON 返回 404。
- 主节点单独调用实际 `ensure_game_leaderboard_storage()`，结果为 `installed_verified_zero_rows`。新增 InnoDB 表，7 列、主键及成绩/时间/用户联合索引，schema option 为 1、autoload=off；无测试成绩。
- 官网隐私页面 115 仅更新正文，保持标题、作者、状态及其他字段；原文先私有备份。公网 `/app-privacy/` 返回 200，并实际包含游戏自愿上榜、撤回记录及 support 隐私邮箱。合作邮箱仍为 369476120@qq.com。
- App Store Connect 的“游戏内容”披露已发布：App 功能、与账号关联、不用于追踪。页面回读共 13 个数据类型；本次只补游戏内容，不把本地候选中的其他待判定分类视为已发布。正式 1.4.0 仍在等待审核。
- 调用现有签名同步服务，22:12:23–22:13:53 执行成功。未改同步脚本、协议、定时器或 authority/standby 标记。两库正文 SHA、schema option=1/off 及排行榜零行一致；备库实际列和索引亦核对通过。两节点 Nginx、PHP-FPM、MySQL 均 active。

正文 SHA-256：`6ee96c3d7a35d2d19bd1a402900044c24be1208b56e0341cd62054d830ca4e29`。

## 恢复材料（仅服务器私有目录）

- 主数据库：`/var/backups/shuzijun-app-content/game-production-db-hoefqezj/wordpress.sql`；SHA-256 `4f36b83d2badfbf3760c9a92d3a72f6024a9414170823a3ccb277a0cfc029620`。不下载或公开内容；未执行数据库恢复。
- 插件原版：主节点 `20260918T135114Z-3adaebe7acbd-981914`、备节点 `20260918T135024Z-3adaebe7acbd-1994273`，位于 `/var/backups/shuzijun-app-content/`。
- Nginx 原版：主 `game-json-nginx-9biru6dg/shuzijun-ssl.conf`、备 `game-json-nginx-dvqs7k1l/shuzijun-ssl.conf`，同一私有备份根。
- 页面原文：`/var/backups/shuzijun-app-content/privacy-55f8364a72b3041c290e826bae455b68/receipt.json`。原正文 SHA 为 `3068a447056a3c4922ce13d2dd43ef8a0493c44c390d9a5ec11337f0594cd0d4`。

恢复需要重新核对实际状态；有真实新成绩后不得盲目回滚数据库。备份存在与摘要一致不等同于已验证可恢复。

## 运维隔离与证据边界

- 初始化使用一次性维护进程，不修改正式服务配置。以系统策略限制只访问 localhost，保留实际 Redis 缓存与 MySQL；核对有效隔离属性，本机 Redis TCP 可达，零载荷公网 UDP 探测实际得到 EPERM 后才进入 WordPress。原始输出只保存 root 私有日志。
- 最初预检因缺少 PHP_SELF、随后因独立网络命名空间无法访问本机 Redis 而停止，均未进入 DDL。补正常引导字段及 localhost-only 隔离后成功；没有禁用 Redis、关闭正式安全保护或放宽出网策略。
- 交叉审阅发现，最初版本的 WordPress 引导仍可执行既有 init 维护钩子；DISABLE_WP_CRON 不等于禁止这些同步维护。因此不声称最初引导绝无后台维护写入。已修正两个专用工具，在当前 CLI 进程精确隔离 8 类 App 维护钩子，不改在线插件。修正版在生产重新执行预检：数据表已安装、正文摘要仍一致；未重做 apply。实际 helper SHA：建表 `16b3b864f16f4d6b51679ee60cd28c26573f9de2c53e24a7c1fc727bc7497105`、隐私 `38c1216bd483190cf73e51cb23cf7c9956cddc8c869a8ae0d24e79e723dda9cd`。
- 没有显式创建生产测试用户、变更真实用户权限、发送测试消息或提交测试成绩。匿名生产排行榜返回 401；这不是已登录生产用户的完整上榜验收。真实账号/成绩联调证据来自独立审核环境，见独立验收记录，不混同为生产账号测试。
- 现有同步为周期性数据库快照，不是实时排行榜复制；本轮已补一次同步，不改变灾备 RPO。

## 本地回归

- 新增建表工具 172 项、隐私更新工具 191 项、Nginx 保护工具 13 项检查通过，均接入 `Scripts/security-check.sh`。这些是离线/合成数据库边界测试，不替代上面的真实部署回执。
- Nginx 工具进一步补上“原子替换成功但目录 fsync 失败”的恢复边界：仅精确匹配候选与备份才回滚；外部修改或回滚失败不覆盖、不掩盖。已成功的线上 Nginx 配置未因此重写。
- 一次性隔离执行器 8 项及 TestFlight 配置脚本 9 项合成边界测试通过。最终隔离执行器 SHA 为 `54f5951dc0780f0a49f55e1ce232c3e4c21c48db5950b829608cb495f1a671e4`，原始私有日志未进入 Git。
- Python Ruff 通过；Bandit 的项目中危及以上门禁通过。固定参数 subprocess 的两项低危提示已人工核对，未隐去提示或降低原门槛。
- 最终完整 `security-check.sh` 退出 0；7 项现有环境条件跳过保留，未触发 GitHub Actions。

## 安装包不变

App 与 Xcode 项目仍与归档源码 `d1480ce8b4f43ed649715e074832f4fe3ae78a38` 一致，本轮只增加运维工具、测试及记录。实际 IPA 没有 B站名称、域名、账号入口或 SDK；保留原作者版权署名及内部来源记录。上传/处理/内部可测试状态另见 `Server/releases/v1.4.0-build10.md`，不以此文档代替 Apple 回执。
