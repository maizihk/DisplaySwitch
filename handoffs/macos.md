# macOS 交接记录

## 当前任务

- 日期：2026-08-27
- 分支：`codex/macos-ds-001-state-machine`
- 清单：DS-001 / M-004
- 基线：`9624ffb9cdf1d39809a66cf11592c2dab43e577d`
- PR：[#4 DS-001 macOS: Extract state machine and add vector tests](https://github.com/maizihk/DisplaySwitch/pull/4)
- 最终实现提交：`1ff24e07f7d5d9a865b1a9c424847ebb74b510e5`

## 完成内容

- 已完成 DS-001 任务范围内的 macOS 状态机隔离：新增 `macOS/Sources/DisplaySwitcher/HandoffStateMachine.swift`，并让 `main.swift` 与 `PeerTransport.swift` 接入该状态机。
- 按 `contracts/protocol-v1/` 读取的方向实现：
  - 消息验收与拒绝路径统一到状态机前置校验
  - 150ms USB 防抖、在线窗口（6s）和 4 次/600ms 握手重试/兜底逻辑
  - `usb_present` 与 `usb_attached_and_awake` 的事件关联与幂等处理
- 新增并修复状态机/消息向量测试（不接真实网络/USB/DDC）：
  - `macOS/Tests/DisplaySwitcherTests/HandoffMessageVectorTests.swift`（17 条）
  - `macOS/Tests/DisplaySwitcherTests/HandoffStateMachineVectorTests.swift`（15 条）
- `macOS/DisplaySwitcher.xcodeproj` 已将 `HandoffStateMachine.swift` 正确加入测试目标编译范围。
- 本次按 PR #4 协调阻塞清单修复了：
  - `completeOutgoingIfNeeded` 不再在 `requestSwitch` 前清空 `outgoingEventID`
  - 通过状态机重试/确认路径修正重复 `handover_request` 的确认发送条件（仅 USB 已接入时发送）
  - `usb_present` mismatch 不再触发额外唤醒动作，避免副作用计数漂移
  - 统一公共向量文件路径解析到仓库根目录，避免测试找错目录
- 本次补齐了 PR #4 最新协调评论中明确要求的解码问题：
  - `PeerMessageType` 的 `Codable` 解码中显式赋值为 `self = Self(rawValue: rawValue) ?? .unknown(rawValue)`，避免 `self.init(rawValue:)` 的编译歧义。
- 后续 CI 暴露并已修复测试接线问题：
  - `.acceptMessage` 测试 pattern 改为与枚举一致的两个关联值。
  - 测试 harness 使用独立 recorder，避免初始化 `stateMachine` 前捕获 `self`。
  - `referenceTime` 作为虚拟 Unix 时间，`atMs` 保持场景相对单调时间；初始和最终在线时间按同一基准转换。
  - 网络发送不再计入 `usbActions` 硬件副作用。
  - 首次合法消息按 `acceptMessage`、`setPeerReachable` 顺序记录；重复消息只刷新在线时间，不重复记录在线动作。
  - 请求先到、USB 后到时，等待 USB 到达唤醒完成后依次发送 `usb_present` 和 `usb_attached_and_awake`。
- 最终安全审计修复：
  - `handleIncomingMessage` 在任何消息校验、在线状态或重放记录变更前检查协同开关、USB 自动化开关及本机配对码至少 8 位。
  - 短或空本机配对码即使与报文完全相同也会静默拒绝，不刷新在线状态、不回复且不触发硬件动作。
  - 协同关闭或 USB 自动化关闭时，合法 `handover_request` 和 `status_probe` 均保持零网络和硬件副作用。
  - 清理 USB 返回分支未使用的 `outgoingID` 变量；最终 CI 日志未再出现对应警告。
- 重复合法 `status_probe` 在十秒重复窗口内仍会：
  - 使用相同 `eventID` 再次发送 `status_response`。
  - 刷新状态机在线时间并再次通知适配层在线，恢复设置界面的连接状态。
  - 不额外产生 `rejectMessage(duplicate)`，公共动作与 Windows 一致。
  - 回归测试先推进到 6001ms，确认六秒窗口过期并通知离线，再重放同一 probe 验证恢复。
  - 保持唤醒、切屏和 USB 硬件副作用为零；其他重复消息行为不变。

## 自动验证

- GitHub Actions `build-and-test` 在最终实现提交 `1ff24e07f7d5d9a865b1a9c424847ebb74b510e5` 上完整通过：
  - Run：`https://github.com/maizihk/DisplaySwitch/actions/runs/33052109672`
  - Xcode 27.0 / Swift 6.4 / macOS 27 SDK。
  - Debug：`xcodebuild ... -configuration Debug ... build`，`BUILD SUCCEEDED`。
  - 全部 XCTest：19 个测试方法、0 失败；其中 17 条消息向量和 15 条状态机向量全部通过，短/空配对码、协同关闭、USB 自动化关闭和重复合法 `status_probe` 四项无副作用/恢复测试全部通过。
  - Release 与打包：`./macOS/scripts/build-app.sh`，`BUILD SUCCEEDED`，生成 `macOS/outputs/DisplaySwitcher.app` 和 `DisplaySwitcher-macOS-arm64.zip`。
  - 签名：构建脚本内严格验证通过，CI 独立执行 `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app` 的 `Verify artifacts` 步骤通过。
- 当前本机 Codex 执行环境仍只暴露 `/Library/Developer/CommandLineTools`，因此未把此前失败的本机构建误报为通过；以上构建、测试、打包和签名结论来自 PR #4 的真实 GitHub Actions macOS runner。

## 尚需验证

- 实机验证（未执行）：
  - 状态机与协议行为在真实 USB/显示器与网络环境下是否完全一致
  - 按任务安全限制，本轮没有执行真实 DDC、USB 交接或显示器唤醒。

## 对 Windows 端的影响

- 本次 DS-001 工作提交仅改 `macOS/` 与本文件；`origin/main` 合并会同步其包含的 Windows 变更（本次为常规同步，不是本任务直接改写）。
- Windows 端在完成其对应分支验证后，将由协调层按 DS-001 向量进行交叉比对。
