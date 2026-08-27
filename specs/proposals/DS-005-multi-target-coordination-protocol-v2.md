# DS-005：多目标协同协议 v2 提案

## 状态

- 状态：PROTOCOL_REVIEW（方向决定已确认，认证细节和 contracts 待补齐）
- 功能编号：DS-005
- 任务类型：cross-platform
- 基线：`24a4ed7bbfab0eb9726ed6261afe5ad56e3f4df7`
- 当前生效协议：`PROTOCOL.md`，`version = 1`
- 建议协议版本：`version = 2`
- 依赖：DS-004 本机 schema v3、多协同配置和显示器输入映射
- contracts：尚未创建；详细决定获批后在 `contracts/protocol-v2/` 创建 schema 和公共向量

用户已接受把本机多配置/UI 与网络新语义拆分：DS-004 负责本机数据和平台功能，DS-005 负责手动定向协同、单目标自动协同、多目标发现、USB/蓝牙通用到达声明以及同系统设备身份。

已确认的协议方向：

- v2 采用 HMAC-SHA256；配对码不得直接出现在网络消息中。
- 多目标发现总窗口为 3 秒。
- 不设置 250 ms 仲裁窗口；首个通过认证的合法 `input_present` 立即且不可变地锁定目标。
- 3 秒内没有合法目标时保持零 DDC，并要求用户手动选择。

本提案未获批准前，不修改 `PROTOCOL.md`、平台实现或现有 `contracts/protocol-v1/`。

## 为什么必须升级版本

v1 的 `source` / `target` 只有 `mac` 和 `windows`，`handover_request` 与 USB 离开绑定，`usb_present` 只表示 USB。以下需求不能在不改变已发布语义的情况下塞入 v1：

- 用户手动选择一个明确配置，要求先唤醒该对端，但不要求 USB 已到达。
- 多个配置同时开启时，由实际收到 USB 或蓝牙键鼠的对端声明接管。
- 两台 Mac 或两台 Windows 需要不同于平台枚举的逻辑设备身份。
- 一个来源必须区分多个对端返回的声明、确认、取消和提交。

因此 v2 使用逻辑 endpoint 身份和通用输入设备到达语义，v1 保持不变。

## 三条协同路径

### 1. 手动定向协同

用户点击 `切换到 {配置名称}`，目标配置明确：

1. 源端为该配置创建事件并发送 `handover_request(intent = manual)`。
2. 目标端不等待 USB/蓝牙到达，立即请求显示器唤醒。
3. 目标端唤醒调用完成后回复 `target_ready`。
4. 源端收到匹配确认后按 DS-004 映射执行 DDC；在线目标 600 ms 内未确认时允许按明确配置降级切换。
5. 源端发送 `committed`，说明 DDC 是否成功。

手动事件只发给用户选择的配置，不广播给其他配置。

### 2. 自动协同且只有一个已开启配置

本机检测到已绑定输入设备离开，唯一目标明确：

1. 源端发送 `handover_request(intent = input_handover)`。
2. 目标端立即请求唤醒，并等待自己配置的 USB/蓝牙设备到达。
3. 目标端确认设备到达且唤醒调用已完成后回复 `target_ready`。
4. 源端收到确认后切屏；在线 600 ms 未确认时按 v1 兼容策略降级，离线时发送一次后直接切屏。
5. 设备在等待期间回到源端时取消事件并发送 `cancelled`。

### 3. 自动协同且有多个已开启配置

源端不能猜测目标：

1. 源端检测输入设备离开后进入目标发现状态，不立即执行 DDC。
2. 各对端在检测到本机已绑定 USB 或蓝牙设备到达后，向对应来源发送 `input_present`。
3. 源端只考虑来自已开启、配置完整且通过认证的配置的声明。
4. 首个通过认证的合法声明立即且原子地锁定目标，不再等待仲裁窗口。
5. 目标锁定后，其他 endpoint 的声明均视为迟到消息并忽略，不得覆盖目标或触发第二次硬件动作。
6. 目标发现总窗口为 3 秒；没有声明时不猜测、不切屏，提示用户手动选择。
7. 锁定目标后发送 `handover_request(intent = input_handover)`，继续目标唤醒、确认、DDC 和 `committed` 流程。

## v2 消息

每条消息为 UTF-8 JSON。建议消息类型：

- `status_probe`
- `status_response`
- `input_present`
- `handover_request`
- `target_ready`
- `committed`
- `cancelled`

### 公共字段

