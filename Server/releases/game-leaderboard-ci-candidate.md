# 小游戏排行榜候选：当前 CI 材料记录

候选标识：`game-leaderboard-ci-candidate`，2026-09-17（UTC+8）。
这是当前工作区的质量门禁材料摘要，不是发布标签、正式构建或完整 CI 通过证明。

## 范围与来源

- 保留先前所有发布记录不变。旧记录对应历史文件，不应拿来证明当前工作流与脚本。
- 当前工作流已在同一 preflight 步骤依次执行仓库检查及 Swift 优化编译回归；
  记录下方 12 项当前材料的精确 SHA-256，以及固定 SPDX 2.3 schema 摘要。
- 契约只切换到本候选记录，继续拒绝缺失、错误、重复、互相冲突、正文内嵌和尾随内容的摘要。
  不放宽运行器、依赖锁、审计覆盖或来源验证要求。

## 已核实与未完成边界

- 已在隔离 Python 3.13.15 环境使用现有质量依赖锁和 `--require-hashes` 安装工具，
  未修改依赖锁或全局 pip；`pip check` 通过。
- 两组 Python 依赖审计分别覆盖运行时 33 项、质量工具 37 项，均未报告已知漏洞；
  两份审计输出的组件覆盖校验通过。这不等于不存在未知漏洞。
- 本地策略校验、fail-closed 解析、审计覆盖测试及 CycloneDX / SPDX schema 验证通过。
  固定 SPDX schema 的下载内容先验证摘要再使用；工作流文本与材料拒绝测试也独立通过。
- 本机实际为 Xcode 27.0（27A266a），现有来源策略要求 Xcode 26.6（17F113）。
  `test_local_provenance` 因工具链不匹配而失败，完整供应链契约仍未通过。
  不伪造来源、不把本机 Xcode 27 记为 26.6，也不修改策略来掩盖此差异。
- 本记录未证明当前候选在 GitHub Actions 完整通过；本次没有触发云端工作流。
  也不表示已部署服务器、上传 TestFlight 或提交 App Store 审核。

## 当前材料摘要

```text
DEPENDABOT_SHA256=248d721817227d770dffbd04c5dff3b1d4c084d402059b77201ff9b086da15c0
WORKFLOW_SHA256=77be82960572461c9754521e4275b4947eb9d44786a56844c517355c37ead214
QUALITY_INPUT_SHA256=a083ccad478b6ce1c6eec26703fc408d135d60d9e490cca83fba5eba499cce1c
QUALITY_LOCK_SHA256=b0323bb24cc389014ab2e8bfa32df687bf15078caf2743a9fb26fa9a0481846e
RUNNER_POLICY_SHA256=f517db9440b488263819c62d8bbda95de5c21a3b8b7c4ce455ac2175e9f1e378
RUNTIME_INPUT_SHA256=dd55470e3027d49c67e0d787a278fc4537846aaf24f91ce273575000098de425
RUNTIME_LOCK_SHA256=f01b3daf02b9f518c87ed32cc072d9f3e0d2d7a182f0c214e1a5f69432c5ff55
RUFF_POLICY_SHA256=76081ff13d0743c297414d482ee23ff61535c633e400bca5cf0ccf1b02a3b859
SUPPLY_CHAIN_SCRIPT_SHA256=58e9decd01bbfff60f567ecb90059d377b646e0f3d951fe94fd9e9ffd1800fd8
RELEASE_ANALYZE_SHA256=ea90a5701479e6a1ae4c945631f450118bb1d68ba088e3c2e1c7a8ea880d8b21
TEST_SUMMARY_SHA256=ff65c2272cd1eae257d40aad7221722d21148714b3bbae67125c761f382303c0
DISTRIBUTION_CHECK_SHA256=5c51c3464e439d2ee2014b3f1b5f3ae73fd569f39530f3bd86fe1e333c1f451f
SPDX_2_3_SCHEMA_SHA256=239208b7ac287b3cf5d9a9af23f9d69863971102a5e1587a27a398b43490b89b
```
