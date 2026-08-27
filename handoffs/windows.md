# Windows 交接记录

## 当前任务

- 日期：2026-08-27
- 分支：`codex/windows-ds-001-state-machine`
- 基线：`e65d05853496c44cdf54f59a4c9d5af7c230a13a`
- 清单：W-003 交接状态机可测试化 / DS-001 Windows
- 实现提交：待本分支提交后补充
- PR：待创建

## 完成内容

- 从 `Controller` 提取无 WinUI、Winsock、USB 或 DDC 依赖的 `HandoverStateMachine`；Controller 只负责传入时钟/USB/网络事件并执行发送、唤醒和切屏动作。
- 状态机实现 150 ms USB 防抖、在线对端 4 次请求、600 ms 兜底、离线快速路径、USB 返回取消、6 秒在线窗口，以及重复、乱序和陈旧事件保护。
- UDP 接收增加严格 JSON 必填字段和类型解析；协议校验覆盖 version、UUID、方向、配对码精确匹配、封闭消息类型和 10 秒时间边界。
- 保留 W-001 安全默认值、W-002 动态多显示器、无协同时的本机 USB 自动切换，以及现有 WinUI 3、UDP、USB、唤醒和 DDC 适配器。
- 未修改 `PROTOCOL.md`、`contracts/`、`specs/`、`coordination/`、GitHub Actions 或 macOS 源码。

## 自动验证

- 原生测试直接读取批准的 `contracts/protocol-v1/message-validation-vectors.json`（17 组）与 `state-machine-vectors.json`（15 组），全部通过。
- 虚拟时间覆盖 150 ms 防抖/重发、4 次上限、600 ms 兜底和 6 秒在线边界；假动作计数确保状态探测及非法消息没有硬件副作用。
- `Windows/build-windows.ps1` x64 Release 构建和全部自动测试通过。
- `Windows/dist/` framework-dependent 绿色版目录为 1.28 MiB，构建产物未进入 Git。

## 尚需验证

- 未启动新版，未执行真实 DDC、USB 交接、显示器睡眠/唤醒或防火墙修改。
- 合并前由 CI 复核构建；合并后可在用户另行确认时进行 Windows/macOS 双机状态探测与交接冒烟测试。

## 对 macOS 端的影响

- 无。Windows 消费已批准的 DS-001 公共向量，协议和 macOS 源码均未修改。

## 回滚

- 回退本分支 W-003 实现提交即可恢复旧 Controller 流程；本机配置格式与公共协议均未变化。
