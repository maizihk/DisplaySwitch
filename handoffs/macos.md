# macOS 交接记录

## 当前任务

- 日期：2026-08-29
- 功能：DS-008 / macOS 本机 USB 双向切换
- 共享基线：`codex/coord-ds-008-usb-local-switch@35c2d156d2c2259fd604f3e305d0b09e234aec2b`
- 分支：`codex/macos-ds-008-usb-local-switch`
- 实现提交：`559d285aa194e5e7a0cf0ccd9bff90bd8abbafea`
- PR：[#41 DS-008 macOS: independent local USB switching](https://github.com/maizihk/DisplaySwitch/pull/41)，base 为 `codex/coord-ds-008-usb-local-switch`
- GitHub Actions：按任务约束不要求中间云端 CI；以下记录为当前实现提交的本地完整验证。

## 完成内容

- USB 监听仅使用独立 `usbSwitch` 配置中用户明确学习的单个本机设备，不再从 endpoint 路由或协同 profile 收集触发设备。
- 首次 USB 状态只建立基线；接入→离开立即按稳定显示器 ID 异步提交 DDC 输入源切换，不等待网络、心跳、回复、防抖或超时。
- 离开→接入只请求本机显示器唤醒，不执行 DDC。重复状态通知不重复执行。
- 联动协同默认关闭；关闭时 USB 路径不读取协同路由并且零网络调用。开启时只向明确选中、完整、已确认 endpoint 的 v2 配置发送一次认证 `wake_display`；发送失败只报告，不阻断、推迟或回滚 DDC。
- 接收合法 `wake_display` 时只请求本机显示器唤醒，不回复、不执行 DDC、不改变手动交接状态。网络唤醒和 USB 接入共用 2 秒合并器。
- 配置升级到 `schemaVersion = 5`；v4 先在本机备份，再使用 staging、回读校验和原子替换迁移。保留非 USB 设置和协同配置，不猜测旧 profile 中的 USB 设备或输入映射，新 USB 功能和联动均默认关闭。
- 迁移或写入失败保留旧值并持久进入 USB、DDC、唤醒和网络全部关闭的安全状态。
- AppKit USB 设置页改为单设备学习、每显示器目标输入源、USB 开关、联动开关和联动目标配置；普通 UI 只显示中性设备名称，不显示 VID/PID、序列号、路径或本机引用。
- 已删除 `input_present`、`input_handover`、USB 网络防抖/发现及输入返回取消的 macOS 死代码，保留 v2 手动协同、HMAC、endpoint 路由、重放保护、重发和超时语义。

## 本地自动验证

- 本机选定的 Xcode 27 Beta 6：Debug 构建通过，Release 构建通过。
- 完整 XCTest：49 项通过，0 失败，0 跳过。
- `contracts/usb-switch-v1/validate.py`：USB-001～USB-016 全部通过，配置 schemaVersion 5。
- `contracts/protocol-v2/validate.py`：4 个 schema、1 条 NFC、4 条认证、20 条消息和 6 条状态机向量通过。
- USB 纯测试覆盖全部 16 条公共向量、单设备精确匹配和 UI 设备名称脱敏。
- v4→v5 测试覆盖保留非 USB 数据、新 USB 默认关闭、不猜测旧绑定，以及写入失败保留原数据并阻断四类副作用。
- `./macOS/scripts/build-app.sh`：通过，生成 Git 忽略的 App 和当前架构 ZIP。
- `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app`：清理忽略产物的 Finder/File Provider 扩展属性后通过。
- `git diff --check`：通过。
- 未启动 App；自动测试全部使用模拟 USB、网络、时钟、DDC 和唤醒接口。

## 尚未执行

- USB 设置页的真实 GUI、学习、单设备匹配、取消和 30 秒超时交互。
- 真实 USB 插拔与双向状态转换。
- 真实 DDC 输入源切换、单台失败隔离和后端恢复。
- 真实本机显示器唤醒和 2 秒唤醒合并。
- 真实 macOS/Windows 认证 `wake_display` 发送、失败降级和重放拒绝。

## 安全与边界

- 实现只修改 `macOS/`；本交接提交只另外修改 `handoffs/macos.md`。
- 未修改 Windows、`PROTOCOL.md`、`AGENTS.md`、根 README、coordination、specs、contracts、GitHub Actions、版本、tag 或 Release。
- 未执行真实 USB、DDC、显示器唤醒、输入源切换或局域网交互。
- 未记录真实 IP、配对码、USB/显示器标识、本机绝对路径或个人硬件信息。
- `macOS/.build/` 和 `macOS/outputs/` 保持 Git 忽略。

## 回滚

- 回退 PR #41 可恢复 DS-008 共享基线的 macOS 实现。
- 本机 v4 备份不得删除；回滚后 USB 自动切换应保持关闭，避免旧网络 USB 语义重新触发硬件。