| 字段 | 类型 | 必填 | 合法范围与缺少行为 |
| --- | --- | --- | --- |
| `version` | JSON integer | 是 | 固定为 `2`；其他版本不按 v2 处理 |
| `type` | JSON string | 是 | 必须为上述已知类型 |
| `eventID` | UUID string | 是 | 比较时 UUID 字母不区分大小写 |
| `sourceEndpointID` | UUID string | 是 | 安装实例生成的逻辑 ID，不是硬件 ID |
| `targetEndpointID` | UUID string/null | 是 | 定向消息必须非空；首次探测可为 `null` |
| `sourcePlatform` | JSON string | 是 | `macos` 或 `windows`，仅描述平台，不用于身份判断 |
| `timestamp` | finite JSON number | 是 | Unix 秒；接收时间差绝对值不超过 10 秒 |
| `nonce` | base64url string | 是 | 每条新逻辑消息使用密码学安全随机值；重发同一逻辑消息保持不变 |
| `authTag` | base64url string | 是 | HMAC-SHA256 认证标签；配对码本身不得发送 |

### 按类型字段

| 字段 | 类型 | 使用消息 | 范围 |
| --- | --- | --- | --- |
| `intent` | JSON string | `handover_request` | `manual` 或 `input_handover` |
| `wakeSucceeded` | JSON boolean | `target_ready` | 目标唤醒调用结果 |
| `switchSucceeded` | JSON boolean | `committed` | 源端 DDC 结果 |
| `reason` | JSON string | `cancelled` | 固定枚举，禁止自由文本泄漏本机信息 |

建议取消原因：`source_input_returned`、`ambiguous_target`、`discovery_timeout`、`configuration_changed`、`user_cancelled`。

`input_present` 不包含 USB/Bluetooth 类型、名称、VID/PID、地址、序列号或路径。它只声明发送 endpoint 的本机已检测到该协同配置绑定的逻辑输入设备到达。

未知字段忽略；缺失字段、类型错误、未知类型或非法枚举安全拒绝，不刷新在线状态、不回复、不产生硬件副作用。

## endpoint 与本机配置映射

- 每个安装实例生成一个随机 `endpointID`，只作为逻辑网络身份，不从显示器、USB、网卡、主机名或用户信息派生。
- DS-004 的每个协同配置保存预期 `peerEndpointID`；第一次成功检测前可以为空。
- 初次检测通过配置的 host/port 和配对凭据识别响应；用户确认后才保存 endpointID。
- 已保存 endpointID 发生变化时不得自动替换，必须提示重新确认。
- 同一 endpoint 可以在本机只有一个已开启配置；重复映射安全拒绝。
- 同系统组合通过 endpointID 区分；`sourcePlatform` 只用于诊断和能力显示。

## 配置检测与版本协商

“检测”按钮：

1. 先运行 DS-004 本机完整性检查。
2. 发送 v2 `status_probe`，响应必须使用相同 eventID，且零硬件副作用。
3. 若 v2 无响应，可以发送一次 v1 `status_probe` 进行兼容性识别。
4. 结果显示为 `v2 可用`、`仅 v1`、`认证失败`、`无响应` 或 `本机配置不完整`。
5. `仅 v1` 的配置不能参与多目标发现、手动协同唤醒、蓝牙声明或同系统协同。

不得通过检测自动开启配置、保存新 endpointID、修改防火墙或执行 DDC；首次 endpointID 仍需用户确认。

## 时序、幂等和选择规则

- 消息有效期保持 10 秒，边界包含 10 秒。
- 定向请求保持 150 ms 间隔、最多 4 次和 600 ms 在线兜底。
- 最近合法消息在线窗口保持 6 秒。
- 多目标发现总窗口固定为 3 秒；首个合法声明立即锁定目标，不设置仲裁窗口。
- 同一 `type + eventID + sourceEndpointID` 在有效期内视为重复。
- 每个事件最多绑定一个目标、执行一次 DDC 和发送一次逻辑提交。
- 已绑定目标后，其他 endpoint 的迟到 `input_present` 不得覆盖目标、重启流程或产生硬件副作用。
- 取消、配置重载、协同关闭或输入返回源端时清理所有相关计时器和待处理事件。
- 未收到合法目标声明时禁止退化为列表第一项或最近使用项。

## v1 兼容和降级

- v1 与 v2 使用同一 UDP 端口时，接收端先按 `version` 分派到独立解析器和状态机。
- v2 实现必须继续通过全部 v1 17 条消息向量和 16 条状态机向量。
- 单个配置可以记录检测到的对端能力；`仅 v1` 时只能使用当前 v1 已定义的 Mac/Windows USB 交接路径。
- 多个配置同时开启时，任何 v1-only 配置都不能参与自动目标发现。
- 不允许把 `input_present` 降级编码为 v1 `usb_present`，也不允许把 `manual` 请求伪装成 v1 USB 交接。
- 协商失败时保持本机显示器当前状态并提示用户，不猜测协议或目标。

## 已确认的认证方向

