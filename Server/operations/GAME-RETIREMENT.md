# 游戏服务退役

用户授权范围为删除游戏资源、排行榜功能及历史游戏数据。运行代码已从发布包移除；
以下工具仅保留必要的数据退役与回滚能力，不包含游戏剧情、规则或可重启游戏的安装器。
Git 历史和原发布收据不重写。

## 精确数据范围

- 当前站点 `$table_prefix . 'yishu_game_leaderboard'`，含该表全部最高成绩记录。
- options 中准确的 `yishu_game_leaderboard_schema_version`。
- `_transient_(timeout_)?yishu_game_(read|submit|delete)_[a-f0-9]{64}` 对应游戏限流记录。
- 已核实的 Redis Object Cache drop-in（SHA256 `b3e91c4365480363c5042a11e53e5c6748c789345fd3f6ee0cac18ab582a0f3b`），
  仅本地 `127.0.0.1:6379` DB 0、无额外 salt、`wp_` 单站配置。
  精确键为 `wp:options:yishu_game_leaderboard_schema_version` 和
  `wp:transient:yishu_game_(read|submit|delete)_[a-f0-9]{64}`。
  对站点范围的游戏键进行有界 SCAN，未知键、其他配置或实现摘要均拒绝。
- 共享 `wp:options:alloptions` / `notoptions` 只断言没有游戏条目，绝不修改、删除或备份整个共享数组。
- 没有游戏专属 usermeta。工具发现 `_?yishu_game_` 开头的未知元数据会拒绝并要求核实，不扩大删除范围。
- 账号、昵称、审批、会话、通知、作品及其他业务表不删除。无全库备份、全库清空或全缓存刷新。

## 操作顺序

1. 按 [候选清单](../releases/no-game-candidate.md) 部署已固定校验的无游戏服务端版本，
   完成 PHP 工作者切换与必要健康检查。确认旧游戏资源已不在运行目录。
2. 等待旧游戏请求结束。旧游戏临时限流计数 TTL 为 60 秒；数据库中的对应项会由本工具删除。
   缓存只接受上述经过核实并固定摘要的实现及配置；其他 drop-in 需要单独审核，不能全局 flush。
3. 每个节点分别建立 root:root 0700 的 `/var/backups/shuzijun-game-retirement`。
   工具与依赖放置在 root 拥有且其他用户不可写的私有操作目录。
4. 默认预检只返回站点身份、记录计数及计划 SHA，不返回用户 ID、成绩行或数据库凭据。
5. 核对计划后运行 apply。它先写 0600 `snapshot.json`、`rollback.sql`、`sha256.json`，
   fsync 文件与目录、复核摘要，再删除准确表与 options，最后逐键原子比较并删除游戏缓存，回读确认。
   缓存 raw bytes（base64）和当时 TTL 只保存在私有 snapshot 中，不打印。
6. 再跑默认预检，确认表不存在、游戏 options 和 cache keys 均为 0。
   重复 apply 同一空计划会返回 `already-retired`。

生产节点（把 `PRIVATE` 换成已核实的 root 私有目录；每个节点独立获得计划）：

```sh
/usr/bin/wp --allow-root --skip-packages --path=/var/www/html/shuzijun.com.cn \
  --require=/PRIVATE/decommission-game.php shuzijun retire-game --profile=production
```

在同一节点，使用刚回读的计划 SHA 与身份字段；主节点 role 是 `authority`，备用节点是 `standby`：

```sh
/usr/bin/wp --allow-root --skip-packages --path=/var/www/html/shuzijun.com.cn \
  --require=/PRIVATE/decommission-game.php shuzijun retire-game --profile=production \
  --apply=PLAN_SHA256 --confirm-database=wordpress \
  --confirm-home=https://www.shuzijun.com.cn --confirm-environment=production \
  --confirm-prefix=wp_ --confirm-role=ROLE_FROM_PREFLIGHT
```

独立审核环境使用明确的另一组身份，不能通过任意 path/home 参数绕过生产检查。
先执行审核插件升级工具；它为新版本安装准确的 `release.sha256`。

```sh
/usr/bin/wp --allow-root --skip-packages --path=/srv/shuzijun-review/site \
  --require=/PRIVATE/decommission-game.php shuzijun retire-game --profile=review

/usr/bin/wp --allow-root --skip-packages --path=/srv/shuzijun-review/site \
  --require=/PRIVATE/decommission-game.php shuzijun retire-game --profile=review \
  --apply=PLAN_SHA256 --confirm-database=shuzijun_review \
  --confirm-home=https://review.shuzijun.com.cn --confirm-environment=review \
  --confirm-prefix=review_ --confirm-role=review-isolated
```

命令注册在 WP-CLI 的 `before_wp_load` 阶段，固定配置只做词法读取、不执行，
不启动 WordPress、mu-plugin、cron、邮件或 HTTP。数据库使用新的本地 mysqli 连接，
不允许重连重放。生产必须匹配 root 角色文件；审核必须匹配独立路径、库、用户、
Unix socket、`review_` 前缀和 review 环境，且数据库凭据不能看到生产库。

工具取得既有 `/var/lib/shuzijun-sync/site-operation.lock`。apply 的短备份/清理窗口
额外锁定本节点的游戏表、options 及 usermeta 读访问，阻止旧请求与快照交错。
默认预检不取得数据库写锁。检测到触发器、外键、未知列或并发变化会拒绝。
Redis 连接显式设置 `OPT_MAX_RETRIES=0`。自然 TTL 倒计时不改变计划摘要，
但键集合或值变化会阻止删除并要求重新预检。缓存写入仅为允许键的单键
compare-and-delete；共享数组和其他站点 namespace 不改变。

## 恢复与不确定结果

DROP TABLE 不能用 SQL 事务回滚。本工具不自动恢复、不盲目重试未知结果。
任何失败都保留返回的 backupID；先重新执行预检确认实际状态。
私有 `rollback.sql` 仅含游戏表定义、游戏记录及准确游戏 options 的 INSERT，
不存在用户/其他业务数据，也不会覆盖冲突的现有记录。仅在另行确认恢复目标身份、
核对 `sha256.json` 并隔离访问后由操作员审阅执行。备份不上传到 Git 或公开目录。
缓存不会由 SQL 自动恢复；snapshot 中的 TTL 是采样时的剩余时间，不能在日后直接重启该期限。
任何恢复均需要重新取得授权；这些备份不得用于恢复游戏服务。

## 本次临时备份的人工清理

新建的 `/var/backups/shuzijun-game-retirement` **没有本工具创建的自动到期任务**，
也未证明受既有整站备份保留任务管理。不能把隐私政策中的保留描述当作自动删除证据。
当前授权要求只保留至本次清理验收和新版本分发完成；随后由主操作员按各节点返回的
准确 backupID 逐项核实目录 owner/mode、内部三个预期文件和摘要，再精确移除这些新增
游戏退役备份，并记录回读结果。此项是明确人工待办，不得遗忘或自动扩展为旧整站备份清扫。
不递归扫描或删除整站历史备份；其中可能包含其他业务数据，另按原保留规则管理。

本地验证：`php Server/tests/game-decommission-test.php` 和
`php Server/tests/no-game-contract-test.php`；前者为离线合成数据库和 Redis 测试，
不等于实际 MySQL、生产或审核环境清理已完成。
