# macOS 交接记录

## 当前任务

- 日期：2026-08-30
- 功能：DS-015 / macOS M-008 IOAVService 拓扑绑定
- 堆叠基线：`codex/macos-ds-014-hdmi-ddc-read-diagnostics@1a15db2`
- 分支：`codex/macos-ds-015-ioav-topology-binding`
- 实现提交：本提交，最终完整 SHA 以分支 HEAD 和交付报告为准
- PR：待创建；不主动触发云端 CI

## DS-015 原因与决策

- 旧枚举在整棵 IORegistry 上递归遍历，并用一个可变的 `currentFramebuffer` 把随后遇到的 `DCPAVServiceProxy` 归给“最近出现”的 framebuffer；结果依赖遍历顺序，接口变化或同型号多屏时可能选错 service。
- CoreDisplay 当前 framebuffer 与 IOAVService 当前 endpoint 是更强的系统拓扑证据。实现只接受当前在线 `IODisplayLocation`，并按 endpoint 一对一匹配；缺失、重复或歧义时明确不可用，不用名称、品牌、顺序或历史缓存猜测。
- Apple Silicon 当前系统拓扑中，内建 HDMI framebuffer `disp0` 对应 service endpoint `dispextE`；数字 `dispextN` 仅对应同名 service。这是平台节点关系，不是显示器型号规则。

## DS-015 实现

- framebuffer 与 DCPAV service 分别独立枚举，再由纯拓扑匹配器关联，删除“相邻节点”推断。
- CoreDisplay `IODisplayLocation` 必须精确命中当前 framebuffer；匹配后的 service metadata 才参与稳定显示器身份匹配。
- 显示器身份匹配改为双向唯一最佳：同型号等分候选、同一 service 被多个显示器竞争时均安全拒绝。
- 每次设置页显式 DDC 读写前重新发现当前 service；重连或接口变化不会继续使用旧 IOAVService、transport 或读取偏好。
- DDC/CI 请求格式、chip/offset、读取安全策略、Set VCP、输入源切换、USB、网络与协议均未改变。

## DS-015 自动验证

- DDC 专项 XCTest：54/54。
- 完整 XCTest：139/139；一条既有 USB 测试产生 QoS 性能提示，测试通过。
- `./macOS/scripts/build-app.sh` Release 构建、打包及 `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app` 通过。
- 自动测试覆盖 M4 `disp0 -> dispextE`、数字 `dispextN`、枚举反序、同型号歧义、重复/未知 endpoint、安全拒绝以及接口变化后的重新绑定。
- 未执行真实 DDC、输入源切换、USB、网络或唤醒，未修改系统权限。

## DS-015 尚需用户实机验证

1. 小米显示器保持内建 HDMI，连续执行多次显式“读取 DDC 参数”，确认绑定到当前 HDMI service；读取协议是否受系统限制仍与 service 绑定分开判断。
2. 两台同型号显示器分别读写一次，确认操作始终落到目标物理显示器，不串台。
3. 热插拔或把同一显示器在 HDMI、USB-C/DP 间切换后刷新，再执行显式读取，确认旧 service 失效且重新绑定。
4. 输入源切换路径不属于本次修改，但应做一次最小回归，确认现有同时切换行为未退化。

## DS-015 修改范围

- `macOS/Sources/DisplaySwitcher/DDCBackend.swift`
- `macOS/Sources/DisplaySwitcher/NativeDDC.swift`
- `macOS/Tests/DisplaySwitcherTests/DDCBackendTests.swift`
- `macOS/DEVELOPMENT_CHECKLIST.md`
- `handoffs/macos.md`

## 上一任务：DS-014 内建 HDMI 原生 DDC 读取收敛

## DS-014 收敛结论

- 实机已经证明：内建 HDMI 的既定 `chip = 0x37` 下，offset 0 与 0x51 的系统调用虽返回成功，但回复均未通过严格 DDC/CI 校验，其中包含 EDID-like 数据；该连接当前只验证 Set VCP 写入可用，读取不可用。
- 同一构建中的 Type-C/DP 严格成功样本证明请求格式、validator 和连续缓冲区并非全局失效；另一个 Type-C/DP 失败样本后续单独诊断，不与内建 HDMI 根因合并。
- 因此停止继续试探 chip、offset、延迟、写周期、回复长度或宽松校验，不把系统调用成功伪装成设备读取成功。

## DS-014 正式实现

- 内建 HDMI Get VCP 只执行一次既定 offset 0 严格事务；失败后不再运行十次诊断循环、不尝试 offset 0x51、不进入 checksum 兼容读取，也不触发 service 重建重试。
- 失败时保留并显示按稳定显示器 ID 保存的上次可信值；没有缓存则不制造数值。
- 普通设置页只显示“当前连接不支持可靠读取”或“当前连接不支持可靠读取，显示上次可信值”，不展示 IOReturn、chip、offset、attempts 或原始回复。
- 保留严格校验、EDID-like 拒绝、显式连续 `withUnsafeBytes`/`withUnsafeMutableBytes` 缓冲区及原始回复不出界面/日志的隐私边界。
- Type-C/DP 读取策略、Set VCP、输入源切换、显示器匹配、网络和 USB 行为均未改变。

## DS-014 最终自动验证

- DDC 专项 XCTest：50/50。
- 完整 XCTest：135/135。首次完整运行仅有一项既有跨显示器并发测试因 resolver 调用顺序波动失败；单项复跑及第二次完整运行均通过，本任务未修改该调度逻辑。
- Debug、Release、`./macOS/scripts/build-app.sh` 与 `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app` 均通过。
- 使用本机选定的 Xcode 27 Beta 6；命令仅记录通用的 `$DEVELOPER_DIR` 表达。
- 未执行新的真实 DDC、输入源切换、USB、网络或唤醒；未创建 PR、未触发云端 CI。

