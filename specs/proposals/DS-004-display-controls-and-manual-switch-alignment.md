# DS-004：显示控制与手动切换入口对齐提案

## 状态

- 状态：DRAFT（等待用户批准详细行为）
- 功能编号：DS-004
- 任务类型：cross-platform
- 基线：`24a4ed7bbfab0eb9726ed6261afe5ad56e3f4df7`
- 网络协议：保持 `version = 1`
- 公共 contracts：保持 `schemaVersion = 1`
- Windows 本机配置：建议由 `schemaVersion = 2` 升至 `schemaVersion = 3`
- macOS 本机配置：保持 `schemaVersion = 2`
- 关联协调记录：`coordination/DS-004.md`

用户已于 2026-08-27 决定：Windows 补齐亮度、对比度和音量调节；两端手动切换入口对齐。该决定确定产品方向，但平台实施须等待本提案的详细行为获批并进入共享基线。

## 当前行为

### macOS

- 菜单同时提供“切换到 Mac”和“切换到 Windows”。
- 每台显示器提供亮度、对比度和音量滑块，并可选择“联动所有显示器”。
- 使用 VCP `0x10`、`0x12`、`0x62` 读写数值；输入源使用 `0x60`。
- 读取失败时可显示本机缓存估计值；三项读取结果同时为零时按已知异常回读处理。
- 配置安全状态会阻断 DDC、USB、唤醒和网络副作用。

### Windows

- 托盘当前只有“手动切换到 Mac”。
- 每台显示器只保存 Mac 输入源，没有 Windows 输入源。
- 原生 Dxva2 与 ControlMyMonitor 当前只用于写入输入源 `0x60`，没有产品化的亮度、对比度、音量读写入口。
- Windows 本机设置文档当前为 `schemaVersion = 2`。

## 建议的公共用户行为

### 1. 手动切换入口

两端菜单或托盘都必须同时显示：

- `切换到 Mac`
- `切换到 Windows`

共同语义：

1. 手动入口只执行本机 DDC 输入源写入，不创建交接 `eventID`，不发送 UDP，不改变 USB 状态，不唤醒显示器，也不改变交接状态机。
2. 每个方向使用该显示器本机配置的对应输入源；不得根据当前平台、枚举顺序或其他显示器猜测输入值。
3. 缺少目标方向输入源的显示器不执行写入；其他配置完整的显示器仍可独立完成，最终明确报告部分失败。
4. 如果没有任何显示器可以执行目标方向，保持零硬件副作用并提示完成配置。
5. 配置处于安全状态时两个入口均不得执行 DDC；平台应显示需要用户检查配置的原因。
6. 一次手动切换未结束时，两个方向入口暂时不可再次触发，避免并发方向互相覆盖；完成后恢复。
7. 每台目标显示器首次写入失败时可在 150 ms 后重试一次。单台失败不得阻止其他显示器；不得对一次点击无限重试。

两端 UI 可以使用平台原生菜单实现，不要求像素级一致。

### 2. 亮度、对比度和音量

两端均按显示器提供以下逻辑控制：

| 控制 | VCP code | 用户值 |
| --- | --- | --- |
| 亮度 | `0x10` | `0...有效最大值` |
| 对比度 | `0x12` | `0...有效最大值` |
| 音量 | `0x62` | `0...有效最大值` |

共同语义：

1. 控件按稳定显示器身份关联，不依赖 `DISPLAY1` / `DISPLAY2` 或枚举顺序。
2. 用户可以调节单台显示器，也可以显式启用“联动所有显示器”；默认不得暗中联动。
3. 滑块仅在用户提交一次变更时写入，拖动预览不得造成无界连续 DDC 写入。
4. 读取成功时显示当前值；报告的最大值必须至少为 10 且不小于当前值，否则显示范围使用 `max(100, current)`。
5. 某台显示器三项控制均成功读取为 `0` 时，按异常遥测处理，不用这些结果覆盖缓存或 UI；单独一项为零仍可视为合法值。
6. 读取失败时不写硬件。存在该显示器对应控制的本机缓存时可显示为估计值；没有缓存时显示未知，不猜测当前值。
7. 写入成功后才更新该显示器的本机缓存。失败时保留上次成功值并报告具体显示器和控制项。
8. 某台显示器或某项 VCP 不支持时只影响该显示器/控制项，不得操作其他硬件标识。
9. 配置安全状态统一阻断读取、写入、枚举刷新引发的后续硬件动作以及缓存提交。

