# Windows 交接记录

## 当前任务

- 日期：2026-08-28
- 功能：DS-005 / Windows W-204 协议 v2
- 分支：`codex/windows-ds-005-protocol-v2`
- 任务起始基线：`dec66eca97b6a848b87a4c1ae3c30473134b8d2a`
- 实现提交：`7cea2cfae848c312efdedf7d13d4784326654692`
- PR：创建后补充；保持开放，不自动合并
- GitHub CI：PR 创建后等待 Windows workflow；本节当前结果均为本机验证

## 完成内容

- UDP 接收层保留原始数据报，再按顶层 `version` 独立送入既有 v1 或新增 v2 解析器与状态机；未修改 v1 消息字段、时序和公共向量。
- v2 使用 Windows CNG 实现 NFC 后配对码、PBKDF2-HMAC-SHA256（200000 次、32 字节方向密钥）、规范化认证输入、常量时间标签比较和系统安全随机 nonce。
- 接收顺序固定为结构/版本、方向与 endpoint、10 秒时间窗、HMAC、20 秒重放缓存；完全相同的重发按重复消息处理，相同 nonce 配合不同认证输入按 `nonce_reuse` 拒绝。
- 运行时按已确认 `peerEndpointID` 精确找到唯一启用配置；重复 endpoint、与本机相同 endpoint、未知 endpoint、未知版本及认证失败均不会刷新在线状态或触发硬件。
- 手动路径只向用户选择的 v2 配置发请求；单个配置保留 150 ms 防抖与在线 600 ms 确认/降级；多个启用配置进入 3 秒发现并立即锁定首个合法 `input_present`，超时保持零 DDC并提示手动选择。
- v1-only 配置不参与 v2 手动唤醒或多目标发现；v1 与 v2 不会同时消费同一个自动交接事件。配置重载会先关闭副作用闸门并递增代际，阻止旧异步唤醒、DDC 或发送结果迟到提交。
- v2 数据报只包含逻辑 endpoint、事件、意图和布尔结果，不包含配对码、USB/蓝牙类型或标识、显示器标识和本机路径。

## 自动验证

- `Windows/build-windows.ps1` x64 Release 完整通过。
- v2 原生公共向量输出：`DS-005 passed 1 normalization vector, 4 authentication vectors, 20 message vectors and 20 state-machine vectors`。
- v1 公共回归输出：`DS-001 passed 17 message vectors and 16 state-machine vectors`。
- DS-004 C-001..C-024 既有本机模型、保存安全、DDC、USB 学习和关于页面回归全部通过。
- 额外自动检查覆盖完全相同 nonce 重发、同 nonce 不同认证输入拒绝、版本分派和序列化隐私字段；状态向量以模拟时间、逻辑输入到达及唤醒/DDC 调用计数执行，不访问真实设备。
- `Windows/dist/DisplaySwitch.exe`、`runtime/` 和必需文件检查通过；framework-dependent x64 绿色版总大小 1.57 MiB，小于 20 MiB，构建产物未进入 Git。
- 本机构建出现 NuGet 漏洞元数据查询 `NU1900` 网络警告；已有依赖恢复、编译、测试和产物检查均成功，未降低或删除检查。
- `contracts/protocol-v2/validate.py` 的独立 Python 校验未运行：本机 Python 缺少 `jsonschema`；同一批正式 JSON 向量已由原生 `DisplaySwitcher.Tests.exe` 全量读取并通过。

## 尚需实机验证

- 两端 v2 配对、同端口 v1/v2 互操作、状态探测、6 秒在线状态过期与恢复。
- 用户手动定向唤醒/确认/切屏、单配置 USB 自动交接、多个配置 3 秒发现与先到先得，以及发现超时的零 DDC 提示。
- Windows/Windows、Windows/macOS 的 endpoint 路由，真实网络丢包/重排/时钟偏差和系统睡眠后的恢复。
- 真实 USB 与平台后续蓝牙到达适配、显示器唤醒和 DDC 输入源结果。
- 本任务未启动新版程序，未访问真实 UDP、USB、蓝牙、DDC、显示器唤醒、防火墙或系统设置。

## 范围与后续

- 仅修改 `Windows/` 和本文件；未修改 macOS、`handoffs/macos.md`、`PROTOCOL.md`、`AGENTS.md`、根 README、coordination、specs、contracts、GitHub Actions、版本号、tag 或 Release。
- W-204 代码与本机自动验证完成；等待 PR 的 Windows CI 和协调评审，不自动合并。
