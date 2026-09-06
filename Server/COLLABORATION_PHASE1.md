# 合作邀约 Phase 1：Build 43 生产硬关闭

2026-09-06 候选 1.5.13.4 已把认证加密接入实际提交、管理员读取和邮件队列，
不再持久化联系人及项目详情明文列。Schema 2、独立文件密钥和 HMAC 幂等指纹
见 [接入及隔离验证记录](releases/v1.4.0-build2-preflight10.md)。生产仍硬关闭；
认证邮件、管理员通知、日志/保留与迁移/轮换等门槛尚未完成。下文历史记录不代表启用批准。

> **禁止在当前版本开启、作为可运行数据处理服务部署，或导入任何真实数据。** 1.5.11 可携带硬关闭的未来实现与合同测试，但不表示功能已具备隐私、数据库或 Apple 上架条件。

## Build 43 的实际行为

- 插件内建 `COLLABORATION_PHASE1_RELEASE_FUSE = false`。即使 `wp-config.php` 或其他先加载代码误写 `define('YISHU_ENABLE_COLLABORATION_PHASE1', true)`，最终门禁仍为 `false`；字符串、数字、WordPress option、请求参数、环境变量或 filter 更不能开启它。
- 粉丝提交、管理员收件箱和状态更新的三个 REST route 不注册，因此粉丝和管理员都无法命中新接口。
- schema 安装、Outbox worker、扫描器、Cron hook 和调度器都不注册、不执行。即使直接调用公开 callback，也会失败关闭。
- 不授予新的 `manage_yishu_collaboration_requests` 权限，该权限也不能单独开启 Application Password。
- 旧 App 现有的本地合作邮件/`mailto` 流程保持不变；当前版本不会把邀约表单上传到新数据表。
- Phase 1 的 dormant 代码可随 1.5.11 发布，但本发布的内建熔断不可开启；线上节点仍应保持外部常量未定义，不得注册路由、建表、调度 worker 或处理真实联系信息。

未来版本若完成全部门槛，需要经过代码审查的新发布先显式修改内建熔断，并同时识别服务器 PHP 代码里的严格布尔常量。单独写入下面的外部常量在 Build 43 中不会开启功能：

```php
define('YISHU_ENABLE_COLLABORATION_PHASE1', true);
```

即使未来发布显式打开上述两层功能门禁，能力接口、提交、管理员收件箱和 Outbox 仍会保持关闭，直到运维同时显式配置有效的 `YISHU_COLLABORATION_EMAIL`，并在完成认证邮件传输、退信处理和端到端验收后将 `YISHU_COLLABORATION_MAIL_TRANSPORT_READY` 严格设为布尔 `true`。`wp_mail()` 函数存在或一次调用返回 `true` 都不视为送达证明；管理端状态只能表述为“邮件服务已接受”。当前版本严禁设置这些生产常量。

**上面只是供未来安全审计和发布探针识别的第二道门禁形式，当前版本严禁写入 `wp-config.php`。** 不得临时改为 option、filter、远程配置或直接 callback 来绕过硬关闭。

`deploy-app-content-release --bundle-preflight` 会在接触现有 Webroot、发出 HTTP 探针、创建备份或改变 PHP-FPM 状态之前，用隔离 PHP 运行候选插件：root 从不可由 worker 遍历的 `0700` staging 边界读取已经通过 manifest 校验的入口，并仅通过标准输入交给 `www-data`、禁用常见文件流/socket/DNS/扩展网络出口且 `open_basedir=/nonexistent` 的 PHP 进程；不会为了探针放宽 staging 权限。探针主动把外部常量定义为严格 `true`，并要求 `collaboration_phase1_enabled()` 仍严格返回 `false`。整个探针只执行发布记录精确审核的 1.5.8/1.5.10/1.5.11 入口哈希，未知入口在 `eval` 前失败关闭；无 gate/fuse 的兼容路径还必须是精确审核的 1.5.8 PHP 哈希。全部断言完成后必须输出唯一成功哨兵，因此允许列表内候选顶层意外提前 `exit(0)` 也不能跳过后置门禁。源码读取失败、候选加载失败、超时和熔断不安全分别失败关闭。普通发布、legacy bootstrap 与 standby seed 复用同一个 bundle preflight；候选熔断不满足时不得继续发布。

## 允许开启前必须全部完成的门槛

2026-09-06 候选增量（**仍保持生产硬关闭**）：已补齐完整 schema 元数据校验，
覆盖 InnoDB、全部列的类型/长度/nullable/default/auto_increment，以及所有主键、
唯一键和普通索引的完整字段/顺序/前缀/可见性。逐次检查 `dbDelta` 的返回形状和
即时数据库错误，再读取真实元数据；异常、部分成功或不兼容表不能写入 ready 版本。
新回归执行实际 dormant trait，不加载 API 入口或生产 WordPress 配置。
默认 486 项元数据/故障断言；独立 MySQL 8.0.46 临时空库通过 28 项 DDL、
缺表/错误字段及索引、唯一性、事务回滚断言，并精确清理测试库。
上述首轮夹具执行真实 DDL 和元数据，不加载完整 WordPress。后续已另补独立的
WordPress 7.1/MySQL 8.0.46 运行时验证：校验官方核心文件后，从空数据库启动真正
的 WordPress 和 `wpdb`，执行真实 `dbDelta`。36 项断言覆盖首次建表、重复升级无
DDL、字段/索引修复、SQL 失败不写 ready、修复后恢复，以及错误引擎/前缀索引
失败关闭；独立宿主网络拒绝测试通过，测试数据库清理后数量为零。
见 [WordPress 集成记录](releases/v1.4.0-build2-preflight3.md)。这仍只是第 1 项的
运行时证据；PII 处理、保留/删除、认证邮件和并发双节点演练仍未完成。
不能据此开启合作提交或宣称自动邮件已送达。

