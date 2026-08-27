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
- 新增状态机/消息向量测试（不接真实网络/USB/DDC）：
  - `macOS/Tests/DisplaySwitcherTests/HandoffMessageVectorTests.swift`（17 条）
  - `macOS/Tests/DisplaySwitcherTests/HandoffStateMachineVectorTests.swift`（15 条）
- `macOS/DisplaySwitcher.xcodeproj` 已加入新测试源文件；核心源码与测试目标可在 Xcode 中执行。

## 自动验证

- 只读环境检查：
  - `swift --version` 成功（Swift 6.4）
  - `xcodebuild -version`：当前系统 `active developer directory` 为 `CommandLineTools`，不能运行 `xcodebuild`/`build-app.sh`。
  - `xcrun --sdk macosx --show-sdk-path` 可取到 `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`
- **未能运行自动验证**（受环境限制）：
  - `xcodebuild -project DisplaySwitcher.xcodeproj -scheme DisplaySwitcher -configuration Debug build`
  - `xcodebuild -project DisplaySwitcher.xcodeproj -scheme DisplaySwitcher -configuration Release build`
  - `./scripts/build-app.sh`
  - `codesign --verify --deep --strict`
  - 向量测试（Debug/Release 下的 XCTest）
- 原因：当前终端 `xcode-select` 未指向 Xcode（`xcodebuild` 依赖）。

## 尚需验证

- 在有 Xcode 的环境中继续执行：
  - `xcodebuild` Debug/Release 构建
  - 相关 XCTest（含 17 条消息向量和 15 条状态机向量）
  - `./scripts/build-app.sh` 与 `codesign --verify --deep --strict`
- 实机验证（未执行）：
  - 状态机与协议行为在真实 USB/显示器与网络环境下是否完全一致

## 对 Windows 端的影响

- 本次只改 `macOS/` 与本文件，未改 `Windows/`、`specs/`、`contracts/`、`coordination/` 和公共协议。
- Windows 端在完成其对应分支验证后，将由协调层按 DS-001 向量进行交叉比对。
