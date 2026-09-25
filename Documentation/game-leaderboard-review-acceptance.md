# 排行榜独立审核环境验收

> 2026-09-26 归档说明：以下保留 2026-09-17 独立审核环境的实际验收与恢复材料记录。对应游戏实现和专用测试工具已从当前候选退役；不应继续执行本文的历史建表或上榜步骤。当前变更及线上状态见 [Build 3 记录](../Docs/V1.5-BUILD3-NO-GAME.md)。

日期：2026-09-17。用户明确批准范围为独立审核环境部署、单独建表、临时账号联调及清理。
不包括生产部署、真实用户更改、GitHub 推送、App Store/TestFlight 发布或过期 Build 9。

## 已完成：审核环境升级

- 固定 SSH 主机公钥访问上海主节点上的独立 `/srv/shuzijun-review` 实例。
- 实际旧清单为 `5038c807d0e15a54b4acb20a7e9fe43ac23e90339708f0cb65561a8730c3acfe`（34 文件），不是旧记录中另一个过渡候选。
- 新清单为 `3adaebe7acbdeeb189a703c865f991935cf90a778a8151eaf85f272e7d053576`（37 文件），恰好 6 个替换、3 个新增；生产候选载荷未因本轮验收工具而改变。
- 独立升级器不修改历史升级器。精确根目录清单、完整备份、共享维护锁、停止服务确认、同文件系统原子 NOREPLACE 新增、原子替换、配置摘要/权限复验、未知变更拒绝及中断后保持停止均有本地合同。
- 本机 30 项升级合同通过；审核主机 Linux 临时目录的 28 项文件事务合同通过，实际执行 `renameat2`，但其中服务与 HTTP 是替身。
- 随后真正执行审核站只读预检与升级，均成功；实际 review PHP/web 服务恢复运行，loopback API 与正常证书校验的本机 HTTPS 匿名门禁通过。未对生产服务执行操作。
- 升级前后现有 3 个用户、69 条用户元数据的全量内容摘要一致；此时尚无排行榜表，未自动建表。

## 恢复材料

只保留在审核主机私有目录，不含于 Git 仓库或客户端：

- 数据库备份：`/etc/shuzijun-review/game-db-backup-tylotx3q/shuzijun_review.sql`，父目录 0700、文件 0600。
- 数据库备份 SHA-256：`de0e54324adf7b0f938a7b8cf525604e015e1cd219d742b2fa46ebbb9e8f79f8`。
- 完整插件与事务回执：`/etc/shuzijun-review/game-plugin-backup-f0eddd8d28d24293b6af6181aa136462`。
- 升级器 SHA-256：`6829d379f3b7aa213f56d636c7c07baee59341141ea25a01aaf888e6896a87c3`。

中断恢复只接受本次确切备份；恢复后仍保持 review 服务停止，须核实清单与配置后显式恢复。数据库备份未被恢复，不自动覆盖现有数据库。

## 数据库联调边界

审核数据库为 MySQL 8.0.46；初始 17 张表均为 InnoDB。数据库账号只能访问审核 schema，不能访问生产 schema。
review PHP 保持 `PrivateNetwork=yes`、`AF_UNIX`，生产目录和推送密钥目录不可访问；禁止外部 HTTP 与邮件的隔离插件保持原摘要。

预检发现 34 条既有 `push_install_states` 记录；它们不是本轮测试数据，不清空、不重建。其他 4 张投递表为空。
联调必须记录并验证其完整摘要，禁止测试身份/安装标识与既有设备状态相交。
删除钩子会清理无收件人的通知，因此测试窗口暂停仅 review web/PHP，并保持自动 cron 禁用，防止并发写入改变空投递表前提。

## 已完成：真实数据库联调与清理

