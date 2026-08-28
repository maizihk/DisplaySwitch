# DisplaySwitch 双端协同协议

本文件是 DisplaySwitch 网络通信的唯一生效规范。当前协议只支持 `version = 2`；任何其他版本都必须安全拒绝。

双端默认使用 UDP `49731`，端口可以按本机协同配置修改。所有消息都是 UTF-8 JSON。

## 版本边界

- `version = 2` 用于逻辑 endpoint、多协同配置、手动定向协同、USB/蓝牙输入到达声明和强认证。
- 网络消息版本字段统一为 `version`。
- 本机配置和公共测试合同使用 `schemaVersion`；它们不得写入网络消息或与 `version` 混用。
- `version = 1` 及其他版本均按未知版本处理：不回复、不刷新在线状态，也不产生 USB、蓝牙、唤醒、DDC 或输入源切换副作用。

## 消息结构

公共消息以 `contracts/protocol-v2/message.schema.json` 为机器可验证定义。公共字段如下：

| 字段 | 类型 | 必填 | 规则 |
| --- | --- | --- | --- |
| `version` | integer | 是 | 固定为 `2` |
| `type` | string | 是 | 必须为已知 v2 类型 |
| `eventID` | UUID string | 是 | 比较时字母不区分大小写 |
| `sourceEndpointID` | UUID string | 是 | 安装实例随机生成的逻辑身份 |
| `targetEndpointID` | UUID string/null | 是 | 仅首次或未绑定的 `status_probe` 可以为 `null` |
| `sourcePlatform` | string | 是 | `macos` 或 `windows`，只用于显示和诊断 |
| `timestamp` | integer | 是 | 非负 Unix 整秒，接收时间差绝对值不超过 10 秒，包含边界 |
| `nonce` | base64url string | 是 | 16 个密码学安全随机字节，无 `=` 填充，共 22 个字符 |
| `authTag` | base64url string | 是 | 32 字节 HMAC-SHA256，无 `=` 填充，共 43 个字符 |

已知消息类型及专用字段：

| `type` | 专用字段 | 行为 |
| --- | --- | --- |
| `status_probe` | 无 | 探测 v2 能力；允许 `targetEndpointID = null` |
| `status_response` | 无 | 使用请求的同一 `eventID`，定向回复来源 endpoint |
| `input_present` | 无 | 只声明本机已绑定的逻辑输入设备到达 |
| `handover_request` | `intent` | `manual` 或 `input_handover` |
| `target_ready` | `wakeSucceeded` | 目标端唤醒调用结果，boolean |
| `committed` | `switchSucceeded` | 源端 DDC 结果，boolean |
| `cancelled` | `reason` | 固定枚举的取消原因 |

`reason` 只能是：`source_input_returned`、`configuration_changed`、`user_cancelled` 或 `peer_unavailable`。禁止用自由文本传输本机信息。

除 `status_probe` 外的消息都必须携带非空 `targetEndpointID`，并与接收端本机 endpoint 完全匹配。`input_present` 不得包含 USB/Bluetooth 类型、名称、VID/PID、地址、序列号或路径。

未知 JSON 字段可以忽略，但不得影响状态或硬件行为，也不进入认证输入。缺少字段、类型错误、未知类型、非法枚举或类型专用字段组合错误必须安全拒绝。

## endpoint 与配置映射

- 每个安装实例随机生成并持久保存一个 `endpointID`；不得从显示器、USB、网卡、主机名、用户名或其他硬件信息派生。
- 每个本机协同配置保存预期的 `peerEndpointID`。首次检测前可以为空。
- 初次检测可以通过已配置 host、端口和配对凭据验证响应，但只有用户确认后才能保存 endpointID。
- 已保存 endpointID 变化时不得自动替换，必须提示用户重新确认。
- 同一 endpoint 在本机最多对应一个已开启配置；重复映射安全拒绝。
- 同平台设备使用 endpointID 区分，不能依赖 `sourcePlatform` 选择目标。

## 配置检测

“检测”操作按以下顺序执行：

1. 先完成本机配置完整性检查。
2. 发送 `version = 2` 的 `status_probe`；`status_response` 必须保持相同 `eventID`，且全程零硬件副作用。
3. 无响应时不得发送 v1 或其他版本探测，不得猜测兼容能力。
4. 结果只显示 `v2 可用`、`认证失败`、`无响应` 或 `本机配置不完整`。
5. 检测不得自动开启配置、保存或替换 endpointID、修改防火墙、执行 DDC、切换输入设备或唤醒显示器。

## 认证

### 配对码与密钥派生

网络消息不发送配对码。配对码先进行 Unicode NFC 规范化，再编码为 UTF-8；规范化后必须为 8 至 128 字节。

认证密钥按消息发送者派生：

- KDF：PBKDF2-HMAC-SHA256。
- 迭代次数：`200000`。
- 输出长度：`32` 字节。
- salt：ASCII `DisplaySwitch-v2-auth|{sourceEndpointID}`，其中 UUID 必须为小写。

无法规范化、长度非法或密钥派生失败时，保留原本机配置并禁用该配置的协同；不得发送消息或执行硬件动作。派生密钥可以安全缓存，但不得写入日志、网络消息或公共数据。

### HMAC 规范化输入

发送端按以下固定顺序构造 UTF-8 文本。每行使用单个 LF（`0A`），最后一行后也必须有 LF。UUID 使用小写；空值和该消息类型不使用的专用字段写字面量 `null`；boolean 使用小写 `true` / `false`；integer 使用无前导零十进制。

