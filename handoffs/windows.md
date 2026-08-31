# Windows 交接记录

## 当前任务

- 日期：2026-08-31
- 功能：Windows 按需详细诊断记录（延续 W-005 / W-203）
- 分支：`codex/windows-detailed-diagnostics`
- 堆叠基线：`codex/windows-w005-w203-diagnostics@d31eee9`，包含 PR [#60](https://github.com/maizihk/DisplaySwitch/pull/60) 的诊断页面及评审修复；未改动或丢弃其 DS-011/DS-012/DS-013 堆叠历史
- PR base：`codex/windows-w005-w203-diagnostics`，使本 PR 只展示按需记录增量
- 实现提交：交付提交将在完成本文件与最终检查后记录
- PR：待创建；保持开放等待实机 GUI 验收
- CI：本节当前结果均为 Windows 本机验证；创建堆叠 PR 后再记录 GitHub 托管检查

## 根因与设计

- 原诊断日志直接接受自由文本，安全性依赖每个调用方自律；现在写盘前统一解析为安全事件名，并只允许预定义的数值字段，未知字段一律删除并标记已脱敏。
- 原显示器最后操作状态只存在于 WinUI `TextBlock`，设置页重建或重新枚举会重置为 idle。现在会话内状态按稳定逻辑显示器 ID、当前不透明物理绑定和 topology generation 关联，不保存句柄：相同绑定重枚举保留状态，绑定或 generation 变化只废弃对应状态，歧义安全拒绝。
- 新增“诊断”标签。报告只投影配置快照、缓存的公开应用元数据和已有内存状态；协同配置、显示器、会话及操作使用 `P1`、`D1`、`S1`、`O1` 临时编号。
- 预览不包含配置名称、地址、配对密码、endpoint、认证/消息标识、用户路径、显示器与 USB 原始身份或友好名称。匿名映射不写配置、不落盘、不跨端同步。
- “刷新预览”不会调用网络检测、USB 枚举/交接、DDC 枚举/读写、唤醒或输入源切换；“复制诊断”仅复制当前可见文本，不刷新也没有第二条导出路径。
- 评审发现 `DisplayOperationTracker::RecordBatch` 曾逐项覆盖同一显示器状态，导致亮度失败后对比度/音量成功可能误报整批成功；现在先按目标显示器聚合，只有全部请求项成功且可信才记录成功，失败、不可信和歧义均安全保留。
- 在线运行态仍按 6 秒窗口从 `v2PeerLastSeenMs_` 失效，但诊断改用独立的会话跟踪器保存最后合法心跳事实，因此会稳定显示 `Never -> Recent -> Expired`；profile/endpoint/地址/端口/认证身份变化、配置删除、安全会话或应用会话重置会清除旧状态，报告不含身份和原始时间。
- 诊断预览正式边界改为 `IDiagnosticSnapshotProvider`：WinUI 预览模型只持有 `ReadSnapshot()`，不能访问 UDP、USB、wake、DDC 或 input-source 接口；刷新调用注入 provider，复制只返回当前可见文本。
- 原详细事件入口无条件写入会话内存和本机 `diagnostic.log`，即使用户没有排障需求也会在启动时创建记录。现在 schema v5 增加可选的本机 `DetailedDiagnosticRecording` 设置，缺失时严格默认为关闭，不修改 schemaVersion。
- “常规”页新增即时保存的“详细诊断记录”。所有 DDC/输入源、USB 与协同网络详细入口最终汇入同一锁内硬门控；关闭时既不保留内存事件也不创建日志文件，任意方向切换都会清空旧内存和旧文件。
- 诊断预览关闭详细记录时仍显示配置、能力、连接和 DDC 基本状态，并明确输出 `detailed-recording=false`；显示器页不再投影后端原始 message，只显示读取/写入成功、失败或匹配歧义。

## 修改范围

- `Windows/DisplaySwitcher.Native/DiagnosticReport.*`：纯诊断快照、严格输出格式、预览模型和显示器操作状态生命周期。
- `Windows/DisplaySwitcher.Native/Diagnostics.*`：日志白名单清洗与有界会话安全事件快照。
- `Windows/DisplaySwitcher.Native/AppConfig.*`、`Controller.cpp`：持久化默认关闭的本机开关，在启动及配置成功应用后同步记录门控。
- `Windows/DisplaySwitcher.Native/Controller.*`、`SystemActions.*`：从现有内存状态投影诊断，并在既有 DDC/输入源完成点记录匿名操作结果。
- `Windows/DisplaySwitcher.Native/SettingsWindow.*`：新增只读诊断页、刷新预览和同文复制；显示器卡片复用会话内最后操作状态。
- `Windows/DisplaySwitcher.Tests/Tests.cpp`：增加默认关闭、旧 v5 缺失字段、持久化、四类入口零记录、开启后记录、双向切换清空、关闭预览不泄漏和简明 DDC 文案测试；保留既有隐私及状态生命周期回归。
- `Windows/README.md`、`Windows/DEVELOPMENT_CHECKLIST.md` 与本交接文件。

## 自动验证

- `Windows/build-windows.ps1` x64 Release 已编译原生应用、绿色版启动器与测试，并真实运行完整 `DisplaySwitcher.Tests.exe`；共通过 246 项检查。
- 新测试使用临时配置与临时日志路径，证明新安装和缺字段旧配置默认关闭、设置可跨重启回读、关闭时 DDC/输入源/USB/协同网络入口零内存及零文件记录、开启后仅记录后续事件、任意切换清空旧轨迹。
- 关闭状态的诊断投影即使收到人为注入的旧 sessions 也强制显示 0 且不输出事件；注入含 HANDLE、HRESULT、attempt、checksum 与 transport 的 DDC 错误后，用户界面投影仍只有简明“读取失败”。
- W-005/W-203 测试向报告注入私网地址、密码、endpoint、合成 Windows 路径、显示器/USB 标识和设备名称，确认全部不存在，同时保留安全状态和匿名编号。
- 可注入 snapshot provider 测试确认刷新只调用 `ReadSnapshot()`，复制不再次读取且文本逐字一致；该纯投影边界不暴露网络、USB、唤醒、DDC 枚举/读写或输入源接口。
- DDC 批处理测试覆盖亮度失败后对比度/音量成功、不可信估计值和歧义优先级，最终状态分别保持失败/失败/歧义，不再误报 `读取：成功`。
- 模拟时钟覆盖心跳 `Never -> Recent -> Expired`，并验证同一身份重新应用保留 Expired，认证身份/endpoint 变化、配置删除和会话重置安全清除。
- D1、D2、D3 依次成功、相同绑定重枚举、同型号/重排、绑定及 generation 变化和歧义隔离均通过。
- 既有 DS-004、DS-005、DS-007、DS-008、DS-009、DS-012、DS-013 回归通过；v2 公共向量为 1 条规范化、4 条认证、20 条消息、6 条状态机；USB-001 至 USB-016 全部通过。
- dist 绿色版为 framework-dependent，构建脚本报告 1.74 MiB。未签名测试 ZIP 为 `Windows/outputs/DisplaySwitch-Windows-x64-unsigned-framework-dependent-detailed-diagnostics.zip`，850,734 字节，SHA-256 `05490C752161DF8FB7288F34823FE31D551014F38DB8EEA382B01635B69D7DD9`。
- Release 编译启用基于 MSBuild 变量的路径映射；对 dist 扫描确认没有配置/日志、测试秘密、当前 Windows 用户目录或仓库绝对路径。
- NuGet 漏洞索引在受限网络下产生 NU1900 警告；缓存依赖还原、编译、链接、测试和产物检查均成功。

## 尚需实机验证

- 诊断标签在常见 DPI/深浅色下的布局、只读文本选择、滚动、刷新和剪贴板行为。
- “常规”页开关的即时保存、重启保持、双向切换后预览内容和旧日志清理需要实机 GUI 验证。
- 多台真实显示器依次进行 DDC 操作后，页面重建、刷新、休眠恢复、热插拔和接口切换时状态显示是否符合预期。
- 本任务未启动正式应用，未执行真实局域网、USB、DDC、唤醒、输入源或系统设置操作。

## 范围

- 只修改 `Windows/` 和 `handoffs/windows.md`；未修改 macOS、共享协议/提案/合约、GitHub Actions、版本号、tag 或 Release。
- 最终提交、PR 和工作区状态将在交付前补齐。
