# macOS 交接记录

## 当前任务

- 日期：2026-08-29
- 功能：DS-009 / macOS M-009 Apple Silicon 原生显示控制
- 协调基线：`codex/coord-ds-009-native-display-control@53c2397011323cd941afe315e3a6881fe772299e`
- 基线确认：协调基线包含 `main@0bbfa9e0fad8350462b3b68083aace4ca9063dce`
- 分支：`codex/macos-ds-009-native-display-control`
- 实现提交：`551c8d694ba24b6802b1363d69436fd23a97d7dd`、`02f006c4d661876bc865ea413dba574b9bd94c61`，本轮映射生命周期修复以 PR #46 当前 HEAD 为准
- PR：[#46](https://github.com/maizihk/DisplaySwitch/pull/46)；base 为 `codex/coord-ds-009-native-display-control`

## 根因

- 实机事实已把故障收窄到原生读取：同一路径写入正常，不能把问题归因为 HDMI 整体不支持，也不应无必要改写写入语义。
- 原生读取只尝试一次，并对所有传输固定使用 read offset `0x51`；AppleSiliconDDC 默认实际尝试五次，MonitorControl 的 Arm64 读取使用 offset `0`，这是读取专属差异。
- 原生访问使用单个全局锁，所有显示器互相阻塞；读取失败不使缓存 service 失效，也不重新发现。结果是一个失效句柄可持续失败，并拖累其他显示器。
- 枚举回退名称和设置页多处直接使用“显示器 N”；离线去重还按产品名排除，导致同型号显示器被折叠或无法区分。
- DDC 路由仍保留自动/手动 `m1ddc` 选择，原生失败可能被回退结果遮蔽，无法判断本次原生调用是否真实成功。
- 对照 AppleSiliconDDC 后确认，原实现把上游默认五次读取尝试缩减成一次；service 绑定也从 IODisplayLocation 高权重的一对一评分简化为 registryEntryID 与遍历顺序，且只识别 `IOMobileFramebuffer` conformance。这些差异会放大偶发读取失败，并可能造成新系统上的漏配或错配。
- 原实现只校验回复 XOR checksum，未校验 Get VCP 回复长度、来源、opcode、结果码和 command echo；迟到或错误 VCP 回复可能被当作当前读取结果。
- 显示器页删除旧总读取开关后，运行时目标仍携带默认关闭的 `readEnabled`，服务又在进入后端前按它过滤，因此可见的亮度功能已开启也不会发起原生读取，诊断停留在 `idle · rebuild 0`。
- USB 与协同映射分别使用 90/180 点固定标题列，输入框又占 120 点；同型号显示器的区分后缀会被固定标签截断。
- 持久化文档始终只有三个唯一显示器；重复行来自设置页每次即时保存都经 `onSave -> reloadSettings` 与本地 `reloadValues` 重建动态映射区，旧行生命周期依赖整组移除再追加，且字段仅按数组序号关联，没有稳定显示器 ID 的幂等协调。
- 小米 Type-C 偶发切换失败来自原生双写结果覆盖：第一次 `IOAVServiceWriteI2C` 已接受输入源命令后，显示器可能立即断开当前 Type-C 链路；第二次返回失败会覆盖第一次成功，触发无意义的重建和重试，并把已接受的命令误报为失败。
- M4/macOS 27 不再提供旧分类器依赖的 `EPICProviderClass`、`Transport` 或 `ConnectionType`；三个服务只在 IORegistry 层级中暴露通用 `dispextE`、`dispext0`、`dispext1` endpoint。内置 HDMI 因而被误分为 `unknown-external`，错误使用 Type-C 的读取 offset `0x51`，最终只显示笼统的 `read-reply-rejected`。

## 完成内容

- 运行时 DDC 路由固定选择 Apple Silicon 原生后端；保留 `m1ddc` 源码作为历史实现，但任何控制通道设置都不能启动它。Intel Mac 明确报告当前原生后端不支持。
- 保留已正常工作的写入 `0x51`、五次尝试和双写语义；不用读取修复改写写入协议。
- 读取恢复为同一 service 最多五次有限尝试，每次重试前清空 response buffer；Type-C/DP Alt 固定使用 `0x51`，确认为内置 HDMI converter 时固定使用 `0`，未识别路径明确标记为 `unknown-external`，不在同一操作中无界探测。
- 设置页提供脱敏诊断：仅显示传输分类、service 是否匹配、请求写入/回复超时/回复 I2C/回复校验类别和重建次数，不显示硬件标识或路径。
- 完整枚举当前 `AppleCLCD2`、`IOMobileFramebufferShim` 及兼容 framebuffer 和外部 `DCPAVServiceProxy`，按 IODisplayLocation、产品名和序列信息评分，并保证一个显示器和一个 serviceLocation 只绑定一次。
- 在线显示器身份与可通信 service 分离：未匹配到 service 时仍可显示产品身份，但读取/写入明确失败。Get VCP 回复新增长度、checksum、来源、载荷、opcode、结果码及 command echo 校验。
- 原生传输锁改为按显示器 selector 隔离：同一显示器串行，不同显示器可独立执行。取消会清空 service 缓存；配置刷新、检测和窗口关闭会取消待写，迟到完成不会更新 UI 或缓存。
- 显示名称优先使用已保存的非默认名称，否则使用系统产品名称；同名显示器按已有稳定逻辑 ID 顺序添加本机序号，枚举重排不改变对应关系。
- 设置页显示器卡片、USB 输入映射、协同输入映射、菜单和辅助功能标签统一使用解析后的显示器名称。
- 原生读取失败显示脱敏错误；历史缓存只标记为“上次可信值”，不伪装成本次原生读取成功。
- 读取目标不再携带或检查隐藏的旧 `readEnabled`；亮度、对比度、音量三个可见功能开关是唯一读取选择来源。至少一项开启即进入原生后端，只调用开启项；全部关闭时零后端调用并明确显示“未开启可读取的 DDC 功能”。
- USB 与协同输入映射统一使用可换行的完整名称标签和 108 点固定输入框；同型号显示器的本机序号保留在标题投影中。
- 两个映射区改为按小写稳定 display ID 协调现有行：重复 ID 只保留一行、过期行可靠移除、重排复用现有行；即时保存成功后不再无条件重建整个显示器页面。
- 原生有限双写继续执行两次，但一轮内任意一次传输接受即视为该 DDC 命令已提交；后一次因输入切换造成的链路消失不再抹掉前一次成功。两次均失败时仍按原有有限重试、service 失效和重发现路径明确失败。
- registry 发现只从 proxy、父节点或相邻 framebuffer 的本机路径/名称中提取通用 endpoint token，不把完整路径带入模型、诊断或日志；`dispextE` 固定分类为内置 HDMI，数字 `dispextN` 固定分类为 Type-C/DP，旧 MCDP/Transport 规则继续作为兼容回退。
- HDMI 读取固定 offset `0`，Type-C/DP 固定 offset `0x51`，同一次操作不盲试另一 offset。脱敏诊断增加最后具体拒绝原因、实际 offset 和本轮有限尝试次数。

## 自动验证

- 完整 XCTest：70 项通过。
- 新增读取门控回归：旧 `readEnabled=false` 且亮度开启时只调用一次原生亮度读取；关闭的对比度/音量零调用；三项全部关闭零调用并返回明确跳过原因。
- 新增映射标题投影回归：两台同型号中性模拟显示器在 USB 与协同映射中均保留完整名称和本机序号。
- 新增 20 轮页面顺序变化、保存/重载等价投影回归：USB 与协同映射始终各为三个唯一稳定 ID，两个同型号名称的（1）/（2）后缀完整保留。
- 新增原生双写回归：`成功 -> 链路断开` 与 `失败 -> 成功` 均判定接受，只有两次都失败才报错；保持固定两次调用，不执行真实 DDC。
- 新增 endpoint 与诊断回归：synthetic `dispextE`、`dispext0`、`dispext1`、旧 MCDP 和未知路径分类及 offset；七种回复拒绝原因均投影为脱敏代码，并显示 offset 和尝试次数。
- 名称测试覆盖两台不同型号、两台同型号、已保存名称、稳定本机序号和枚举重排；断言用户可见名称不含 selector/稳定 ID。
- 后端测试覆盖原生成功、不可用、枚举失败、读取失败和写入失败均零 `m1ddc` 调用；持久化的旧控制通道设置不能重新启用回退。
- 写入协调测试覆盖 100 次快速滑杆写入合并为首值与最终值、同显示器跨 DDC 项串行、不同显示器故障隔离、取消/刷新/窗口关闭后丢弃迟到完成。
- 原生纯测试覆盖一对一 service 匹配、同型号位置区分、传输分类、未绑定身份拒绝、Get VCP 正确回复及 checksum/结果码/command echo 错误、分路径 read offset、五次读取与原写入参数回归。
- 使用本机选定的 Xcode 27 Beta 6：Debug、Release、`./macOS/scripts/build-app.sh` 和严格签名验证均通过；测试包实际解压后再次严格验签通过。
- `git diff --check`、构建产物忽略和敏感信息检查通过。
- 自动测试全部使用模拟后端和模拟副作用，没有访问真实 DDC、USB、UDP、网络、唤醒或输入源切换。

## 尚未执行

- 未启动 App 验证设置页、菜单、显示器卡片和两类输入映射的真实 GUI 名称与换行布局。
- 未验证真实 Apple Silicon CoreDisplay/IOAVService 枚举、同型号显示器本机序号对应、DDC 回读/写入、连续滑杆恢复或显示器断开重连。
- 未执行真实 USB、UDP、网络、显示器唤醒或输入源切换。
- Intel Mac 不在本机自动验证范围，当前设计为明确不支持原生 DDC。
- 内置 HDMI converter 的当前系统 IORegistry 结构和 service 匹配仍需授权实机只读验证；未经验证时不声称旧系统的 `AppleDCPMCDP29XX` 父节点规则仍完全适用。

## 上游审计依据

- [AppleSiliconDDC 原生实现](https://github.com/waydabber/AppleSiliconDDC/blob/main/Sources/AppleSiliconDDC/AppleSiliconDDC.swift)：读取默认五次尝试、framebuffer/proxy 枚举、一对一评分绑定和 `0x51` 读取 offset。
- [MonitorControl Arm64DDC](https://github.com/MonitorControl/MonitorControl/blob/main/MonitorControl/Support/Arm64DDC.swift)：当前读取 offset 为 `0`；与 AppleSiliconDDC 的差异只参数化记录，不在无授权时向真实硬件试探。

## 安全与边界

- 只修改 `macOS/` 和 `handoffs/macos.md`。
- 未修改 Windows、协议、contracts、specs、coordination、根 README、GitHub Actions、版本号、tag 或 Release。
- 未记录配对码、凭据、真实 IP、真实显示器/USB 标识、IORegistry 路径或个人路径。
- `macOS/.build/` 和 `macOS/outputs/` 为忽略的本机构建产物，不进入 Git。

## 协调端下一步

1. 审查本 PR 的原生单次请求、service 失效/重发现和 native-only 路由。
2. 在最终协调 PR 运行云端 CI；本平台任务不单独触发中间 CI。
3. 获得用户授权后，在 Apple Silicon 上分别验证不同型号与同型号多显示器的枚举、连续拖动和失败恢复。
