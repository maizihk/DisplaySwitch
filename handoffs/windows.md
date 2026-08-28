# Windows 交接记录

## 当前任务

- 日期：2026-08-29
- 功能：DS-008 / Windows 本机 USB 双向切换
- 分支：`codex/windows-ds-008-usb-local-switch`
- PR base：`codex/coord-ds-008-usb-local-switch`
- 共享基线：`35c2d156d2c2259fd604f3e305d0b09e234aec2b`
- 实现提交：`43683d6973e2088ba3e4832a622102cffd081633`
- PR：[#42](https://github.com/maizihk/DisplaySwitch/pull/42)，目标为协调分支，保持开放且禁止自动合并

## 完成内容

- 配置升级为 schema v5。仅对 v4 执行 `.pre-v5.backup` 后的原子迁移，保留常规、显示器、DDC 和协同配置；旧 profile 设备和协同输入映射不会被猜测为新 USB 配置。迁移失败保留原文件及已解析的非 USB 数据，并持久进入安全状态。
- 新增独立 `UsbSwitchCoordinator`，USB presence 不再进入 `V2StateMachine`。一个明确选择的本机 USB 设备由本机引用精确监听；启动、重载和换设备后的第一次观察只建立基线。
- USB 接入变离开时先调度所有合法显示器映射的 DDC 输入源写入，不等待网络；单台失败不阻止其他显示器。离开变接入只请求本机显示器唤醒。
- “联动协同”默认关闭。关闭时 USB 决策不生成网络动作；开启时在 DDC 已调度后向一个完整目标发送一次认证 `wake_display`，网络失败不阻断或回滚 DDC。
- 合法 `wake_display` 只进入共享唤醒合并器，不回复、不写 DDC、不进入手动协同状态；网络唤醒和 USB 接入在 2 秒内最多实际唤醒一次。
- 正式 v2 解析删除 `input_present`，`handover_request` 只接受 `manual`；保留 HMAC、时间窗、nonce、endpoint 和重放保护，以及手动协同的 150 ms 重发和 600 ms 兜底。
- USB 设置页改为一个设备、每显示器目标输入源、USB 开关、联动开关和联动目标配置。原始 VID/PID 与设备路径不显示；同名设备使用中性序号区分。

## 自动验证

- `Windows/build-windows.ps1` x64 Release 完整通过，并真实运行 `DisplaySwitcher.Tests.exe`。
- 原生测试通过 `contracts/usb-switch-v1/` 的 USB-001 至 USB-016。
- v2 回归通过 1 条 NFC、4 条认证、20 条消息和当前 6 条状态机向量。
- 既有 DS-004 C-001 至 C-024、DS-005 检测和 DS-007 Windows 适用回归继续通过。
- `Windows/dist/` 含绿色版入口与完整 `runtime/`，共 1,679,136 字节（1.60 MiB），低于 20 MiB。
- 公共合同 Python 校验脚本因本机未安装 `jsonschema` 未单独运行；同一 JSON 已由原生测试直接读取并逐项比对，未为此安装额外依赖。
- `git diff --check`、范围、敏感信息和构建产物检查通过；未提交 `dist/bin/obj`、本机配置、设备引用或秘密。

## 尚需实机验证

- 设置页一个设备、动态每显示器映射、即时保存/回滚、同名设备选择、窄窗口和高 DPI 交互。
- 真实单设备接入/离开检测及首次基线行为。
- 真实 DDC 输入源切换、单台失败隔离和不同后端兼容性。
- Windows/macOS 双机认证 `wake_display`、网络失败不影响 DDC，以及网络唤醒与 USB 接入的 2 秒合并。
- 本任务未启动新版程序，未执行真实 UDP、USB、DDC、显示器唤醒、输入源切换、防火墙或系统设置操作。

## 范围

- 仅修改 `Windows/` 和本文件。
- 未修改 `macOS/`、`handoffs/macos.md`、`PROTOCOL.md`、`AGENTS.md`、根 README、`coordination/`、`specs/`、`contracts/`、GitHub Actions、版本号、tag 或 Release。
- 不自动合并 PR。
