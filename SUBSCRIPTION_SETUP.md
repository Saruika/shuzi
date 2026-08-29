# 易姝完整作品订阅配置

App 内订阅功能已经接入 StoreKit 2。正式收费前，需要由 Apple Developer 团队在 App Store Connect 创建同名商品。

## App Store Connect 商品

- 类型：自动续期订阅
- 订阅组参考名称：`易姝完整作品`
- 商品参考名称：`完整作品月度订阅`
- 产品 ID：`cn.com.shuzijun.yishu.photos.monthly`
- 周期：1 个月
- 中国大陆价格：人民币 3 元/月
- 中文显示名称：`易姝完整作品`
- 中文说明：`订阅期间解锁 App 内全部相册照片与持续更新的影像作品。`

产品 ID 必须与 `Yishu/Services/SubscriptionStore.swift` 中的
`SubscriptionStore.monthlyProductID` 完全一致，创建后不可修改。

## 上架前必做

1. 在 App Store Connect 的“订阅”中新建订阅组和自动续期订阅。
2. 为中国大陆店面选择人民币 3 元价格点；其他店面价格由 App Store Connect 换算后逐一确认。
3. 添加本地化名称、说明、审核截图和审核备注。
4. 在审核备注中提供一个可直接打开作品页的方法，并说明每个相册前 3 张免费、其余照片需要订阅。
5. 首个自动续期订阅须随一个新的 App 版本一并提交审核。
6. 确认 App Store Connect 中的“付费 App 协议”、税务与收款资料均已生效。

## App 内规则

- 普通用户：每个相册免费浏览前 3 张照片。
- 有效订阅用户：浏览全部相册照片。
- 管理员：登录后始终拥有完整访问权限，便于维护内容。
- 订阅到期：已收藏记录保留，但付费照片重新锁定。
- 购买与恢复购买：完全由 Apple StoreKit 处理，App 不保存支付信息。
- Debug 构建：付费墙底部提供“开发测试：模拟订阅成功”，仅用于本地验收，不会进入 Release 构建。

## 测试顺序

1. Debug 模式分别验证访客、模拟订阅和管理员三种状态。
2. App Store Connect 商品建立后，用 Sandbox Apple Account 验证真实购买、自动续期、取消和恢复购买。
3. 使用 TestFlight 再验证一次商品价格、本地化文本和订阅管理入口。

