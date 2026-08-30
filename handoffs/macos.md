# macOS 交接记录

## 当前任务

- 日期：2026-08-30
- 功能：DS-011 / macOS 原生 DDC 单后端清理
- 基线：`e6655b524cd8c012fcfd1cab2eb465494c96788e`
- 分支：`codex/macos-ds-011-native-ddc-only`
- 实现提交：本提交，最终完整 SHA 以分支 HEAD 和交付报告为准
- PR / CI：按任务边界不创建 PR、不触发云端 CI

## DS-011 原因与决策

- 运行时虽然已只选择原生后端，仓库仍保留完整的外部进程实现、路径检测、历史回退路由、配置字段和设置选择器；这些死路径会让公开能力边界与代码事实不一致。
- DS-011 将路由收敛为一个注入式 `DDCBackend`，正式 App 只注入 `NativeDDCBackend`。原生不可用或读写失败直接返回原生错误，不尝试替代后端。
- VCP/cache 属性改成平台无关名称，但继续生成完全相同的 `LastValue.stable.*` 键，避免清空已有可信缓存。
- schemaVersion 保持 5；旧后端选择字段由 Codable 作为未知字段忽略，后续编码不再保存。
- 根 `README.md` 仍有历史回退描述，但本平台任务禁止修改共享文件；需由协调端在合并阶段统一校准。

## DS-011 实现

- 删除外部 DDC 后端、`Process`/`Pipe` 调用、Homebrew/可执行路径探测、专属错误和显示器列表文本解析。
- `DDCBackendRouter` 改为单后端路由，保留统一枚举、读写、取消、诊断、缓存和安全闸门接口。
- 删除配置模型、启动和重载路径中的后端选择；显示器页不再展示无可选项的“控制后端”说明，仅保留检测/刷新入口，Intel Mac 在原生后端不可用时显示不支持。
- 显示器控制标题与“检测/刷新”、显示器名称与“读取 DDC 参数”分别采用同一行左右布局；读取结果移到下一行全宽展示，控制逻辑和诊断语义不变。
- 本机配置检查弹窗将内部校验枚举替换为可执行的中文说明；只有原生后端确实不可用时才附加后端状态。
- 已启用配置在逐项编辑期间若暂时不完整，会保存当前有效输入并自动停用；不再因整份完整性校验回滚刚输入的映射。
- 测试覆盖原生成功、不可用、读写失败显式返回、旧配置字段不再写回，以及旧可信缓存键继续读取。

## DS-011 自动验证

- 相关 XCTest：54/54（DDC 37 项、配置 17 项）。
- 完整 XCTest：122/122；现有输入源切换、队列、USB、v2 网络和安全闸门模拟回归继续通过。
- Debug、Release、`./macOS/scripts/build-app.sh` 与 `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app` 均通过。
- 使用本机选定的 Xcode 27 Beta 6；命令只记录通用的 `$DEVELOPER_DIR` 表达，不记录本机绝对路径。
- 未执行真实 DDC、输入源切换、USB、网络或唤醒，未修改系统权限、签名信任或防火墙。

## DS-011 尚需用户实机验证

1. Apple Silicon 原生显示器枚举与稳定名称保持正确。
2. 设置页显式读取，以及亮度、对比度、音量写入保持现有行为。
3. USB、手动和协同入口的多显示器输入源切换不回归。
4. Intel Mac 只显示原生 DDC 不支持，不执行外部进程。

## DS-011 修改范围

- `macOS/Sources/DisplaySwitcher/DDCBackend.swift`
- `macOS/Sources/DisplaySwitcher/DDCController.swift`
- `macOS/Sources/DisplaySwitcher/DisplayConfigurationStore.swift`
- `macOS/Sources/DisplaySwitcher/SettingsWindowController.swift`
- `macOS/Sources/DisplaySwitcher/main.swift`
- `macOS/Tests/DisplaySwitcherTests/DDCBackendTests.swift`
- `macOS/Tests/DisplaySwitcherTests/DisplayConfigurationStoreTests.swift`
- `macOS/Tests/DisplaySwitcherTests/PeerProtocolV2Tests.swift`
- `macOS/Tests/DisplaySwitcherTests/PublicPresentationModelsTests.swift`
- `macOS/DEVELOPMENT_CHECKLIST.md`
- `handoffs/macos.md`

