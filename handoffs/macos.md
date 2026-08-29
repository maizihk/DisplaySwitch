# macOS 交接记录

## 当前任务

- 日期：2026-08-29
- 功能：DS-009 / macOS 非对称协同检测第一阶段诊断
- 分支：`codex/macos-ds-009-collaboration-diagnostics`
- 堆叠基线：`codex/macos-ds-009-hardware-acceptance@85c975b`
- 本轮实现提交：`21d24a3`
- 前置验收记录：PR #49 保持开放
- 本轮 PR：#50，目标为 `codex/macos-ds-009-hardware-acceptance`，保持开放

## 审计结论

- 从设置页检测到 UI 结果的链路为：`beginPeerCapabilityInspection` → 同一 BSD UDP socket 同步绑定本机监听端口 → `sendto` → `recvfrom` 携带来源地址/端口 → pending eventID 匹配 → v2 endpoint/HMAC/时间验证 → 设置页状态。
- 现有实现没有证据表明 1 秒超时是根因；本轮保持 1 秒不变。
- 已确认的首要问题是可观测性缺失：监听、发送和接收错误只进入系统日志，event/endpoint/HMAC/时间窗等拒绝统一折叠成“无响应”，无法判断非对称故障发生在哪一层。
- 另确认两项协议路径缺口：检测响应此前绕过 nonce 重放分类；超时后的迟到响应会进入普通 v2 路径并可能刷新在线状态。本轮分别改为明确拒绝 `nonce-reuse`/重复响应和 `late-response`。
- 未修改 PROTOCOL、Windows、检测超时、DDC、USB、唤醒或显示器行为；非对称故障的最终根因仍需用户双向诊断日志判定。

## 实现

- `PeerTransport.swift`：监听启动和发送返回结构化成功/错误类别；接收回调携带来源 endpoint；仍由同一个已绑定 socket 收发。
- `PeerProtocolV2.swift`：响应校验返回精确拒绝原因；增加脱敏诊断、event 生命周期、来源端口和 envelope 投影模型。
- `main.swift`：每次检测记录监听、发送、收包、校验、重放、迟到响应和超时；菜单新增“复制协同检测诊断”。
- `PeerTransportTests.swift`、`PeerProtocolV2Tests.swift`：模拟监听绑定失败、同一 socket 发送、正确响应、错误来源端口、event/endpoint/HMAC/时间窗错误、迟到响应、零收包超时和脱敏输出。
- `macOS/DEVELOPMENT_CHECKLIST.md`：记录该诊断阶段的自动验证状态。

## 自动验证

- 相关 XCTest：24/24。
- 完整 XCTest：115/115；全部使用模拟 socket、时间和协议消息。
- Debug 测试构建、Release `build-app.sh` 构建及严格 codesign 验证通过。
- 测试包实际解压后严格验签通过，ZIP 不含 `__MACOSX` 或 AppleDouble 条目。
- 使用本机选定的 Xcode 27 Beta 6；handoff 不记录个人绝对路径。
- 未执行真实 UDP、USB、DDC、唤醒或输入源切换，未修改防火墙。

## 诊断测试包

- `macOS/outputs/DisplaySwitcher-DS-009-collaboration-diagnostic-v2-macOS-test.zip`
- SHA-256：`0e98ea8a83c6f00814d26c50668fd2d0c0e42f889e1224240a20b9038f266298`
- 大小：648709 bytes

## 用户最短验证步骤

1. 两端保持现有配置和防火墙不变，先在 Windows 端对 macOS 点击一次“检测”。
2. 再在 macOS 协同页对同一 Windows 配置点击一次“检测”，等待结果。
3. 从 macOS 菜单选择“复制协同检测诊断”，将文本发回；导出不含 IP 原文、配对码、authTag 或 endpoint 原值。

## 待验与边界

- 根据日志区分：listener 未启动、sendto 失败、完全零收包、来源端口不符、event 不符、endpoint/HMAC/时间窗/重放拒绝或迟到响应。
- 本任务没有继续处理 C2C、DDC 原生读取或其他协同状态机行为。
- 多显示器同时切换已由用户实机确认通过；该结论与本次网络诊断分开记录。