## DS-014 后续边界

- 不需要新的内建 HDMI 读取诊断包：本轮已无待验证的新读取变量，继续打包只会重复已确认失败的硬件路径。
- 如需界面确认，可在后续合并候选中验证安全提示与缓存展示；不作为继续试探读取参数的理由。
- 第二个 Type-C/DP 失败样本需要独立任务和独立证据范围。

## DS-014 第二阶段根因证据

- 第一阶段实机中，内建 HDMI 目标的 offset 0 与 0x51 共十次 WriteI2C/ReadI2C 均返回成功，但全部严格 checksum 失败；回复包含与当前显示器 EDID 衍生名称一致的连续窗口。原始字节和真实名称未写入本文件。
- 同一构建中另一条 Type-C/DP 样本可一次严格读取成功，证明 Get VCP 请求格式、严格 validator 和 Swift/C 桥接路径并非全局失效；另一个 Type-C/DP 失败样本继续单列，不与 HDMI 数据源问题混合。
- 当前枚举只证明选中了 `DCPAVServiceProxy`、`Location=External` 且相邻 endpoint 为 `dispextE`；这些证据能确认内建 HDMI 路由和 `chip=0x37` 写入路径，但不能证明私有 ReadI2C 被驱动复用到 DDC/CI 数据源。
- 因此本阶段不新增 chip、offset、延迟、写周期或回复长度探测。若连续缓冲区实验后仍分类为 `non-ddcci/edid-like`，结论是该内建 HDMI 原生路径当前只验证写入，读取不可用并安全显示上次可信值。

## DS-014 第二阶段实现

- `NativeDDCBridge.h` 将 WriteI2C 输入声明为只读指针；Swift 调用统一使用 `withUnsafeBytes`/`withUnsafeMutableBytes`，明确传入连续缓冲区的首地址和实际长度。
- 枚举仅在本机内存中保留当前 service/framebuffer 的原始 EDID（若系统提供）及 EDID 衍生产品名字节，拒绝回复只做连续窗口比对。
- 原始 11 字节回复仍用于严格校验，但不再进入界面诊断；展示只保留 IOReturn、offset、尝试次数、长度、严格结果及 `ddcci/strict-valid`、`non-ddcci/edid-like` 或未分类来源。
- 未改变 Set VCP、输入源切换、显示器匹配、Type-C/DP 读取策略、chip、offset、延迟、写周期和回复长度。

## DS-014 第二阶段诊断构建自动验证（历史）

- DDC 专项 XCTest：45/45。
- 完整 XCTest：130/130；存在一条既有 USB 并发测试 QoS 警告，测试本身通过。
- 纯测试覆盖连续输入/输出缓冲区长度与字节、EDID-like 窗口分类、严格 DDC/CI 优先、未匹配数据隔离及原始回复不出现在用户诊断。
- Debug、Release、`./macOS/scripts/build-app.sh` 和严格 codesign 验证通过。
- 未执行真实 DDC、输入源切换、USB、网络或唤醒；未创建 PR、未触发云端 CI。

## DS-014 第二阶段实机结果（已完成）

1. 用户保持目标显示器直连内建 HDMI，完成诊断读取。
2. offset 0 与 0x51 均未得到严格 DDC/CI 回复；连续缓冲区没有改变结果。
3. 结果已经用于上方正式安全策略，不再安排新的 HDMI 参数探测。

## DS-014 第一阶段原因与决策

- 已确认内建 HDMI 的原生 Set VCP 正常，而 Get VCP 在固定 offset 0 下失败；同一显示器经 Type-C/DP 时可以读取，因此本轮只验证 read offset，不改匹配、chip、延迟、写周期或回复长度。
- 诊断仅适用于当前已唯一匹配、`chip = 0x37`、`builtin-hdmi-converter` 的亮度 `0x10` 读取；明确 MCDP/0xB7、其他 VCP 和 Type-C/DP 保持既有行为。
- offset 0 严格失败后才诊断 offset 0x51。offset 0x51 必须连续两次产生严格有效且 current/max 一致的回复，才能标记为本次诊断成功；不接受移位、坏 checksum、null reply 或弱校验估算。

## DS-014 第一阶段实现

- 新增纯 `NativeDDCHDMIReadDiagnosticRunner`，对 offset 0 与 0x51 执行相同的有界次数和 50 ms 延迟；request-write-failed 不进入回退。
- 每个 attempt 记录 offset、固定延迟、两次写调用的 IOReturn、ReadI2C IOReturn、完整 11 字节回复和严格校验结果；输出只包含 DDC/CI 公共事务字段。
- 诊断成功显示 `read-diagnostic-succeeded`，不把实验策略描述成正式默认；失败保持精确拒绝原因。
- 读取偏好缓存从 selector 单键升级为 selector + 当前 IORegistry service identity + transport，重新发现、service 替换、取消和失效会清理旧偏好。

## DS-014 第一阶段自动验证

- DDC 专项 XCTest：42/42。
- 完整 XCTest：127/127；Type-C/DP、输入源切换、USB、协同、缓存与安全闸门模拟回归通过。
- 自动测试覆盖 HDMI offset 0 → 0x51 有界回退、request-write-failed 不回退、移位/坏 checksum/null reply/语义不一致拒绝、连续两次严格成功，以及 service/transport 绑定缓存失效。
- 未执行真实 DDC、输入源切换、USB、网络或唤醒。

## DS-014 第一阶段实机验证（已完成）

1. 用户已按要求完成内建 HDMI 亮度读取诊断。
2. offset 0 与 0x51 均未得到严格 DDC/CI 回复；原始回复暴露问题已在第二阶段修复。

## 上一任务：DS-011 原生 DDC 单后端清理

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
