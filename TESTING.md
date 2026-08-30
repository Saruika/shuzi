# Hi，梳子测试与质量门禁

## 本地验证

执行以下命令即可复现 GitHub 的主要检查：

```bash
Scripts/security-check.sh
Scripts/ci-ios-tests.sh iPhone
Scripts/ci-ios-tests.sh iPad
Scripts/ci-release-analyze.sh
```

测试脚本会自动选择当前 Xcode 中第一台可用的 iPhone 或 iPad 模拟器，不依赖固定的设备名称或 UDID。DerivedData 位于独立临时目录并在任务结束时自动清理，不会进入 Git。

## 覆盖的用户路径

- 首页、作品、影视、收藏和关于五个主模块都能出现并切换。
- 作品网格可打开相册，相册封面可进入全屏查看，收藏操作可达。
- “发送合作邀约”可进入完整表单，管理员入口可进入安全登录页。
- 相同用例同时在 iPhone 与 iPad 上执行，iPad 还会旋转至横屏验证自适应布局，并在 `.xcresult` 中保留关键页截图。

UI 测试仅在 Debug 构建中使用参数关闭截屏保护，以便 XCTest 读取界面并保留失败截图。Release 构建中这些参数不生效。

## 安全门禁

`Scripts/security-check.sh` 会在构建前检查：

- Git 中是否误放 `.p8`、`.p12`、描述文件、`.env` 或私钥。
- 文本中是否出现高置信度的云密钥、私钥或 URL 内嵌密码。
- iOS 生产 Swift 源码是否使用明文 HTTP。
- Xcode/Privacy/Entitlement 配置、WordPress PHP 插件和 Python 订阅校验器是否通过基础语法检查。
- 内容清单会用超量集合、重复 ID、异常时长、超长 URL 和未知缓存版本做负向单元回归。

GitHub Actions 只有仓库内容读权限，不使用 Apple、腾讯云或服务器密钥；外部 Action 固定到完整 commit SHA。失败时保留七天 `.xcresult` 供排查。
