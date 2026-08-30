# Windows 交接记录

## 当前任务

- 日期：2026-08-30
- 功能：DS-013 / Windows W-013 动态显示器物理绑定、去重与句柄失效修复
- 分支：`codex/windows-ds-013-display-binding`
- 父分支：`codex/windows-ds-011-native-ddc-only-windows-host`
- 承接基线：`8451110a579b8ea79775ec1dc97492ee995121d3`
- 实现提交：待完成提交后回填
- PR：待创建，base 为上述父分支
- CI：只执行 Windows 本机测试和构建，不主动触发额外云端 CI

## 根因与修复

- 旧后端把同一弱接口标识下的多个 `PHYSICAL_MONITOR` 句柄依次试写，接受第一个成功结果；这不能证明已操作用户选择的显示器。原身份又主要依赖接口/GDI 信息，在热插拔、接口切换、同型号和枚举重排时存在误绑定风险。
- 建立“逻辑显示器→当前唯一物理 DDC 句柄”两层模型。枚举基于 `QueryDisplayConfig` / `DisplayConfigGetDeviceInfo` 的 adapter LUID + target ID、monitor device path，并结合 SetupAPI 当前接口、Container ID 和 EDID。
- 持久化身份是本机 SHA-256 不透明标识。FriendlyName、品牌、型号和枚举顺序只用于显示；原硬件信息不写日志、handoff 或 Git。
- 全局一对一解析只允许唯一强身份自动绑定。同一 target 仍只显示一项；多句柄、身份缺失/重复或迁移多候选标记歧义/需重新确认，亮度、对比度、音量和输入源保持零 DDC。
- 引入 topology generation；`WM_DISPLAYCHANGE`、主动刷新、枚举差异和句柄失效会释放旧句柄、清空解析缓存并递增 generation。读写途中变化时，即使底层返回成功也丢弃结果并停止剩余批量操作。
- 显示器断开或休眠只标记离线，保留名称、DDC/托盘开关、输入源、USB 映射和协同映射。旧 GDI/接口标识只在唯一强候选时迁移。

## 修改文件

- `Windows/DisplaySwitcher.Native/`：`DisplayModel`、`DdcBackends`、`DdcControl`、`SystemActions`、`Controller`、`TrayIcon`、`SettingsWindow` 及工程链接设置。
- `Windows/DisplaySwitcher.Tests/`：模拟拓扑/DDC、generation、迁移和映射保留回归。
- `Windows/README.md`、`Windows/DEVELOPMENT_CHECKLIST.md`、`handoffs/windows.md`。

## 自动验证

- `Windows/build-windows.ps1` 在 Windows 主机完成 x64 Release 构建，并真实运行 `DisplaySwitcher.Tests.exe`。
- DS-013 模拟测试覆盖 2 target/4 handle 只显示 2 项、歧义零 DDC、同型号 serial=0 不猜测、唯一强身份一对一、重排/接口切换、部分/空枚举、休眠恢复、generation 变化、迟到成功丢弃、迁移唯一/多候选和断开映射保留。
- DS-004、DS-007、DS-008、DS-009、DS-011、DS-012 回归通过；v2 通过 1 条 NFC、4 条认证、20 条消息和 6 条状态机向量；USB-001 至 USB-016 全部通过。
- 产物为 `Windows/dist/DisplaySwitch.exe` 及完整 `runtime/`，目录 1.66 MiB，低于 20 MiB。
- 只有 NuGet 漏洞索引无法联网的 NU1900 警告；已缓存依赖的还原、编译、链接、测试和产物检查均成功。

## 尚需实机验证

- 实际两台物理显示器在设置页和托盘中只显示两项，同型号不串台。
- 热插拔、休眠恢复及 HDMI/DP/USB-C 接口切换后仍解析到正确目标。
- 亮度、对比度、音量和输入源四类 DDC 操作稳定且无误操作。
- 本任务未启动正式程序，未执行真实 DDC、USB、网络、显示器唤醒、输入源或系统设置操作。

## 范围与工作区

- 仅修改 `Windows/` 和本文件；未修改旧 C# 参照、macOS、共享协议/提案/合约、GitHub Actions、版本号、tag 或 Release。
- 最终提交、PR 和 `git status` 待 push 后回填。
