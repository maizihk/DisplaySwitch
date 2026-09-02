# DisplaySwitch 本机 USB 切换公共合同

本目录固定 DS-008 的跨平台本机行为，不包含真实 USB、显示器、IP、端口、配对码或路径。

- `usb-switch-vectors.schema.json`：公共向量结构。
- `usb-switch-vectors.json`：USB-001 至 USB-016 的合成事件和预期动作。
- `validate.py`：结构、编号、隐私和关键不变量校验。

`configSchemaVersion = 5` 指两端本机配置语义；它不是网络消息字段。网络 `wake_display` 的结构与认证仍由 `contracts/protocol-v2/` 约束。

按已批准的 [`DS-026`](../../specs/proposals/DS-026-input-source-null-safety.md)，显示器映射的 `targetInput` 只能为 `null` 或整数 `1...65535`，`switchDisplay` 动作只能携带整数 `1...65535`。空映射继续报告既有 `missing_mapping`，不新增错误原因。

平台测试必须把每个 `input` 送入纯逻辑层，并逐项比对 `expectedActions`。`switchDisplay`、`wakeDisplay` 和 `sendWakeDisplay` 必须使用模拟接口。

```bash
python3 contracts/usb-switch-v1/validate.py
```