## 上一任务：DS-010 本地网络权限引导

- 日期：2026-08-30
- 功能：DS-010 / macOS 本地网络权限引导
- 基线：`main@5e382569466139193cab0828865af6c3c91d4c49`
- 分支：`codex/macos-ds-010-local-network-permission-ux`
- 实现提交：本提交，最终完整 SHA 以分支 HEAD 和交付报告为准
- PR / CI：按任务边界不创建 PR、不触发云端 CI

## DS-010 原因与决策

- macOS 的本地网络权限由系统管理，原界面没有入口或保守状态说明，用户无法区分权限、地址、对端、防火墙和认证问题。
- 当前直接 BSD UDP socket 没有可靠公开信号可单独证明本地网络 TCC 被拒绝。超时、零响应、发送失败、认证失败和普通网络错误一律显示一般连接失败。
- “系统明确拒绝”只接受显式系统拒绝证据；本轮不改 UDP 架构，不增加 Bonjour、组播或旁路探测。

## DS-010 实现

- 协同页顶部新增紧凑的“本地网络权限”模块，说明用途、当前状态和“检测并申请权限”入口；不新增标签或 App 内权限开关。
- 入口复用现有协同配置校验、绑定源端口、v2 状态探测、HMAC 和响应验证路径；检测仍为零 USB、DDC、唤醒和输入源切换副作用。
- 状态限制为“未检测”“协同连接正常”“系统明确拒绝”“连接失败，请检查权限、地址和防火墙”。明确拒绝时保留“系统设置 → 隐私与安全性 → 本地网络”文字路径。
- 更新 `NSLocalNetworkUsageDescription`，说明连接检测、协同唤醒和用户配置的显示器切换，不暗示同步原始 USB 或硬件标识。

## DS-010 自动验证

- 相关 `PublicPresentationModelsTests`：11/11，通过四状态、模糊错误不误报、模拟网络入口和零硬件副作用。
- 完整 XCTest：118/118；既有 v2、固定源端口、重放保护、USB 和 DDC 模拟回归继续通过。
- Debug、Release、`./macOS/scripts/build-app.sh` 和严格 codesign 验证通过，保持 ad-hoc 签名。
- 使用本机选定的 Xcode 27 Beta 6；命令仅使用通用的 `$DEVELOPER_DIR` 表达，不记录本机绝对路径。
- 未访问真实局域网，未弹授权框，未执行真实 USB、DDC、唤醒或输入源切换，未修改 TCC 或防火墙。

## DS-010 尚需用户实机验证

1. macOS 15 及以上首次点击“检测并申请权限”是否出现系统本地网络授权框。
2. 分别选择允许、拒绝，并在“系统设置 → 隐私与安全性 → 本地网络”重新允许后的恢复行为。
3. 错误地址、对端未运行、现有防火墙阻断和错误配对码只显示一般连接失败，不显示“系统明确拒绝”。
4. 模块在浅色/深色模式及紧凑窗口中的真实 AppKit 布局。

## DS-010 修改范围

- `macOS/Resources/Info.plist`
- `macOS/Sources/DisplaySwitcher/PublicPresentationModels.swift`
- `macOS/Sources/DisplaySwitcher/SettingsWindowController.swift`
- `macOS/Tests/DisplaySwitcherTests/PublicPresentationModelsTests.swift`
- `macOS/DEVELOPMENT_CHECKLIST.md`
- `handoffs/macos.md`

## 上一任务：DS-009 协同检测诊断

