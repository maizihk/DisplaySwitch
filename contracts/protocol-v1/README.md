# DisplaySwitch 协议 v1 公共合同

本目录是 DS-001 获批后生成的机器可读公共合同，供 Windows W-003 和 macOS M-004 的自动测试共同消费。当前运行时规范仍是仓库根目录 `PROTOCOL.md`；本目录不得单独改变线上协议语义。

## 文件

- `message.schema.json`：单条 UDP v1 JSON 消息的结构约束。
- `message-validation-vectors.schema.json`：消息验证向量文件的结构约束。
- `message-validation-vectors.json`：合法、错误、未知和时间边界输入。
- `state-machine-vectors.schema.json`：状态机序列向量文件的结构约束。
- `state-machine-vectors.json`：防抖、重发、兜底、取消、重复和乱序场景。
- `validate.py`：协调侧结构和公共不变量验证脚本。

## 版本边界

- `protocolVersion` 对应网络消息字段 `version`，当前为 `1`。
- `schemaVersion` 表示公共测试合同自身的数据结构版本，当前为 `1`；它不是网络协议版本，也不写入平台本机配置。
- DS-001 不引入跨端配置同步；这里的 `schemaVersion` 只用于 contracts 和公共测试向量。

## 测试数据

所有 UUID、相对时间和配对码都是固定合成数据。平台测试必须把 `referenceTime` 作为虚拟 Unix 时间，把 `atMs` 作为相对于场景起点的单调时间，不得访问真实时钟、局域网、USB、DDC 或显示器唤醒接口。

公共示例配对码 `TEST-CODE-0001` 仅用于测试，不是用户配置或凭据。向量不得替换成开发者或用户的真实配对码。

## 执行语义

1. 每个向量以 `initialState` 开始，并从 `nextEventIDs` 依次获取本端新事件 ID。
2. `steps` 按 `atMs` 升序执行。到达某个时刻时，先执行严格早于该时刻的到期计时器，再处理该步输入，最后执行恰在该时刻到期的计时器。
3. 同一 `atMs` 的 `expectedActions` 顺序具有意义；没有列出的内部状态变化不参与跨平台比较。
4. `sendMessage.atMs`、`requestWake.atMs` 和 `requestSwitch.atMs` 使用虚拟单调时间，允许平台内部线程模型不同，但逻辑时刻必须一致。
5. `expectedHardwareCalls` 是整个场景的总调用次数。`usbActions` 指改变 USB 归属的操作，不包括模拟 USB 存在状态输入。
6. `finalState` 只比较列出的公共状态；平台私有 UI 文案、日志和内部缓存布局不参与比较。
7. 非法消息必须产生 `rejectMessage`，且不得产生 `setPeerReachable`、回复或硬件动作。

## 验证

协调侧可执行：

```bash
python3 contracts/protocol-v1/validate.py
```

脚本需要 Python 3 和 `jsonschema`。平台实现仍须把相同 JSON 向量接入各自的原生测试目标，不能用协调脚本代替平台测试。
