# Windows 交接记录

## 当前任务

- 日期：2026-08-28
- 功能：DS-004 / Windows W-201——DDC 后端接口化与亮度、对比度、音量控制
- 分支：`codex/windows-ds-004-ddc-controls`
- 任务起始基线：`7c78c537e0ba47c4613063ba5f71560e336115e9`
- 实现提交：`9e078a4926ef7d48f2629c63410bf4fc75f9e82b`
- PR：分支 push 后创建；不得自动合并

## 完成内容

- 新增统一的硬件 DDC 接口，覆盖稳定显示器枚举、后端能力和可用性、VCP 读取/写入、结构化错误及代际取消。
- Windows Dxva2 与 ControlMyMonitor 已拆成独立后端。原有输入源 `0x60`、并行显示器执行和一次 150 ms 重试语义保持不变；没有修改协议或 macOS。
- 每台显示器在现有 schema v3 内保存独立后端，旧 v3 配置缺少该字段时继承原全局后端，v2/更旧迁移仍保持原行为。后端和物理显示器按稳定逻辑 ID 关联，不依赖枚举顺序。
- 支持亮度 `0x10`、对比度 `0x12` 和音量 `0x62`。每项有独立开关；关闭后服务层零读取、零写入，界面滑块和提交按钮同时停用。
- 设置页为每台显示器提供后端选择、显式“三项读取”和逐项“应用”。滑块变化本身不写 DDC；“联动所有显示器”需用户显式开启且默认关闭。
- 报告最大值小于 10 或小于当前值时使用 `max(100, current)`。单项零值合法；同一显示器三项均成功返回零时不信任结果、不覆盖缓存。
- 缓存按稳定显示器 ID 与 VCP code 保存。读取失败可继续显示估计值，只有可信读取或成功写入才提交；单项、单显示器和联动部分失败互不污染。
- 后端不可用时明确区分不支持和暂时失败，ControlMyMonitor 始终描述为外部硬件 DDC/CI 后端，不描述为软件调光。
- 配置安全状态、运行时安全门和取消均在调用及缓存提交边界检查；窗口关闭、取消、保存或新操作会使旧异步结果失效。缓存持久化失败沿用既有安全标记和当前实例零副作用流程。

## 自动验证

- `Windows/build-windows.ps1` x64 Release 完整通过。
- 自动测试输出：`DS-004 passed C-001 through C-015 local-model scenarios`。
- 新增模拟后端输出：`DS-004 passed C-016 through C-020 and C-024 DDC-control scenarios`。
- v1 公共回归输出：`DS-001 passed 17 message vectors and 16 state-machine vectors`。
- 模拟覆盖三项正常回读、全零不可信、单项合法零、单台/单项失败隔离、单项关闭零调用、后端不可用、每显示器回退、取消和迟到结果、枚举重排稳定关联、显式联动部分失败及配置/运行时安全门零调用。
- 测试只使用临时配置和纯模拟后端；未访问真实 DDC、显示器、UDP、USB、Bluetooth、唤醒或防火墙。
- `Windows/dist/` 已验证入口 `DisplaySwitch.exe`、`runtime/` 和全部必需文件；framework-dependent 绿色版总大小 1.44 MiB，小于 20 MiB。构建产物未进入 Git。

## 尚需实机验证

- WinUI 3 每显示器后端选择、三项功能开关、读取/状态提示、提交式滑块、显式联动、取消及高 DPI/滚动布局。
- Dxva2 对真实显示器的三项能力、当前值/最大值准确性、零值行为和失败提示。
- ControlMyMonitor `/GetValue`、`/SetValue` 在真实目标上的退出码、显示器字符串和兼容性。
- 任一真实 DDC 测试（包括输入源、亮度、对比度或音量写入）都可能改变硬件状态，必须另行取得用户确认后执行。
- 本任务未验证真实 USB/蓝牙、UDP、唤醒或防火墙行为。

## 范围与后续

- 只修改 `Windows/` 和本文件；未修改 macOS、协议、contracts、specs、coordination、GitHub Actions、根文档、版本号、tag 或 Release。
- 未实现 DS-005、协议 v2、HMAC、USB 学习或关于页面。
- framework-dependent 绿色版仍要求目标电脑安装 Windows App Runtime 2.4 x64。
