# 合作邀约 Phase 1：Build 41 生产硬关闭

> **禁止在当前版本开启、作为可运行数据处理服务部署，或导入任何真实数据。** 1.5.10 可携带硬关闭的未来实现与合同测试，但不表示功能已具备隐私、数据库或 Apple 上架条件。

## Build 41 的实际行为

- 插件内建 `COLLABORATION_PHASE1_RELEASE_FUSE = false`。即使 `wp-config.php` 或其他先加载代码误写 `define('YISHU_ENABLE_COLLABORATION_PHASE1', true)`，最终门禁仍为 `false`；字符串、数字、WordPress option、请求参数、环境变量或 filter 更不能开启它。
- 粉丝提交、管理员收件箱和状态更新的三个 REST route 不注册，因此粉丝和管理员都无法命中新接口。
- schema 安装、Outbox worker、扫描器、Cron hook 和调度器都不注册、不执行。即使直接调用公开 callback，也会失败关闭。
- 不授予新的 `manage_yishu_collaboration_requests` 权限，该权限也不能单独开启 Application Password。
- 旧 App 现有的本地合作邮件/`mailto` 流程保持不变；当前版本不会把邀约表单上传到新数据表。
- Phase 1 的 dormant 代码可随 1.5.10 发布，但本发布的内建熔断不可开启；线上节点仍应保持外部常量未定义，不得注册路由、建表、调度 worker 或处理真实联系信息。

未来版本若完成全部门槛，需要经过代码审查的新发布先显式修改内建熔断，并同时识别服务器 PHP 代码里的严格布尔常量。单独写入下面的外部常量在 Build 41 中不会开启功能：

```php
define('YISHU_ENABLE_COLLABORATION_PHASE1', true);
```

**上面只是供未来安全审计和发布探针识别的第二道门禁形式，当前版本严禁写入 `wp-config.php`。** 不得临时改为 option、filter、远程配置或直接 callback 来绕过硬关闭。

`deploy-app-content-release --bundle-preflight` 会在接触现有 Webroot、发出 HTTP 探针、创建备份或改变 PHP-FPM 状态之前，用隔离 PHP 运行候选插件：探针主动把外部常量定义为严格 `true`，并要求 `collaboration_phase1_enabled()` 仍严格返回 `false`。普通发布、legacy bootstrap 与 standby seed 复用同一个 bundle preflight；候选熔断不满足时不得继续发布。

## 允许开启前必须全部完成的门槛

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

这些契约在开启前仍必须通过上述五个门槛的真实环境验证。

## 验收与回滚

Build 41 验收应只验证“关闭”：

1. 分别在外部开关未定义、以及严格定义为 `true` 的隔离进程中，确认 `collaboration_phase1_enabled()` 都为 `false`，三个新 route 均未注册。
2. authority 和 standby 均不注册两个合作 Cron hook，不安排扫描任务。
3. 直接调用 schema、worker、sweeper 和 scheduler 均返回 `false`，且不产生数据库、邮件或 Cron 副作用。
4. 直接调用三个 REST callback 均返回 `collaboration_feature_disabled`，不触碰表单数据。
5. App 中原有邮件合作流程保持可用。

若误定义外部开关，Build 41 的内建熔断仍会阻止启用，但仍应立即移除常量并重载 PHP/WordPress。若观察到任何合作 route、表、Cron 或 Outbox 活动，说明运行代码已偏离受审发布；不要在未确定数据是否已写入时删表，先隔离服务、保全最小审计证据，再按批准的隐私/删除流程处理。
