# 双端交接协议 v1

Mac 和 Windows 使用 UDP `49731`（可配置）通信。每条消息都是 UTF-8 JSON，包含：

- `version`：当前为 `1`。
- `type`：`handover_request`、`usb_present`、`usb_attached_and_awake`、`committed`、`status_probe` 或 `status_response`。
- `eventID`：本次交接的 UUID。
- `source` / `target`：`mac` 或 `windows`。
- `timestamp`：Unix 秒。
- `pairingCode`：两端相同且至少 8 位。
- `wakeSucceeded`：可选，表示唤醒或切屏调用是否成功。

源端检测到 USB 消失后防抖 150 ms。若最近 6 秒内收到过对端心跳，则每 150 ms 重复发送 `handover_request`，最多 4 次，并在 600 ms 后兜底切换；若对端不在线，则发送一次请求后立即切换，避免无效等待。目标端立即请求唤醒显示器，确认 USB 已接入后回复 `usb_attached_and_awake`。USB 先于请求到达时，目标端会主动发送 `usb_present`；请求随后到达时也会检查 USB 当前状态。为降低单个 UDP 包丢失造成的额外等待，`usb_present` 和 `usb_attached_and_awake` 会在短时间内重复发送 3 次。

源端收到确认后立即执行 DDC 切屏并发送 `committed`。在线对端 600 ms 内仍未确认时，源端退化为直接切屏；对端不在线时不等待。USB 在等待期间回到源端会取消交接。消息有效期为 10 秒，旧请求不会覆盖新请求。

Windows 在双端协同开启时每 2 秒发送一次 `status_probe`，Mac 使用相同 `eventID` 回复 `status_response`。连续约 6 秒未收到合法响应时，Windows 将对端状态显示为未响应或连接已中断。状态探测不会唤醒显示器，也不会触发 USB 或 DDC 切换。

配对码用于避免局域网内的误触发，不提供传输加密。应只在可信的家庭局域网中使用，并仅在专用网络配置文件中允许该程序通过防火墙。
