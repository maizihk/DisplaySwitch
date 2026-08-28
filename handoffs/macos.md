# macOS 交接记录

## 当前任务

- 日期：2026-08-28
- 功能：DS-007 / macOS 设置界面、DDC 可靠性与 v2-only 收敛
- 分支：`codex/macos-ds-007-settings-ui`
- PR 基线：`codex/coord-ds-007-v2-only@da90d0c598ef683c53b243b804526e09ab0cce4f`
- 实现提交：待创建；以本交接记录所在 PR 的最新提交为准
- PR：待创建，base 必须为 `codex/coord-ds-007-v2-only`
- GitHub Actions：待推送后记录

## 完成内容

- 网络入口收敛为 v2-only：删除 v1 解析器、状态机、发送、心跳、探测回退及固定平台角色路径；只有整数 `version = 2` 才进入正式解析器。
- v1、缺失版本、浮点/字符串版本和未知版本均零回复、零在线刷新、零 USB、零唤醒和零 DDC。
- 本机配置升级到 `schemaVersion = 4`；v3 及更早配置先保留原值和本机备份，再生成协同、USB 自动化与全部 DDC 开关关闭的 v4 默认配置。
- v4 写入使用 staging、回读校验和最后有效值恢复；编码、写入或回读失败持久进入四类副作用全部关闭的安全状态。
- 设置页保持 Swift/AppKit，标签统一为“常规、USB 切换、协同、显示器、关于”；移除全局保存/取消，开关、选择器、配置增删排序和 endpoint 确认即时原子保存，文本字段在提交时保存。
- 保存或校验失败恢复最后有效值，并在窗口内显示文字错误；普通设置页不展示 VCP 编号、endpointID、schemaVersion、后端类名或原始显示器标识。
- 协同检测和在线状态按配置独立维护，覆盖未启用、配置不完整、尚未检测、正在检测、无响应、v2 可用、已连接及 6 秒后连接断开。
- 手动配置入口只走已确认的 v2 路由；未确认时不再绕过协议直接写输入源。
- 显示器页仅保留控制通道、联动开关、检测/刷新入口，以及每台显示器的亮度、对比度、音量功能/托盘开关、滑杆和值。
- 新显示器六个 DDC 开关默认关闭；菜单栏控制只为 `enabled = true && showInTray = true` 的项目生成。
- 连续 DDC 写入按“稳定显示器 ID + 控制项” latest-wins 合并，同一显示器通道串行且不阻塞主线程；原生句柄失败后失效、重发现并只重试一次，再按控制通道决定是否回退。
- 配置变化、显示器重检、取消和安全闸门关闭会清空待写值；迟到结果不能更新缓存或 UI，自动读取不会覆盖写入中的项目。
- 标题使用非透明 AppKit 原生标题栏并随标签同步；内容、滚动区和关于页使用动态系统语义背景色。
- 关于页继续只读取公开 Bundle/静态信息，展示产品、版本/构建、平台/架构、协议 v2、GitHub、许可证和测试构建提示。

## 本地自动验证

- 本机选定的 Xcode 27 Beta 6：
  - Debug：通过。
  - Release：通过。
  - 完整 XCTest：47 项通过，0 失败，0 跳过。
- 公共 v2 消息：20 条全部通过；NFC 规范化 1 条、认证 4 条全部通过。
- 当前 v2-only 状态机：18 条公共向量全部通过。
- DDC 自动测试覆盖 100 次快速滑杆合并、两项交错串行、取消/迟到结果、句柄恢复单次重试、回退选择、失败后下次恢复和缓存保护。
- `./macOS/scripts/build-app.sh`：成功，生成忽略的 App 和当前架构 ZIP。
- `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app`：通过；文件同步扩展属性出现时清理忽略产物后复验通过。
- `contracts/protocol-v2/validate.py`：4 个 schema、1 条规范化、4 条认证、20 条消息和 20 条状态机数据合同校验通过。
- `git diff --check`：通过。
- 未启动 App；自动测试使用模拟网络、时间、DDC、USB、唤醒和输入源接口。

## 共享合同差异

- `contracts/protocol-v2/state-machine-vectors.json` 仍包含 DS-005 的 P-014/P-015 v1 兼容向量。
- 这两条与当前 `PROTOCOL.md`、DS-007 提案和本任务明确要求的 v2-only 行为冲突。
- macOS 没有为通过旧向量而保留已禁止的 v1 路由；平台测试执行其余 18 条 v2-only 状态机向量。共享文件不在本任务权限内，需由协调任务校准。

## 尚未执行

- 五个设置页的真实 GUI、浅色/深色外观、窄窗口、标题视觉居中、键盘焦点和辅助功能检查。
- 真实 macOS/Windows v2 UDP 探测、认证、在线过期、手动和自动交接。
- 真实 DDC 读取/连续拖动、原生句柄恢复、m1ddc 回退和多显示器失败隔离。
- 真实 USB/蓝牙 presence、显示器唤醒和输入源切换。

## 安全与边界

- 只修改 `macOS/` 和 `handoffs/macos.md`。
- 未修改 Windows、`PROTOCOL.md`、`AGENTS.md`、根 README、coordination、specs、contracts、GitHub Actions、版本、tag 或 Release。
- 未记录真实 IP、配对码、USB/显示器标识、本机绝对路径或个人硬件信息。
- `macOS/.build/` 和 `macOS/outputs/` 保持 Git 忽略。

## 回滚

- 回退本 PR 可恢复协调基线代码；v4 首次读取旧配置时生成的本机备份仍保留，回滚后需由用户明确选择是否人工恢复旧配置。
