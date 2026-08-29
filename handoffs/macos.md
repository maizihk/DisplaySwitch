# macOS 交接记录

## 当前任务

- 日期：2026-08-29
- 功能：DS-009 / macOS M-009 Apple Silicon 原生显示控制
- 协调基线：`codex/coord-ds-009-native-display-control@53c2397011323cd941afe315e3a6881fe772299e`
- 基线确认：协调基线包含 `main@0bbfa9e0fad8350462b3b68083aace4ca9063dce`
- 分支：`codex/macos-ds-009-native-display-control`
- 实现提交：`500c609b71f2273bdd91676007f3a7458e74e68a`
- PR：[#46](https://github.com/maizihk/DisplaySwitch/pull/46)；base 为 `codex/coord-ds-009-native-display-control`

## 根因

- 实机事实已把故障收窄到原生读取：同一路径写入正常，不能把问题归因为 HDMI 整体不支持，也不应无必要改写写入语义。
- 原生读取只尝试一次，并对所有传输固定使用 read offset `0x51`；AppleSiliconDDC 默认实际尝试五次，MonitorControl 的 Arm64 读取使用 offset `0`，这是读取专属差异。
- 原生访问使用单个全局锁，所有显示器互相阻塞；读取失败不使缓存 service 失效，也不重新发现。结果是一个失效句柄可持续失败，并拖累其他显示器。
- 枚举回退名称和设置页多处直接使用“显示器 N”；离线去重还按产品名排除，导致同型号显示器被折叠或无法区分。
- DDC 路由仍保留自动/手动 `m1ddc` 选择，原生失败可能被回退结果遮蔽，无法判断本次原生调用是否真实成功。
- 对照 AppleSiliconDDC 后确认，原实现把上游默认五次读取尝试缩减成一次；service 绑定也从 IODisplayLocation 高权重的一对一评分简化为 registryEntryID 与遍历顺序，且只识别 `IOMobileFramebuffer` conformance。这些差异会放大偶发读取失败，并可能造成新系统上的漏配或错配。
- 原实现只校验回复 XOR checksum，未校验 Get VCP 回复长度、来源、opcode、结果码和 command echo；迟到或错误 VCP 回复可能被当作当前读取结果。

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

## 自动验证

- 完整 XCTest：63 项通过。
- 名称测试覆盖两台不同型号、两台同型号、已保存名称、稳定本机序号和枚举重排；断言用户可见名称不含 selector/稳定 ID。
- 后端测试覆盖原生成功、不可用、枚举失败、读取失败和写入失败均零 `m1ddc` 调用；持久化的旧控制通道设置不能重新启用回退。
- 写入协调测试覆盖 100 次快速滑杆写入合并为首值与最终值、同显示器跨 DDC 项串行、不同显示器故障隔离、取消/刷新/窗口关闭后丢弃迟到完成。
- 原生纯测试覆盖一对一 service 匹配、同型号位置区分、传输分类、未绑定身份拒绝、Get VCP 正确回复及 checksum/结果码/command echo 错误、分路径 read offset、五次读取与原写入参数回归。
- 使用本机选定的 Xcode 27 Beta 6：Debug、Release、`./macOS/scripts/build-app.sh` 和 `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app` 均通过。输出目录所在 File Provider 在脚本结束后重新附加 Finder 元数据，清除该非签名元数据后独立严格验签通过。
- `git diff --check`、构建产物忽略和敏感信息检查通过。
- 自动测试全部使用模拟后端和模拟副作用，没有访问真实 DDC、USB、UDP、网络、唤醒或输入源切换。

## 尚未执行

- 未启动 App 验证设置页、菜单和显示器卡片的真实 GUI 名称与布局。
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
