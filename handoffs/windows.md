# Windows 交接记录

## 当前任务

- 日期：2026-08-28
- 功能：DS-005 / Windows W-204 协议 v2 评审修正
- 分支：`codex/windows-ds-005-protocol-v2`
- 任务起始基线：`dec66eca97b6a848b87a4c1ae3c30473134b8d2a`
- 实现提交：`7cea2cfae848c312efdedf7d13d4784326654692`
- 初次验证记录提交：`5cd459a04fd8df5e36737930b27a112038ed43e4`
- 首轮评审修正代码/CI head：`1068cf24fdf3d974d184a1174695368e2863e816`
- 双方空 endpoint 首次引导代码/CI head：`5d7f6233d967230e074a4980f6f19cd19f63b4cc`
- 最终交接记录提交：本文件所在提交（不改变上述已验证代码）
- PR：[#33](https://github.com/maizihk/DisplaySwitch/pull/33)；保持开放，不自动合并
- GitHub CI：[Windows run 33120448212](https://github.com/maizihk/DisplaySwitch/actions/runs/33120448212) 已在 `5d7f623` 成功

## 完成内容

- UDP 接收层保留原始数据报，再按顶层 `version` 独立送入既有 v1 或新增 v2 解析器与状态机；未修改 v1 消息字段、时序和公共向量。
- v2 使用 Windows CNG 实现 NFC 后配对码、PBKDF2-HMAC-SHA256（200000 次、32 字节方向密钥）、规范化认证输入、常量时间标签比较和系统安全随机 nonce。
- 接收顺序固定为结构/版本、方向与 endpoint、10 秒时间窗、HMAC、20 秒重放缓存；完全相同的重发按重复消息处理，相同 nonce 配合不同认证输入按 `nonce_reuse` 拒绝。
- 运行时按已确认 `peerEndpointID` 精确找到唯一启用配置；重复 endpoint、与本机相同 endpoint、未知 endpoint、未知版本及认证失败均不会刷新在线状态或触发硬件。
- 手动路径只向用户选择的 v2 配置发请求；单个配置保留 150 ms 防抖与在线 600 ms 确认/降级；多个启用配置进入 3 秒发现并立即锁定首个合法 `input_present`，超时保持零 DDC并提示手动选择。
- v1-only 配置不参与 v2 手动唤醒或多目标发现；v1 与 v2 不会同时消费同一个自动交接事件。配置重载会先关闭副作用闸门并递增代际，阻止旧异步唤醒、DDC 或发送结果迟到提交。
- v2 数据报只包含逻辑 endpoint、事件、意图和布尔结果，不包含配对码、USB/蓝牙类型或标识、显示器标识和本机路径。
- 设置页“检测”现已执行真实协议能力探测：先发送 v2 `status_probe`，2 秒无响应后最多回退一次 v1 `status_probe`；两种响应都必须保持当前待处理的同一 `eventID`。
- v2 检测按当前编辑中的 host、port 与配对码验证；报告 `v2 可用`、`仅 v1`、`认证失败`、`无响应` 或 `本机配置不完整`。首次发现或已保存 endpoint 变化都只弹出确认，不自动覆盖或写入磁盘。
- 检测期间暂停常规心跳并阻断 USB 事件、手动/自动切屏、DDC 与唤醒入口；检测结束后恢复原运行配置。检测专用 UDP socket 仅在原运行时未监听时临时启用并在完成后关闭。
- 常规 v1/v2 在线心跳也记录待处理 eventID；错误、过期、重复或非待处理 `status_response` 不再刷新在线状态。v2 `status_probe` 仍可按协议原 eventID 回复，但本身不直接标记对端在线。
- 双方尚未保存 `peerEndpointID` 时，接收端保留 UDP 数据报的来源地址与端口，并只在 host/port、HMAC 凭据及配置唯一性共同匹配时回复定向 `status_response`；响应复用探测 eventID，但不写配置、不刷新在线状态或信任 endpoint。
- 多个候选都通过、认证失败、来源不匹配、本机/既有配置 endpoint 冲突时安全拒绝且不回复。已绑定配置的常规 v2 心跳改为携带目标 endpoint，只有未绑定首次探测使用 `targetEndpointID = null`。

## 自动验证

- `Windows/build-windows.ps1` x64 Release 完整通过。
- v2 原生公共向量输出：`DS-005 passed 1 normalization vector, 4 authentication vectors, 20 message vectors and 20 state-machine vectors`。
- v1 公共回归输出：`DS-001 passed 17 message vectors and 16 state-machine vectors`。
- DS-004 C-001..C-024 既有本机模型、保存安全、DDC、USB 学习和关于页面回归全部通过。
- 额外自动检查覆盖完全相同 nonce 重发、同 nonce 不同认证输入拒绝、版本分派和序列化隐私字段；状态向量以模拟时间、逻辑输入到达及唤醒/DDC 调用计数执行，不访问真实设备。
- 新增模拟网络/时钟探测测试，覆盖 v2 probe/response 同 eventID、错误/过期/重复/非待处理响应、首次 endpoint 确认、endpoint 变化、认证失败、v2 超时后恰好一次 v1 回退、无响应/本机不完整及全流程 USB/蓝牙/唤醒/DDC 调用为零。
- 双端空 endpoint 模拟测试覆盖来源 host/port、相同 eventID 定向响应、HMAC、首次确认、候选歧义、错误凭据、endpoint 冲突、双方配置不被自动修改及零硬件调用。
- `Windows/dist/DisplaySwitch.exe`、`runtime/` 和必需文件检查通过；framework-dependent x64 绿色版总大小 1.61 MiB，小于 20 MiB，构建产物未进入 Git。
- GitHub 托管 Windows CI 的 Release 构建、显式自动测试、dist/体积检查与 artifact 上传全部成功；artifact 为 `DisplaySwitcher-Windows-x64-unsigned-framework-dependent`（ZIP 797348 bytes，保留 7 天）。
- 本机构建出现 NuGet 漏洞元数据查询 `NU1900` 网络警告；已有依赖恢复、编译、测试和产物检查均成功，未降低或删除检查。
- `contracts/protocol-v2/validate.py` 的独立 Python 校验未运行：本机 Python 缺少 `jsonschema`；同一批正式 JSON 向量已由原生 `DisplaySwitcher.Tests.exe` 全量读取并通过。

## 尚需实机验证

- 设置页在两台真实设备间的 v2 检测、双方空 endpoint 首次引导、首次/变化 endpoint 确认、v1 回退、认证失败与无响应显示；同端口 v1/v2 互操作、6 秒在线状态过期与恢复。
- 用户手动定向唤醒/确认/切屏、单配置 USB 自动交接、多个配置 3 秒发现与先到先得，以及发现超时的零 DDC 提示。
- Windows/Windows、Windows/macOS 的 endpoint 路由，真实网络丢包/重排/时钟偏差和系统睡眠后的恢复。
- 真实 USB 与平台后续蓝牙到达适配、显示器唤醒和 DDC 输入源结果。
- 本任务未启动新版程序，未访问真实 UDP、USB、蓝牙、DDC、显示器唤醒、防火墙或系统设置。

## 范围与后续

- 仅修改 `Windows/` 和本文件；未修改 macOS、`handoffs/macos.md`、`PROTOCOL.md`、`AGENTS.md`、根 README、coordination、specs、contracts、GitHub Actions、版本号、tag 或 Release。
- W-204 评审修正与本机自动验证完成；等待 PR 的 Windows CI 和协调复评，不自动合并。
