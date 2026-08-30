# Windows 交接记录

## 当前任务

- 日期：2026-08-30
- 功能：W-005 文档与诊断安全、W-203 诊断页面与脱敏日志
- 分支：`codex/windows-w005-w203-diagnostics`
- 堆叠基线：PR [#54](https://github.com/maizihk/DisplaySwitch/pull/54) head `12598853571ea601b838e4748f93d52a79fdee00`
- PR base：`codex/windows-ds-013-display-binding`；保留 PR #54 及其 DS-011/DS-012/DS-013 堆叠历史，不合并或 retarget 到 main
- 实现提交：完成本地验证后回填
- CI：等待本任务 PR；本节所列结果均为 Windows 本机验证

## 根因与设计

- 原诊断日志直接接受自由文本，安全性依赖每个调用方自律；现在写盘前统一解析为安全事件名，并只允许预定义的数值字段，未知字段一律删除并标记已脱敏。
- 原显示器最后操作状态只存在于 WinUI `TextBlock`，设置页重建或重新枚举会重置为 idle。现在会话内状态按稳定逻辑显示器 ID、当前不透明物理绑定和 topology generation 关联，不保存句柄：相同绑定重枚举保留状态，绑定或 generation 变化只废弃对应状态，歧义安全拒绝。
- 新增“诊断”标签。报告只投影配置快照、缓存的公开应用元数据和已有内存状态；协同配置、显示器、会话及操作使用 `P1`、`D1`、`S1`、`O1` 临时编号。
- 预览不包含配置名称、地址、配对密码、endpoint、认证/消息标识、用户路径、显示器与 USB 原始身份或友好名称。匿名映射不写配置、不落盘、不跨端同步。
- “刷新预览”不会调用网络检测、USB 枚举/交接、DDC 枚举/读写、唤醒或输入源切换；“复制诊断”仅复制当前可见文本，不刷新也没有第二条导出路径。

## 修改范围

- `Windows/DisplaySwitcher.Native/DiagnosticReport.*`：纯诊断快照、严格输出格式、预览模型和显示器操作状态生命周期。
- `Windows/DisplaySwitcher.Native/Diagnostics.*`：日志白名单清洗与有界会话安全事件快照。
- `Windows/DisplaySwitcher.Native/Controller.*`、`SystemActions.*`：从现有内存状态投影诊断，并在既有 DDC/输入源完成点记录匿名操作结果。
- `Windows/DisplaySwitcher.Native/SettingsWindow.*`：新增只读诊断页、刷新预览和同文复制；显示器卡片复用会话内最后操作状态。
- `Windows/DisplaySwitcher.Tests/Tests.cpp` 与工程文件：隐私注入、零副作用、同文复制、D1/D2/D3 状态、重枚举、generation、重排和歧义测试。
- `Windows/README.md`、`Windows/DEVELOPMENT_CHECKLIST.md` 与本交接文件。

## 自动验证

- `Windows/build-windows.ps1` x64 Release 已编译原生应用、绿色版启动器与测试，并真实运行完整 `DisplaySwitcher.Tests.exe`；共通过 227 项检查。
- W-005/W-203 测试向报告注入私网地址、密码、endpoint、合成 Windows 路径、显示器/USB 标识和设备名称，确认全部不存在，同时保留安全状态和匿名编号。
- 刷新与复制测试确认文本逐字一致；模拟网络、USB、唤醒、DDC 枚举/读写和输入源调用均为 0。
- D1、D2、D3 依次成功、相同绑定重枚举、同型号/重排、绑定及 generation 变化和歧义隔离均通过。
- 既有 DS-004、DS-005、DS-007、DS-008、DS-009、DS-012、DS-013 回归通过；v2 公共向量为 1 条规范化、4 条认证、20 条消息、6 条状态机；USB-001 至 USB-016 全部通过。
- dist 绿色版为 framework-dependent，完整目录 1,815,493 字节（1.73 MiB）。未签名测试 ZIP 为 `DisplaySwitch-Windows-x64-unsigned-framework-dependent-W005-W203.zip`，846,172 字节，SHA-256 `3FB47D393130A3846AA863A498A7DB0AD5B41C08EDED8A8483071E6527F3AD2B`。
- Release 编译启用基于 MSBuild 变量的路径映射；对 dist 扫描确认没有配置/日志、测试秘密、当前 Windows 用户目录或仓库绝对路径。
- NuGet 漏洞索引在受限网络下产生 NU1900 警告；缓存依赖还原、编译、链接、测试和产物检查均成功。

## 尚需实机验证

- 诊断标签在常见 DPI/深浅色下的布局、只读文本选择、滚动、刷新和剪贴板行为。
- 多台真实显示器依次进行 DDC 操作后，页面重建、刷新、休眠恢复、热插拔和接口切换时状态显示是否符合预期。
- 本任务未启动正式应用，未执行真实局域网、USB、DDC、唤醒、输入源或系统设置操作。

## 范围

- 只修改 `Windows/` 和 `handoffs/windows.md`；未修改 macOS、共享协议/提案/合约、GitHub Actions、版本号、tag 或 Release。
- 最终提交、PR、ZIP 和工作区状态将在交付前补齐。
