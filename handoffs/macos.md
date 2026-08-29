# macOS 交接记录

## 当前任务

- 日期：2026-08-29
- 功能：DS-009 / macOS 多显示器并发切换实机验收记录
- 分支：`codex/macos-ds-009-hardware-acceptance`
- 基线：`main@0cb90ae24b9cba2c940eb3723b8c6f8b8ee88135`
- 本轮实现提交：本提交（仅文档）
- 平台实现 PR：[#46](https://github.com/maizihk/DisplaySwitch/pull/46) 已合并
- 验收记录 PR：本任务创建，保持开放且不合并

## 原因与决策

- 用户已在最终版本上完成真实多显示器输入源切换，确认小米与 Dell 同时切换，不再出现先后串行。
- 该结论是用户实机验证结果，不是 XCTest、模拟后端或 CI 结果；本轮只记录验收，不修改调度、C2C、协同或 DDC 读取实现。
- `c1a019b` 已让底层批量服务并发，但 USB 离开路径仍逐台调用单目标 sink，AppDelegate 又把每个单目标任务放进串行 `inputSwitchQueue`；底层从未同时收到多台目标，因此实机仍必然先后切换。
- 本轮保留事件间的串行队列，只把同一 USB 离开事件的全部有效显示器聚合成一个批次。这比把外层队列整体改成 concurrent 更安全：既消除了同事件串行点，又保留跨事件顺序和安全门控。
- USB、手动和协同入口现在都把批量目标直接交给同一个 `InputSourceSwitchService`；不同 selector 并发，同一 selector 仍去重并由 per-display arbiter 串行。
- 单台失败按原 display ID 报告，不取消同批次其他目标。未改变 C2C、writeCycles/writeAttempts、VCP 帧、地址、matcher、租约、诊断、协议或 Windows。

## 修改范围

- 本轮只更新 `macOS/DEVELOPMENT_CHECKLIST.md` 和 `handoffs/macos.md` 的实机验收状态；没有代码变更。
- `LocalUSBSwitchCoordinator.swift`：USB 离开事件聚合有效映射并一次提交批次，逐目标保留失败归因与公共向量顺序。
- `main.swift`：AppDelegate 将 USB 批次统一解析为 `InputSourceSwitchTarget`，只排入一次事件队列，再调用批量输入服务。
- `LocalUSBSwitchTests.swift`：从 USB 离开入口阻塞第一台写入并证明第二台已进入；覆盖单台失败隔离、同 selector 去重及 16 条公共 USB 向量。
- `macOS/DEVELOPMENT_CHECKLIST.md`：校准 DS-009 多显示器输入切换状态。
- 未修改协议、Windows、版本号、tag、Release 或 GitHub Actions。

## 自动验证

- 输入源切换与 USB 入口专项：20/20；完整 XCTest：109/109。
- 全新 Debug 测试构建、Release 脚本构建通过。
- `./macOS/scripts/build-app.sh` 在 `/private/tmp` 的干净源码副本通过；App 打包前和 ZIP 实际解压后严格 codesign 验证均通过。
- 仓库内脚本构建本身成功，但 File Provider 会即时恢复输出 App 的 FinderInfo，导致仓库输出路径直接验签失败；交付 ZIP 来自无该元数据的同源码干净构建。
- 所有测试使用模拟 resolver/transport；未执行真实 DDC、USB、网络、唤醒或输入源切换。
- 平台实现 PR #46 和最终协调 PR #48 已合并；本轮文档 PR 保持开放，不合并。

## 用户实机验证

- 已通过：最终版本中小米与 Dell 在同一多显示器切换事件内同时切换，不再先后串行。
- 证据类型：用户实机确认；不是自动测试或代理执行的硬件验证。
- 验收边界：仅确认多显示器并发切换行为，不代表 C2C 偶发执行、协同连接、DDC 原生读取或其他硬件路径已通过。

## 测试包

- 路径：`macOS/outputs/DisplaySwitcher-DS-009-usb-batch-parallel-macOS-test.zip`
- SHA-256：`6132ec40aaad728e48486a554f1a7f96c0bd2ff38d56bc4a2711280d6418d95b`
- 无 `__MACOSX`、AppleDouble 和 Finder 扩展属性；实际解压后严格验签通过；构建产物不进入 Git。

## 尚需用户实机验证

1. 单台失败时，是否仍不影响同一事件中的其他显示器。
2. 同一显示器连续触发时是否仍保持串行，不与该显示器的亮度、对比度或音量操作并发。
3. C2C 偶发不执行问题仍保留，本轮没有调整其重试、服务生命周期或 matcher。

## 安全与工作区

- 三个未知重复文件保持未跟踪且不提交。
- `macOS/.build/` 和 `macOS/outputs/` 是忽略的本机构建产物。
