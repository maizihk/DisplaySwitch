# DisplaySwitch 协议 v2 公共合同

本目录是当前 `version = 2` 协议的机器可读公共合同，供 Windows 和 macOS 使用相同字节、消息和状态机向量实现。仓库根目录 `PROTOCOL.md` 是唯一生效规范。

## 文件

- `message.schema.json`：单条 UDP v2 JSON 消息的结构约束。
- `auth-vectors.schema.json` / `auth-vectors.json`：Unicode NFC、PBKDF2、规范化认证输入和 HMAC-SHA256 固定向量。
- `message-validation-vectors.schema.json` / `message-validation-vectors.json`：合法消息、错误输入、方向、时间窗和认证失败向量。
- `state-machine-vectors.schema.json` / `state-machine-vectors.json`：手动、单目标自动、多目标先到先得、超时、取消、重复和降级向量。
- `validate.py`：协调侧结构、密码学结果和跨文件不变量验证脚本。

## 版本边界

- `protocolVersion = 2` 对应网络字段 `version = 2`。
- contracts 自身使用 `schemaVersion = 1`；它不是平台本机配置的 `schemaVersion = 4`。
- 当前网络协议只支持 `version = 2`；`version = 1`、缺少版本和未知版本必须安全拒绝，且不得回复、刷新在线状态或触发硬件副作用。

## 合成测试材料

向量只包含合成输入字节、逻辑 endpoint UUID、固定 nonce 和固定虚拟时间，不包含真实配对码、IP、USB/蓝牙标识、显示器信息或本机路径。`syntheticInputSecretHex` 只用于验证 KDF，不是可部署凭据。

平台测试必须使用虚拟时钟、模拟 UDP、输入设备、唤醒和 DDC。任何 `status_probe/status_response`、非法消息、发现超时或迟到声明都不得访问真实硬件。

## 执行语义

1. `timestamp` 是非负 Unix 整秒，允许的接收偏差为闭区间 `[-10, +10]` 秒。
2. 新逻辑消息生成 16 字节随机 nonce；同一消息重发保持完全相同的 nonce 和认证字段。
3. 接收端保存 `sourceEndpointID + nonce` 至少 20 秒。完全相同的重放按重复消息处理；相同 nonce 配合不同认证字段安全拒绝。
4. 多目标发现从 150 ms 输入离开防抖完成后开始，最多持续 3 秒。首个通过认证的合法 `input_present` 立即锁定目标，不设置仲裁窗口。
5. 目标锁定后其他 endpoint 的声明不得覆盖目标或触发硬件；发现超时保持零 DDC并要求手动选择。
6. 一个 eventID 最多执行一次唤醒、一次 DDC 和一次逻辑提交；向量中未列出的硬件调用均为零。

## 验证

```bash
python3 contracts/protocol-v2/validate.py
```

脚本需要 Python 3 和 `jsonschema`。协调脚本不能代替两端原生测试目标消费同一批 JSON 向量。