后续隔离回归发现并复现：收件箱列表查询失败后，随后的计数查询会重置
`wpdb->last_error`，从而返回错误的“成功但空列表”。候选 1.5.13.2 在每次查询后
立即核验，并严格检查 COUNT 返回值，不把 null、无效类型或溢出值转换为 0。
扩展后的真实 WordPress 回归为 64 项，覆盖带/不带状态筛选的列表故障、计数故障、
异常空计数及恢复。见 [修正记录](releases/v1.4.0-build2-preflight4.md)；尚未部署。

随后在同一隔离 WordPress 环境补齐删号清理回归：129 项累计断言通过。发现并
修正仅凭表存在就开始事务删除的问题；候选 1.5.13.3 在删除之前核对物理 schema
与 InnoDB，且不依赖功能开关/ready option。覆盖查询、三张表删除及 COMMIT 的
合成失败回滚、两用户隔离、重复删除，以及 MyISAM 拒绝后数据不变。
这不是备份/邮件副本清理或生产删号端到端验收，相关门槛仍未关闭。
见 [删除事务记录](releases/v1.4.0-build2-preflight5.md)。

```bash
php Server/tests/collaboration-schema-regression.php
# 仅测试环境：Unix socket 认证；自建随机空库并在 finally 精确销毁。
# 不接受生产库名、不读取 wp-config、不发送邮件或推送。
php Server/tests/collaboration-schema-regression.php --mysql
```

`Server/tests/collaboration-wordpress-schema-integration.php` 为显式 Linux 集成测试，
不能直接针对线上 WordPress 路径执行。必须先在 `/tmp/yishu-wordpress-schema.XXXXXX`
形式的全新目录下载、校验 WordPress 7.1，将该目录设为 root 所有且 `0700`、核心
文件不可由组/其他用户写入，并在 `PrivateNetwork=yes`、禁止访问生产 Webroot/配置
和 MySQL 数据目录的 systemd 沙箱中运行。测试只通过本地 Unix socket 自建随机空库，
不接受已有数据库名、不加载 `wp-config.php` 或插件，不注册合作 API，也不发送邮件。
具体已执行的隔离参数与范围见上述发布记录；缺少隔离条件时拒绝执行，不伪造通过。

1. **InnoDB 和 schema 实证**：安装后逐表校验引擎、完整字段、字段类型、三个唯一索引及普通索引；不能只检查表名存在。必须检查 `dbDelta` 结果，并在引擎或索引不符合时失败关闭，不得声称事务或幂等已成立。
2. **PII 日志抑制**：联系人、联系方式、组织、城市、预算和项目说明不得出现在 WordPress/PHP/MySQL 错误日志、`$wpdb->last_query`、邮件失败日志、安全 action 或运维输出。需要可验证的屏蔽方案和故障测试。
3. **保留期和删号级联**：明确数据最短/最长保留期，实现定时清理；粉丝在 App 中删除账号时，请求表、Outbox、审计、备份、导出和邮件副本必须按审批后的规则删除或不可逆匿名化，并完成重试/幂等设计。
4. **隐私披露与用户界面**：更新 App 内隐私政策、提交前说明、用户同意与删除入口，并在 App Store Connect 隐私标签中如实披露收集、用途、关联身份、保留与删除。合作邮箱收件人也必须纳入权限和保留政策。
5. **真实数据库与故障测试**：在与生产相同的 MySQL/MariaDB、WordPress、PHP 和双节点架构上完成建表/升级/回滚、并发幂等、事务回滚、lease 恢复、重试收敛、邮件重复、删号级联、主备故障和恢复演练。仅通过静态/PHP harness 不能开启。

以上任一项未完成，发布负责人必须拒绝开启常量。开启前还需要独立安全/隐私复审和明确的产品批准。

## 保留的未来契约（尚不可用）

代码中保留了以下待验证设计，目的是便于后续审查，不是上线声明：

- 已批准 normal 粉丝会话的 UUIDv4 幂等提交。
- authority-only 的 InnoDB 请求、Outbox 和脱敏审计表草案。
- 专用 `manage_yishu_collaboration_requests` 权限、管理收件箱和乐观并发版本。
- 有界重试、lease 与 `dead` 终态的邮件 Outbox 草案。
- 粉丝用户、安装 ID 和网络指纹三层限流草案。
- App 删号路径会在删除 WordPress 用户前，以事务方式先删除该粉丝关联的请求、Outbox 和审计；清理入口不依赖功能开关，避免回滚关闭功能后遗留历史数据。该设计仍需真实数据库并发、故障和备份清理验收。

这些契约在开启前仍必须通过上述五个门槛的真实环境验证。

## 验收与回滚

Build 43 验收应只验证“关闭”：

1. 分别在外部开关未定义、以及严格定义为 `true` 的隔离进程中，确认 `collaboration_phase1_enabled()` 都为 `false`，三个新 route 均未注册。
2. authority 和 standby 均不注册两个合作 Cron hook，不安排扫描任务。
3. 直接调用 schema、worker、sweeper 和 scheduler 均返回 `false`，且不产生数据库、邮件或 Cron 副作用。
4. 直接调用三个 REST callback 均返回 `collaboration_feature_disabled`，不触碰表单数据。
5. App 中原有邮件合作流程保持可用。

若误定义外部开关，Build 43 的内建熔断仍会阻止启用，但仍应立即移除常量并重载 PHP/WordPress。若观察到任何合作 route、表、Cron 或 Outbox 活动，说明运行代码已偏离受审发布；不要在未确定数据是否已写入时删表，先隔离服务、保全最小审计证据，再按批准的隐私/删除流程处理。