| 实际检查 | 结果 |
| --- | --- |
| 隔离执行环境 | transient systemd service，review 用户、PrivateNetwork、AF_UNIX、NoNewPrivileges、只读系统、隐藏生产目录；只允许 review tmp 写入；原有 unit 配置不变 |
| 建表 | 单独 `install-schema` 成功；新增审核库排行榜 InnoDB 表与 schema option，未创建测试账号 |
| 真实路由与身份门禁 | WordPress 已注册 REST 路由、真实 Bearer/安装标识/审批/credential epoch 校验；匿名、待审批、停用、撤权按预期拒绝 |
| 成绩与撤榜 | 服务器重演负分/完整路线；只保留最高成绩、同分保留原时间；拒绝客户端指定分数/他人账号/对象伪装数组；仅能撤回本人记录 |
| 前 100 名及本人排名 | 101 名已审批测试用户上榜；本人第 101 名独立显示；真实单条、最多 101 行 SQL 与客户端一致性约束通过 |
| 两连接 InnoDB MVCC | 他人撤榜及停用未提交时仍读到旧完整快照；提交后本人变为第 100 名，榜内本人数据与单独本人名次一致 |
| 删除账号 | 真正调用 `/fan/delete`，对应成绩及会话失效；其余临时用户通过 WordPress 核心删除钩子清理 |
| 清理核验 | 102 个临时账号全部清理；无遗留测试成绩、用户元数据、会话或对应限流记录；排行榜表保留，行数为 0 |
| 原数据保留 | 原 3 个用户与 69 条 usermeta 完整摘要一致；14 张内容/分类/评论/推送表完整摘要一致，包括原有 34 条安装状态 |
| 服务恢复 | review PHP/web 恢复运行；loopback 健康检查及正常证书校验 HTTPS 的匿名管理/排行榜门禁再次通过 |

私有 run 回执 `5403b26a1d1a4156a02529b72f6858bd` 显示 `acceptancePassed=true`、`state=cleaned`、`cleanedCount=102`、`failure=null`。
实际测试时间为 03:22:57–03:23:38 UTC；仅审核服务的停止/恢复观察窗口约 03:22:30–03:24:49 UTC。
回执只保存合成账号清理目标、摘要及结果，不保存密码、Bearer token 或安装标识原文。
执行的 harness SHA-256 为 `19713d4998d6bae02feffa2262c2e93d96df5f9ddd1e492b72e35f1bdc7d78c9`。

本轮还验证了 130 项离线 guard/receipt/page 合同；已接入 `Scripts/security-check.sh` 的真实 PHP 分支，升级合同也加入同一检查脚本。离线 PHP 缺 POSIX 时，仅测试 UID facade；真实审核主机则硬要求原生 POSIX/mysqli，未以替身代替线上门禁。

完整 `security-check.sh` 使用真实本地 PHP/Composer/Node 执行，退出 0；Ruff 与 Bandit 门禁通过。已有 6 项 Linux util-linux flock 用例和 1 项旧 v5 源码基线用例按环境条件跳过，不算通过；本轮审核主机的 28 项文件事务测试不替代这 7 项。完整日志保存在本机 QA 目录的 `review-game-20260917-security-check.log`。没有触发付费 GitHub Actions。

### WP-CLI 加载方式

首次只读预检被 WP-CLI 默认 `eval` 与 `strict_types` 不兼容挡住，在任何测试建表/账号创建前停止。读取主机安装版本帮助后，使用其原生 `--use-include`；保留严格类型与全部隔离门禁，随后真实预检成功。

调用方式必须是 `wp ... eval-file <root-owned harness> --use-include <phase>`，阶段参数为 `preflight`、`install-schema=<run>`、`run=<run>`、`cleanup=<run>`，不是自定义 `--run` 标志。失败运行不能盲目重试；先读回执，再对该确切 run 执行清理。单独清理成功不会被记成验收成功。

## 发布边界

真实会话为临时测试用户显式配置，随后走真实鉴权，不声称验证了密码登录本身。本轮不声称已完成正式包真机验收、已登录 HTTPS 全链路、单条 SELECT 执行中途提交的并发证明或生产上线。
保持现有 Build 9 不变。生产部署、隐私线上披露回读与新的 TestFlight 发行仍是独立步骤。