v2 采用 HMAC-SHA256。配对码不直接上网，使用明确规定的标准 KDF 派生认证密钥，对消息业务字段、时间戳、nonce 和 endpoint 身份进行认证，并继续使用时间窗和重放缓存。

在创建正式 contracts 和派发平台实现前，仍必须补齐并再次审查：

- 配对码文本编码和规范化方式。
- KDF 算法、salt、迭代次数和输出长度。
- HMAC 输入的规范化格式与字段顺序。
- nonce 长度、编码、缓存键和缓存期限。
- `authTag` 编码及常量时间比较要求。
- 不含真实配对码或设备信息的公共密码学测试向量。

这些细节属于已批准 HMAC 方向的技术规范化，不得由两个平台各自决定。

## 公共测试向量草案

| 编号 | 场景 | 预期结果 |
| --- | --- | --- |
| P-001 | v2 status probe/response | 相同 eventID，零硬件副作用 |
| P-002 | 手动定向请求 | 只发送给选定 endpoint；目标不等待输入设备即可唤醒并确认 |
| P-003 | 单配置自动交接 | 目标等待本机绑定设备到达后确认 |
| P-004 | 多配置首个合法 input_present | 立即且不可变地绑定该 endpoint |
| P-005 | 两个 endpoint 几乎同时声明 | 接收顺序中的首个合法声明胜出；后续声明零副作用 |
| P-006 | 3 秒无声明 | 超时，不猜测目标，零 DDC |
| P-007 | 绑定后其他 endpoint 迟到 | 忽略，不覆盖目标 |
| P-008 | 输入返回源端 | 取消请求和全部计时器 |
| P-009 | 重复 request/ready/committed | 唤醒和 DDC 均最多一次 |
| P-010 | 配置重载或协同关闭 | 清理事件，迟到消息零副作用 |
| P-011 | 同平台不同 endpoint | 按 endpointID 正确区分，不依赖 platform |
| P-012 | endpointID 变化 | 拒绝自动替换，要求用户确认 |
| P-013 | input_present 不含设备类型或标识 | 接受逻辑声明且无敏感数据 |
| P-014 | v1 与 v2 同端口 | 分别进入对应解析器，不串状态 |
| P-015 | v1-only 多配置 | 禁止自动多目标发现 |
| P-016 | 未知版本/type/intent/reason | 安全拒绝，零副作用 |
| P-017 | 错误 endpoint、配对或签名 | 安全拒绝，不刷新在线状态 |
| P-018 | 过期、重复、乱序和迟到消息 | 不改变新事件或重复硬件动作 |
| P-019 | 手动目标在线但 600 ms 未确认 | 仅对明确目标执行已批准降级，不广播 |
| P-020 | 自动多目标 3 秒内没有合法目标 | 不执行任何输入源切换并要求手动选择 |

正式 contracts 必须使用固定脱敏 UUID、逻辑 endpoint 和示例密钥，不含真实 IP、配对码、设备信息或路径。

## 平台任务边界

### Windows

- 增加 v2 解析器、endpoint 身份、配置路由、三条状态机路径和 USB/Bluetooth presence 适配器。
- 保留 v1 状态机和公共向量，不修改 macOS 或共享提案。

### macOS

- 增加等价 v2 解析器、endpoint 身份、配置路由、三条状态机路径和 USB/Bluetooth presence 适配器。
- 保留 v1 状态机和公共向量，不修改 Windows 或共享提案。

平台实现必须使用模拟网络、时钟、唤醒、输入设备和 DDC；不得通过真实硬件补足自动测试。

## 安全与隐私

- endpointID 必须随机生成，不得包含 MAC 地址、主机名、用户名称或硬件 UUID。
- `input_present` 不同步输入设备类型和任何硬件标识。
- IP、配对凭据和本机 profile UUID 不进入公共 contracts、日志或 Git。
- 未经用户明确确认，不执行真实 DDC、USB/蓝牙、唤醒、网络监听调整或防火墙测试。

## 回滚

- v2 与 v1 状态机并存；平台可以回退 v2 实现并继续读取保留的 v1 兼容配置。
- 回退不得自动删除 DS-004 schema v3 配置；无法理解 v3 的旧版必须保持安全状态。
- 协议失败时可关闭 v2 协同，不影响本机显示器控制。
- 未经批准不修改当前 `PROTOCOL.md`；提案回滚只需移除本文件和尚未创建的 v2 contracts。

## 已批准决定

1. v2 采用 HMAC-SHA256，不沿用 v1 明文 pairingCode。
2. 多目标发现总窗口采用 3 秒。
3. 不采用 250 ms 仲裁；首个通过认证的合法声明立即锁定目标，后续声明不得覆盖。
4. 发现超时时坚持零 DDC，并要求用户手动选择。
