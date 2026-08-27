# macOS 交接记录

## 当前任务

- 日期：2026-08-28
- 功能：DS-005 / macOS M-202 协议 v2/HMAC
- 分支：`codex/macos-ds-005-protocol-v2`
- 基线：`dec66eca97b6a848b87a4c1ae3c30473134b8d2a`
- 实现提交：`0d40c1ff31ae7bb76f413448433c5d8b2bb69b1c`
- endpoint 引导评审修正提交：`ed00de4e701701e375ad7e9d46806c41ee63e718`
- 已验证实现 HEAD：`ed00de4e701701e375ad7e9d46806c41ee63e718`
- 最终 PR HEAD：以本交接记录所在的 PR #32 最新提交为准；该提交只更新验证记录。
- PR：[#32 DS-005 macOS: implement protocol v2 coordination](https://github.com/maizihk/DisplaySwitch/pull/32)

## 完成内容

- 在同一 UDP 端口按 `version` 分派 v1/v2，保留原 v1 解析、状态机、字段和时序。
- 增加 v2 严格消息校验，包括 endpoint 方向、UUID、10 秒时间窗、按类型字段和未知字段兼容。
- 使用 CommonCrypto/Security 实现 NFC 配对码输入、PBKDF2-HMAC-SHA256、规范化 HMAC-SHA256、常量时间比较和安全随机 nonce。
- nonce 缓存区分完全重复与同 nonce 异内容重用；重发使用同一已编码消息、nonce 和 authTag。
- endpoint 路由只接受完整、已开启、已确认的 v2 配置，重复 endpoint 映射安全停用。
- 增加纯 v2 状态机：手动定向、单目标自动交接、3 秒多目标发现、首个合法目标锁定、150 ms 防抖/重发、600 ms 定向兜底、6 秒在线窗口和取消/迟到结果隔离。
- USB 监控在启动时只记录初始 presence，不触发交接；输入返回源端只取消当前事件，不误发 `input_present`。
- 网络 `input_present` 只表示逻辑到达，不包含 USB/蓝牙类型、名称、标识、序列号或本机引用。
- “检测”先运行本机完整性检查，再发送零硬件副作用 v2 `status_probe`；无响应时仅回退一次 v1 探测。endpoint 首次或变化需用户确认并手动保存。
- 修复双方尚未确认 endpoint 时的首次探测死锁：未绑定配置仍监听本机端口；只有恰好一个完整候选通过 HMAC 后才沿原数据报连接定向回复相同 eventID 的 `status_response`。
- 首次探测不写入、确认或替换 `peerEndpointID`；多个认证候选、错误配对码、错误 target 和已配置 endpoint 冲突均安全拒绝，且不刷新正式路由/在线状态、不进入 USB、蓝牙、唤醒或 DDC 状态机。
- 配置安全状态、USB 学习状态和配置重载会停止网络/唤醒/DDC 副作用并清理计时器、重放缓存和待处理检测。

## 本地自动验证

- 本机选定的 Xcode 27 Beta 6：
  - Debug：`BUILD SUCCEEDED`。
  - Release：`BUILD SUCCEEDED`，包含 Standard Architectures。
  - 标准 `xcodebuild test`：66 项 XCTest，0 失败。
- v1 公共向量：17 条消息、16 条状态机，全部通过。
- v2 公共向量：1 条 NFC、4 条认证、20 条消息、20 条状态机，全部通过。
- `DEVELOPER_DIR="$DEVELOPER_DIR" ./macOS/scripts/build-app.sh`：成功。
- 产物：`macOS/outputs/DisplaySwitcher.app`、`macOS/outputs/DisplaySwitcher-macOS-arm64.zip`。
- `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app`：通过。
- 文件同步提供程序可能在验证后重新附加 Finder 扩展属性；构建脚本和本次最终验证均已清理被忽略的产物并严格验签，未修改系统信任。
- `contracts/protocol-v1/validate.py` 和 `contracts/protocol-v2/validate.py`：全部通过。
- `git diff --check`：通过。
- endpoint 引导新增 3 项 XCTest，覆盖双方 endpoint 均为空、唯一/多候选、错误配对码、错误 target、endpoint 冲突、相同 eventID、不自动保存身份和零硬件副作用。
- GitHub Actions macOS run [`33118330583`](https://github.com/maizihk/DisplaySwitch/actions/runs/33118330583) 在已验证实现 HEAD `ed00de4e701701e375ad7e9d46806c41ee63e718` 上通过：Debug、66 项 XCTest、Release 打包、产物检查、严格 codesign 和 artifact 上传全部成功。

## 尚未执行

- 真实 macOS/Windows 双端 UDP v2 认证、能力检测、手动定向、单目标和多目标交接。
- 真实 USB/蓝牙 presence，以及显示器唤醒、DDC 和输入源切换。
- 设置页能力检测、endpoint 确认、菜单状态和错误提示的真实 GUI 交互。
- 本任务没有启动 App，也没有访问真实网络、USB、蓝牙、唤醒或 DDC 接口。

## 安全与边界

- 只修改 `macOS/` 和 `handoffs/macos.md`。
- 未修改 Windows、`PROTOCOL.md`、`AGENTS.md`、根 README、coordination、specs、contracts、GitHub Actions、版本、tag 或 Release。
- 未记录真实 IP、配对码、USB/显示器标识、本机绝对路径或个人硬件信息。
- `macOS/.build/` 和 `macOS/outputs/` 保持 Git 忽略。

## 回滚

- 回退实现提交可停用 v2 运行时；v1 状态机和 schema v3 配置仍可保留，不需要删除用户数据。
