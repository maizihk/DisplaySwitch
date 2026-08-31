# Windows 交接记录

## 当前状态：DS-021 发布准备事实同步

- 日期：2026-08-31
- 分支：`codex/docs-ds-021-release-readiness`
- 基线：`origin/main@ee6bc5bacc582841351c4b89b23ae842151a21cc`
- 范围：仅公共兼容性、清单与交接文档；不修改 Windows 运行时、协议、schema、合约、workflow、版本或硬件状态。
- 主线集成：PR [#54](https://github.com/maizihk/DisplaySwitch/pull/54) 已合并为 `e14ae6ea6d381dd31097406d7d735f41ec9a2699`，PR [#60](https://github.com/maizihk/DisplaySwitch/pull/60) 已合并为 `3a22c66afdb4838040e2fdc5d122ed955337bb13`。
- CI：Windows runs `33366897393`、`33367712427` 均通过构建、自动测试、dist 验证和 artifact 上传。
- 用户验收：最终 Windows 测试包、诊断页和真实局域网协同检测通过，单击检测不再卡死。
- 剩余边界：休眠恢复、热插拔、接口切换、高 DPI/辅助功能和清单中明确保留的未覆盖 DDC 场景。

## 上一任务：W-005 文档与诊断安全、W-203 诊断页面

- 日期：2026-08-31
- 功能：W-005 文档与诊断安全、W-203 诊断页面与脱敏日志
- 分支：`codex/windows-w005-w203-diagnostics`
- 集成基线：PR [#54](https://github.com/maizihk/DisplaySwitch/pull/54) 已合并为 `e14ae6ea6d381dd31097406d7d735f41ec9a2699`
- 实现提交：`befd20f49cc11d535bcc3dc8bee0036e1a4550e3`
- PR #60 评审修复提交：`9bfa6d546ae6cc3a9a9284bd01b55b7d55b1582e`，补齐 DDC 批量聚合、心跳诊断生命周期和只读 snapshot provider 边界
- PR：[#60](https://github.com/maizihk/DisplaySwitch/pull/60)，已合并为 `3a22c66afdb4838040e2fdc5d122ed955337bb13`
- CI：合并到 main 后的 Windows runs `33366897393`、`33367712427` 均全绿；本节所列 Windows 本机验证同样通过

## 根因与设计

- 原诊断日志直接接受自由文本，安全性依赖每个调用方自律；现在写盘前统一解析为安全事件名，并只允许预定义的数值字段，未知字段一律删除并标记已脱敏。
- 原显示器最后操作状态只存在于 WinUI `TextBlock`，设置页重建或重新枚举会重置为 idle。现在会话内状态按稳定逻辑显示器 ID、当前不透明物理绑定和 topology generation 关联，不保存句柄：相同绑定重枚举保留状态，绑定或 generation 变化只废弃对应状态，歧义安全拒绝。
- 新增“诊断”标签。报告只投影配置快照、缓存的公开应用元数据和已有内存状态；协同配置、显示器、会话及操作使用 `P1`、`D1`、`S1`、`O1` 临时编号。
- 预览不包含配置名称、地址、配对密码、endpoint、认证/消息标识、用户路径、显示器与 USB 原始身份或友好名称。匿名映射不写配置、不落盘、不跨端同步。
- “刷新预览”不会调用网络检测、USB 枚举/交接、DDC 枚举/读写、唤醒或输入源切换；“复制诊断”仅复制当前可见文本，不刷新也没有第二条导出路径。
- 评审发现 `DisplayOperationTracker::RecordBatch` 曾逐项覆盖同一显示器状态，导致亮度失败后对比度/音量成功可能误报整批成功；现在先按目标显示器聚合，只有全部请求项成功且可信才记录成功，失败、不可信和歧义均安全保留。
- 在线运行态仍按 6 秒窗口从 `v2PeerLastSeenMs_` 失效，但诊断改用独立的会话跟踪器保存最后合法心跳事实，因此会稳定显示 `Never -> Recent -> Expired`；profile/endpoint/地址/端口/认证身份变化、配置删除、安全会话或应用会话重置会清除旧状态，报告不含身份和原始时间。
- 诊断预览正式边界改为 `IDiagnosticSnapshotProvider`：WinUI 预览模型只持有 `ReadSnapshot()`，不能访问 UDP、USB、wake、DDC 或 input-source 接口；刷新调用注入 provider，复制只返回当前可见文本。

## 修改范围

- `Windows/DisplaySwitcher.Native/DiagnosticReport.*`：纯诊断快照、严格输出格式、预览模型和显示器操作状态生命周期。
- `Windows/DisplaySwitcher.Native/Diagnostics.*`：日志白名单清洗与有界会话安全事件快照。
- `Windows/DisplaySwitcher.Native/Controller.*`、`SystemActions.*`：从现有内存状态投影诊断，并在既有 DDC/输入源完成点记录匿名操作结果。
- `Windows/DisplaySwitcher.Native/SettingsWindow.*`：新增只读诊断页、刷新预览和同文复制；显示器卡片复用会话内最后操作状态。
- `Windows/DisplaySwitcher.Tests/Tests.cpp` 与工程文件：隐私注入、零副作用、同文复制、D1/D2/D3 状态、重枚举、generation、重排和歧义测试。
- `Windows/README.md`、`Windows/DEVELOPMENT_CHECKLIST.md` 与本交接文件。

## 自动验证

- `Windows/build-windows.ps1` x64 Release 已编译原生应用、绿色版启动器与测试，并真实运行完整 `DisplaySwitcher.Tests.exe`；共通过 236 项检查。
- W-005/W-203 测试向报告注入私网地址、密码、endpoint、合成 Windows 路径、显示器/USB 标识和设备名称，确认全部不存在，同时保留安全状态和匿名编号。
- 可注入 snapshot provider 测试确认刷新只调用 `ReadSnapshot()`，复制不再次读取且文本逐字一致；该纯投影边界不暴露网络、USB、唤醒、DDC 枚举/读写或输入源接口。
- DDC 批处理测试覆盖亮度失败后对比度/音量成功、不可信估计值和歧义优先级，最终状态分别保持失败/失败/歧义，不再误报 `读取：成功`。
- 模拟时钟覆盖心跳 `Never -> Recent -> Expired`，并验证同一身份重新应用保留 Expired，认证身份/endpoint 变化、配置删除和会话重置安全清除。
- D1、D2、D3 依次成功、相同绑定重枚举、同型号/重排、绑定及 generation 变化和歧义隔离均通过。
- 既有 DS-004、DS-005、DS-007、DS-008、DS-009、DS-012、DS-013 回归通过；v2 公共向量为 1 条规范化、4 条认证、20 条消息、6 条状态机；USB-001 至 USB-016 全部通过。
- dist 绿色版为 framework-dependent，完整目录 1,820,613 字节（1.74 MiB）。未签名测试 ZIP 为 `DisplaySwitch-Windows-x64-unsigned-framework-dependent-PR60.zip`，849,286 字节，SHA-256 `C8870D61F791880C7A5792C862A71CF1FC7A36349C33695B2F9C89131111F575`。
- Release 编译启用基于 MSBuild 变量的路径映射；对 dist 扫描确认没有配置/日志、测试秘密、当前 Windows 用户目录或仓库绝对路径。
- NuGet 漏洞索引在受限网络下产生 NU1900 警告；缓存依赖还原、编译、链接、测试和产物检查均成功。

## 实机验收与剩余边界

- 用户已确认最终测试包的诊断标签、刷新/复制、多显示器状态和真实局域网检测可用，单击检测不再导致程序卡死。
- 休眠恢复、热插拔、接口切换和常见高 DPI/辅助功能仍需专项实机验证。
- 本轮文档同步不执行新的网络、USB、DDC、唤醒、输入源或系统设置操作。

## 范围

- 只修改 `Windows/` 和 `handoffs/windows.md`；未修改 macOS、共享协议/提案/合约、GitHub Actions、版本号、tag 或 Release。
- 实现已通过 PR #54、#60 集成到 `main`；正式安装器、商业签名、tag 和 Release 仍不在本任务范围。