- 日期：2026-08-29
- 功能：DS-009 / macOS 非对称协同检测第一阶段诊断
- 分支：`codex/macos-ds-009-collaboration-diagnostics`
- 堆叠基线：`codex/macos-ds-009-hardware-acceptance@85c975b`
- 本轮实现提交：`21d24a3`
- 前置验收记录：PR #49 保持开放
- 本轮 PR：#50，目标为 `codex/macos-ds-009-hardware-acceptance`，保持开放

## 审计结论

- 从设置页检测到 UI 结果的链路为：`beginPeerCapabilityInspection` → 同一 BSD UDP socket 同步绑定本机监听端口 → `sendto` → `recvfrom` 携带来源地址/端口 → pending eventID 匹配 → v2 endpoint/HMAC/时间验证 → 设置页状态。
- 现有实现没有证据表明 1 秒超时是根因；本轮保持 1 秒不变。
- 已确认的首要问题是可观测性缺失：监听、发送和接收错误只进入系统日志，event/endpoint/HMAC/时间窗等拒绝统一折叠成“无响应”，无法判断非对称故障发生在哪一层。
- 另确认两项协议路径缺口：检测响应此前绕过 nonce 重放分类；超时后的迟到响应会进入普通 v2 路径并可能刷新在线状态。本轮分别改为明确拒绝 `nonce-reuse`/重复响应和 `late-response`。
- 未修改 PROTOCOL、Windows、检测超时、DDC、USB、唤醒或显示器行为；非对称故障的最终根因仍需用户双向诊断日志判定。

## 实现

- `PeerTransport.swift`：监听启动和发送返回结构化成功/错误类别；接收回调携带来源 endpoint；仍由同一个已绑定 socket 收发。
- `PeerProtocolV2.swift`：响应校验返回精确拒绝原因；增加脱敏诊断、event 生命周期、来源端口和 envelope 投影模型。
- `main.swift`：每次检测记录监听、发送、收包、校验、重放、迟到响应和超时；菜单新增“复制协同检测诊断”。
- `PeerTransportTests.swift`、`PeerProtocolV2Tests.swift`：模拟监听绑定失败、同一 socket 发送、正确响应、错误来源端口、event/endpoint/HMAC/时间窗错误、迟到响应、零收包超时和脱敏输出。
- `macOS/DEVELOPMENT_CHECKLIST.md`：记录该诊断阶段的自动验证状态。

## 自动验证

- 相关 XCTest：24/24。
- 完整 XCTest：115/115；全部使用模拟 socket、时间和协议消息。
- Debug 测试构建、Release `build-app.sh` 构建及严格 codesign 验证通过。
- 测试包实际解压后严格验签通过，ZIP 不含 `__MACOSX` 或 AppleDouble 条目。
- 使用本机选定的 Xcode 27 Beta 6；handoff 不记录个人绝对路径。
- 未执行真实 UDP、USB、DDC、唤醒或输入源切换，未修改防火墙。

## 诊断测试包

- `macOS/outputs/DisplaySwitcher-DS-009-collaboration-diagnostic-v2-macOS-test.zip`
- SHA-256：`0e98ea8a83c6f00814d26c50668fd2d0c0e42f889e1224240a20b9038f266298`
- 大小：648709 bytes

## 用户最短验证步骤

1. 两端保持现有配置和防火墙不变，先在 Windows 端对 macOS 点击一次“检测”。
2. 再在 macOS 协同页对同一 Windows 配置点击一次“检测”，等待结果。
3. 从 macOS 菜单选择“复制协同检测诊断”，将文本发回；导出不含 IP 原文、配对码、authTag 或 endpoint 原值。

## 待验与边界

- 根据日志区分：listener 未启动、sendto 失败、完全零收包、来源端口不符、event 不符、endpoint/HMAC/时间窗/重放拒绝或迟到响应。
- 本任务没有继续处理 C2C、DDC 原生读取或其他协同状态机行为。
- 多显示器同时切换已由用户实机确认通过；该结论与本次网络诊断分开记录。