## DDC 后端共同逻辑接口

平台内部语言和类型可以不同，但应能映射到以下逻辑操作：

- `enumerate() -> [display]`
- `availability(display, control) -> available | unsupported | temporarilyUnavailable`
- `read(display, control) -> current + optionalMaximum | error`
- `write(display, control, value) -> success | error`
- `cancel(operation)`

共同要求：

- `control` 至少包含 `input`、`brightness`、`contrast`、`volume`。
- 原生后端和兼容后端是独立实现；选择或回退后端不得改变控制语义。
- Windows 原生后端使用系统物理显示器 API；ControlMyMonitor 可以使用其 `/SetValue` 和 `/GetValue` 能力。无法可靠获得最大值时按上述有效最大值规则降级。
- macOS Apple Silicon 原生后端和 `m1ddc` 回退保持现有选择策略；Intel Mac 无可用后端时明确报告不支持。
- 所有异步操作在 App 退出、配置重载或进入安全状态后必须可取消或丢弃迟到结果。

## 本机数据结构

本功能不创建跨端配置同步，也不把平台配置写入 `contracts/`。

### Windows `schemaVersion = 3`

每个 `Displays[]` 项在现有字段基础上增加：

| 字段 | 类型 | 必填性 | 合法范围 | 缺少时行为 |
| --- | --- | --- | --- | --- |
| `WindowsInput` | JSON integer | v3 保存时必填 | `-1` 或 `0...65535` | 从 v2 迁移为 `-1`，表示未配置，禁止猜测 |
| `ReadEnabled` | JSON boolean | v3 保存时必填 | `true` / `false` | 从 v2 迁移为 `true` |

- `MacInput` 语义和范围不变。
- `WindowsInput = -1` 不得阻塞已有“切换到 Mac”及自动交接；只使“切换到 Windows”对该显示器不可用。
- `ReadEnabled = false` 时不主动读取该显示器的三个数值，但用户明确写入仍可执行。
- 控制缓存仅保存在本机并按稳定显示器 ID 与 VCP code 分隔；不得包含在网络消息或公共样例中。

### macOS `schemaVersion = 2`

现有 `macInput`、`windowsInput` 和 `readEnabled` 已能表达所需语义，不修改字段或版本。

## 迁移、未知字段和失败安全

- Windows 必须读取 schema v2，并在内存中补充 `WindowsInput = -1`、`ReadEnabled = true`；只有完整 v3 文档原子写入成功后才视为迁移完成。
- 迁移写入失败时保留原 v2 文件，不覆盖、不删除；既有 v2 能力不得因新增字段而被错误解释。
- 损坏数据、非法类型或未知 `schemaVersion` 安全拒绝，进入不执行 DDC、USB、唤醒和网络交接的状态。
- v3 未知字段忽略；已知字段类型错误不得用猜测值修复。
- 降级到旧版 Windows 时，旧版会拒绝未知 schema v3 并进入安全状态。因此回滚平台提交前，应恢复用户备份的 v2 设置，或由回滚工具显式去除只属于 v3 的字段并把版本改回 2；不得静默覆盖。
- macOS 无配置迁移。

## 公共验收样例

这些样例定义共同观察行为，不进入网络 `contracts/protocol-v1/`：