```text
DisplaySwitch/v2
version:2
type:{type}
eventID:{eventID}
sourceEndpointID:{sourceEndpointID}
targetEndpointID:{targetEndpointID-or-null}
sourcePlatform:{sourcePlatform}
timestamp:{timestamp}
nonce:{nonce}
intent:{intent-or-null}
wakeSucceeded:{wakeSucceeded-or-null}
switchSucceeded:{switchSucceeded-or-null}
reason:{reason-or-null}
```

使用派生密钥对上述字节计算 HMAC-SHA256。`authTag` 使用 RFC 4648 base64url 且不带 `=` 填充。接收端必须使用常量时间比较认证标签。

接收端先校验 JSON 结构、`version`、消息方向、时间窗和 endpoint，再验证 HMAC。任何失败消息都不得刷新在线状态、获得回复或产生硬件副作用。

### nonce、重复和重放

- 每条新的逻辑消息生成新的 16 字节随机 nonce。
- 同一逻辑消息的网络重发必须复用完全相同的字段、nonce 和 authTag。
- 接收端以 `sourceEndpointID + nonce` 为键保存至少 20 秒。
- 相同 nonce 和完全相同的已认证字段属于重复消息：不得重复唤醒或 DDC，但可以重发已缓存的同事件响应。
- 相同 nonce 对应不同认证字段时以 `nonce_reuse` 安全拒绝。
- 过期、乱序或迟到消息不得改变较新的事件。

## 协同状态机

### 手动定向协同

1. 用户选择 `切换到 {配置名称}`，源端只向该配置发送 `handover_request(intent = manual)`。
2. 目标端不等待输入设备到达，立即请求显示器唤醒。
3. 唤醒调用完成后，目标端发送 `target_ready`。
4. 源端收到匹配确认后按该配置的显示器映射执行 DDC。
5. 目标最近在线但 600 ms 内未确认时，只允许对这个明确目标降级切换；不得广播或选择其他配置。
6. 源端发送一次逻辑 `committed`，记录 DDC 是否成功。

### 自动协同且只有一个已开启配置

1. 本机已绑定输入设备离开后防抖 150 ms，源端向唯一目标发送 `handover_request(intent = input_handover)`。
2. 目标端立即请求唤醒，并等待本机已绑定 USB 或蓝牙设备到达。
3. 输入到达且唤醒调用完成后，目标端发送 `target_ready`。
4. 源端收到确认后执行 DDC；在线目标 600 ms 未确认时按明确配置降级，离线时发送一次后直接切换。
5. 输入设备在等待期间回到源端时，取消事件并发送 `cancelled(reason = source_input_returned)`。

### 自动协同且有多个已开启配置

1. 源端检测到已绑定输入设备离开后进入目标发现状态，不立即执行 DDC。
2. 各对端检测到其本机绑定的 USB 或蓝牙设备到达后，向对应来源发送 `input_present`。
3. 源端只接受来自已开启、配置完整、endpoint 匹配且认证通过的配置的声明。
4. 接收顺序中的首个合法声明立即且原子地锁定目标，不设置额外仲裁窗口。
5. 目标锁定后，其他 endpoint 的声明全部作为迟到消息忽略，不得覆盖目标、重启流程或触发第二次硬件动作。
6. 发现窗口固定为 3 秒。超时仍无合法目标时，不猜测、不执行 DDC，并提示用户手动选择。
7. 锁定目标后发送 `handover_request(intent = input_handover)`，继续目标唤醒、确认、DDC 和 `committed` 流程。

## 共同时间与幂等规则

- 消息有效期为 10 秒，包含恰好 10 秒的边界。
- 定向请求每 150 ms 重发，最多发送 4 次。
- 在线目标确认兜底为 600 ms；最近合法消息在线窗口为 6 秒。
- 多目标发现窗口为 3 秒，没有仲裁等待。
- 同一 `type + eventID + sourceEndpointID` 在有效期内视为重复。
- 每个事件最多绑定一个目标、执行一次 DDC 并发送一次逻辑提交。
- 取消、配置重载、协同关闭或输入返回源端时，必须清理相关计时器和待处理事件。
- 不得退化选择配置列表第一项、最近使用项或根据平台名称猜测目标。

## 版本拒绝与安全降级

- 同一 UDP 端口收到的数据报必须先读取并校验 `version`；只有整数 `2` 可以进入消息解析器和状态机。
- `version = 1`、缺少版本、类型错误和未知版本均安全拒绝，不发送兼容探测或响应。
- 版本、认证、endpoint 或目标选择失败时，保持当前显示器状态并提示用户，不猜测协议或目标。
- 协同可以按配置关闭而不影响本机显示器控制。
- 本机 `schemaVersion = 4` 配置不迁移 v3 或更早字段；旧文件只作为本机备份保留，不参与运行时。

## 隐私与测试要求

- 原始显示器 UUID、USB/Bluetooth 标识、IP、配对码、本机路径和个人硬件信息只保存在本机，不得进入网络同步数据、公共 contracts、公共样例、日志或 Git。
- endpointID 是随机逻辑身份，可以进入 v2 网络消息；不得由个人或硬件信息派生。
- 自动测试必须使用模拟网络、时钟、输入设备、唤醒和 DDC，不得访问真实局域网或硬件。
- 公共验收只以 `contracts/protocol-v2/` 为准，包括 NFC、PBKDF2/HMAC、消息验证和状态机向量。
- 实现与本文件或公共 contracts 不一致时，先停止合并并判断是平台偏离还是规范不足；不得单端改变公共字段语义。
