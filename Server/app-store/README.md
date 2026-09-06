# 商店资料与上传前检查

`zh-Hans.json` 是已审核的公开文案，不保存审核密码、身份码或签名凭据。
上架实际缺项以仓库根目录 `APP_STORE_READINESS.md` 的最新证据为准。

## 检查实际导出的签名 App

在 Mac 上对准备上传的 IPA 解包目录执行；不是对模拟器 `.app` 或未导出的归档执行：

```sh
python3 Scripts/check-distribution-package.py \
  --app /absolute/export-inspection/Payload/Yishu.app \
  --version 1.4.0 --build 4
```

必须传入本次计划上传的版本及构建号，不从旧包自动推断预期值。工具只读，检查实际签名、
设备平台、iPhone/iPad 支持、iOS 17 部署目标、签名及描述文件中的生产 APNs、Apple 登录、
WeatherKit、禁止调试、团队/App 标识与描述文件有效期。也检查当前无追踪声明及 ATS 边界。
失败返回非零，仅显示固定检查标识；不输出原始描述文件、证书、设备列表或工具错误正文。

这是一条新增的上传前手动校验命令，尚未接管或自动阻断独立的上传工具。
CI 对校验逻辑执行合成单元测试与静态分析；没有签名凭据的 CI 不伪装验证过实际发行包。
成功只能说明这些包级检查通过：`submissionReady` 和 `liveServices` 都明确标为 `not_assessed`。
仍需实际登录、定位/天气、APNs、删号、图片连续浏览、审核账号及正式商店资料的完整验收。

源码 entitlements 中的 `aps-environment=development` 不能单独证明发行包错误；
以实际导出包的有效签名和嵌入描述文件为准。不要为使校验通过而修改已签名包的内容。
已有 `ci-release-analyze.sh` 的构建与资源审计继续保留，本工具不替代它。

Apple 要求 [审核期间可用的后台与完整访问](https://developer.apple.com/app-store/review/guidelines/#before-you-submit)，
以及具有实际联系方式的 [支持网址](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)。
包校验通过或元数据字段非空不等于满足这些要求，也不代表审核通过。