| 编号 | 输入 | 预期结果 |
| --- | --- | --- |
| C-001 | 点击“切换到 Mac”，两台配置完整 | 两台分别写 `0x60` 的 Mac 输入值；无 UDP/USB/唤醒副作用 |
| C-002 | 点击“切换到 Windows”，两台配置完整 | 两台分别写 `0x60` 的 Windows 输入值；无 UDP/USB/唤醒副作用 |
| C-003 | 一台缺少目标输入值 | 另一台仍完成；缺失项零写入；报告部分失败 |
| C-004 | 安全状态点击任一手动入口 | 零 DDC、UDP、USB、唤醒副作用 |
| C-005 | 快速重复点击相反方向 | 首次操作期间拒绝第二次并发操作 |
| C-006 | 原生后端读取三项正常值 | UI 使用当前值和有效最大值 |
| C-007 | 三项均成功读为零 | 不覆盖缓存，显示估计值或未知 |
| C-008 | 单项合法读为零 | 该项显示零，不误判整台异常 |
| C-009 | 最大值缺失、小于 10 或小于当前值 | 使用 `max(100, current)` |
| C-010 | 单台/单项不支持 | 其他显示器和控制项继续工作 |
| C-011 | 联动关闭后调节一台 | 仅目标稳定 ID 收到一次写入 |
| C-012 | 联动开启后调节一台 | 每台配置显示器独立写入，失败隔离 |
| C-013 | v2 Windows 配置迁移 | 保留 MacInput；WindowsInput=-1；ReadEnabled=true；原文件写入失败时保留 |
| C-014 | 未知 Windows schemaVersion | 安全拒绝，零硬件和网络副作用 |
| C-015 | 配置重载/退出后迟到读取完成 | 丢弃结果，不更新 UI 或缓存 |

两端自动测试必须使用模拟 DDC、模拟时钟/执行器和临时配置目录，不得访问真实显示器、USB、网络、睡眠或唤醒接口。涉及交接代码的回归仍须通过现有 17 条消息向量和 16 条状态机向量。

## 平台任务范围

### Windows

- 实施 DDC 后端逻辑接口，并让 Dxva2 与 ControlMyMonitor 分别适配。
- 增加 per-display 亮度、对比度、音量读取和写入入口，以及显式联动开关。
- 托盘增加两个方向的手动切换入口。
- 本机配置迁移到 schema v3，加入 Windows 输入源和读取开关。
- 增加无硬件测试，更新 Windows 清单和 handoff。

### macOS

- 将现有 DDCController 映射到共同后端语义，补充可用性、错误、取消和单显示器失败隔离测试。
- 核实两个手动入口满足零网络/USB/唤醒副作用、并发互斥和安全状态规则；修复偏离并补测试。
- 不改变本机 schema v2，不改变现有 AppKit UI 技术栈。
- 更新 macOS 清单和 handoff。

## 安全与隐私

- 自动测试和公共样例不得包含真实 IP、配对码、显示器 UUID、USB ID、设备路径或本机路径。
- 日志不得记录原始硬件标识、路径或控制值之外的个人配置；配对码始终禁止记录。
- 真实 DDC 写入可能改变亮度、音量或造成黑屏。未经用户在当前任务再次明确确认，平台 Agent 不得执行实机写入、输入源切换、USB 交接或唤醒测试。

## 实现依据

- Microsoft Win32 物理显示器 API：[`GetVCPFeatureAndVCPFeatureReply`](https://learn.microsoft.com/windows/win32/api/lowlevelmonitorconfigurationapi/nf-lowlevelmonitorconfigurationapi-getvcpfeatureandvcpfeaturereply) 与 [`SetVCPFeature`](https://learn.microsoft.com/windows/win32/api/lowlevelmonitorconfigurationapi/nf-lowlevelmonitorconfigurationapi-setvcpfeature)。Microsoft 明确提示不同显示器对 MCCS/DDC 的实现可能不完整，因此失败隔离和实机兼容性验证不能省略。
- ControlMyMonitor 官方命令行说明：[`/GetValue`、`/SetValue` 和导出命令](https://www.nirsoft.net/utils/control_my_monitor.html)。兼容后端不得把进程启动成功误判为显示器必然支持对应 VCP code。

## 回滚

- 两个平台以独立提交实现，可分别回退。
- 回退 Windows v3 实现前必须处理本机 v3 配置兼容问题；代码回退本身不得自动删除用户配置。
- 本提案不修改 `PROTOCOL.md` 或公共 contracts，回滚不涉及网络协议。
