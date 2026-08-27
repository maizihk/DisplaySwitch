# macOS 交接记录

## 当前任务

- 日期：2026-08-27
- 分支：`codex/macos-ds-001-state-machine`
- 清单：DS-001 / M-004
- 基线：`9624ffb9cdf1d39809a66cf11592c2dab43e577d`

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

## 自动验证

- 只读环境检查：
  - `swift --version` 成功（Swift 6.4）
  - `xcodebuild -version`：当前系统 `active developer directory` 为 `CommandLineTools`，不能运行 `xcodebuild`/`build-app.sh`。
  - `xcrun --sdk macosx --show-sdk-path` 可取到 `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`
- 实际执行结果：
  - `xcodebuild -version`：`/Library/Developer/CommandLineTools`，非完整 Xcode，xcodebuild 相关命令全部不通
  - `xcodebuild -project macOS/DisplaySwitcher.xcodeproj -scheme DisplaySwitcher -configuration Debug build`：失败
  - `xcodebuild -project macOS/DisplaySwitcher.xcodeproj -scheme DisplaySwitcher -configuration Release build`：失败
  - `xcodebuild -project macOS/DisplaySwitcher.xcodeproj -scheme DisplaySwitcher -configuration Debug test`：失败
  - `./macOS/scripts/build-app.sh`：失败（同上）
  - `codesign --verify --deep --strict outputs/DisplaySwitcher.app`：失败（输出：resource fork, Finder information, or similar detritus not allowed）
- 原因：当前环境缺少可运行的 Xcode 完整套件；`swift` 版本与本机 SDK 也存在不匹配告警，无法做可靠本地编译验证。

## 尚需验证

- 待 Xcode 完整环境补齐后继续执行：
  - `xcodebuild -project macOS/DisplaySwitcher.xcodeproj -scheme DisplaySwitcher -configuration Debug build`
  - `xcodebuild -project macOS/DisplaySwitcher.xcodeproj -scheme DisplaySwitcher -configuration Release build`
  - 相关 XCTest（含 17 条消息向量和 15 条状态机向量）
  - `./macOS/scripts/build-app.sh`
  - `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app`
- 实机验证（未执行）：
  - 状态机与协议行为在真实 USB/显示器与网络环境下是否完全一致

## 对 Windows 端的影响

- 本次只改 `macOS/` 与本文件，未改 `Windows/`、`specs/`、`contracts/`、`coordination/` 和公共协议。
- Windows 端在完成其对应分支验证后，将由协调层按 DS-001 向量进行交叉比对。
