# macOS 交接记录

## 当前任务

- 日期：2026-08-29
- 功能：DS-008 / macOS 发布前 UDP 固定源端口修复
- 共享基线：`codex/coord-ds-008-usb-local-switch@aad145d0e3962c16d05442d34e6b07a8553b21cf`
- 基线确认：开始前已 fetch；基线包含 PR #41 (`4da002d`) 和 PR #42 (`aad145d`)
- 分支：`codex/macos-ds-008-fixed-source-port`
- 实现提交：`bc37d2e214eff1cd514d82878c78e48b8d939966`
- PR：待创建，base 为 `codex/coord-ds-008-usb-local-switch`

## 根因

- Windows `UdpPeer::Start` 把 UDP socket 绑定到本机 `listenPort`，`SendRaw` 复用这个 socket，因此主动数据报的源端口稳定为本机监听端口。
- Windows 首次未绑定 `status_probe` 只接受 `SourceMatches` 同时匹配配置 host 和 `profile.peerPort` 的来源；其自动测试也按来源地址和来源端口匹配首次探测。
- macOS 原 `PeerTransport.send` 每次创建未指定本地 endpoint 的 `NWConnection`，系统会分配临时源端口。目标端口虽正确使用 `peerPort`，Windows 仍会在首次 endpoint 绑定前因来源端口不匹配拒绝探测，界面最终表现为等待心跳或无响应。

## 完成内容

- `PeerTransport` 的监听和主动 UDP 连接都启用本地 endpoint 复用；主动连接使用 `requiredLocalEndpoint` 绑定当前 `listenPort`，目标仍使用所选配置的 `peerPort`。
- 所有主动 `send` 共用同一路径，因此覆盖 `status_probe`、`wake_display`、`handover_request`、状态机重发及其他主动消息；没有新增第二个用户可配置端口。
- 主动连接按 host/目标端口复用，连接 ready 前的数据报排队；同一主动连接持续接收对端响应，避免固定源端口后回包落到无人接收的 socket。
- `start` 同端口重复调用不创建第二个监听；端口重配、`stop`、监听失败、连接失败和发送失败会释放相应监听/连接资源，退出时显式停止网络传输。
- 收到数据报后的回复仍使用该数据报所属连接，没有修改 eventID、HMAC、endpoint 路由、消息缓存或重放保护。
- 通过可注入 listener/connection factory 新增 5 项纯传输测试，覆盖三类主动请求的源/目标端口、同端口重复 start、端口重配、stop、发送失败重建和原连接回复。

## 本机验证

- 生产 `PeerTransport.swift` 使用本机 macOS 26.5 SDK完成 Swift 类型检查；新增测试文件通过 Swift 语法解析。
- 仅使用 `127.0.0.1` 的 UDP 运行验证通过：接收端观测到主动请求源端口等于配置 `listenPort`、目标端口等于 loopback 接收端口，且响应由主动连接收到。
- `contracts/protocol-v2/validate.py`：4 个 schema、1 条 NFC、4 条认证、20 条消息和 6 条状态机向量通过。
- `contracts/usb-switch-v1/validate.py`：USB-001 至 USB-016 全部通过，配置 schemaVersion 5。
- `plutil -lint macOS/DisplaySwitcher.xcodeproj/project.pbxproj`、`git diff --check` 和提交内容审查通过。
- 本机只有 Command Line Tools，没有完整 Xcode；未运行 XCTest、Debug/Release Xcode 构建、`build-app.sh` 或 codesign。按协调策略，不单独触发 workflow_dispatch 或中间云端 CI；这些项目由协调端最终 main PR 的 macOS CI 一次完成。

## 发布产物

- 本机未生成新的忽略发布产物，因为没有完整 Xcode。
- 协调端可从本分支重建：`./macOS/scripts/build-app.sh`。
- 预期忽略产物路径：`macOS/outputs/DisplaySwitcher.app` 和 `macOS/outputs/DisplaySwitcher-macOS-$(uname -m).zip`。
- 最终 main PR 的 macOS CI 应上传 `DisplaySwitcher-macOS-${runner.arch}-unsigned` artifact。

## 尚未执行

- 新增 5 项 `PeerTransportTests` 及现有完整 XCTest 尚待最终 main PR 的 macOS CI 执行。
- Debug、Release、正式打包与严格 codesign 尚待最终 main PR 的 macOS CI 执行。
- 未做真实 macOS/Windows 双机首次探测、心跳、`wake_display`、手动交接和重发验证。
- 未做真实 USB、DDC、显示器唤醒、输入源切换或 GUI 验证。

## 安全与边界

- 仅修改 `macOS/` 和 `handoffs/macos.md`。
- 未修改 Windows、`PROTOCOL.md`、contracts、coordination、specs、根 README、`AGENTS.md`、GitHub Actions、版本号、tag 或 Release。
- 未启动 App，未访问局域网，未执行真实 USB、DDC、显示器唤醒或输入源切换。
- 未记录配对码、凭据、真实 IP、真实 endpoint、USB/显示器标识或个人路径。
- `macOS/.build/` 和 `macOS/outputs/` 保持 Git 忽略。

## 协调端下一步

1. 审查并合并本 PR 到 `codex/coord-ds-008-usb-local-switch`。
2. 从协调分支创建最终 main PR，让 macOS CI 一次运行完整 XCTest、Debug、Release、打包、严格验签和 artifact 上传。
3. CI 通过后再做授权的 macOS/Windows 双机首次探测，确认 Windows 看到的来源端口等于 Mac `listenPort`，并验证心跳、协同唤醒和手动交接。
