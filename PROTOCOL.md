# 双端交接协议 v1

Mac 和 Windows 使用 UDP `49731`（可配置）通信。每条消息都是 UTF-8 JSON，包含：

- `version`：当前为 `1`。
- `type`：`handover_request`、`usb_present`、`usb_attached_and_awake` 或 `committed`。
- `eventID`：本次交接的 UUID。
- `source` / `target`：`mac` 或 `windows`。
- `timestamp`：Unix 秒。
- `pairingCode`：两端相同且至少 8 位。
- `wakeSucceeded`：可选，表示唤醒或切屏调用是否成功。

源端检测到 USB 消失后防抖 800 ms，然后在约 2 秒内重复发送 `handover_request`。目标端立即请求唤醒显示器，确认 USB 已接入后回复 `usb_attached_and_awake`。USB 先于请求到达时，目标端会主动发送 `usb_present`；请求随后到达时也会检查 USB 当前状态。

源端收到确认后执行 DDC 切屏并发送 `committed`。2.5 秒仍未确认时，源端退化为直接切屏。USB 在等待期间回到源端会取消交接。消息有效期为 10 秒，旧请求不会覆盖新请求。

配对码用于避免局域网内的误触发，不提供传输加密。应只在可信的家庭局域网中使用，并仅在专用网络配置文件中允许该程序通过防火墙。
