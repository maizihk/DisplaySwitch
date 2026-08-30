# Windows 交接记录

## 当前任务

- 日期：2026-08-30
- 功能：DS-012 / Windows P0 协同检测非阻塞化
- 分支：`codex/windows-ds-011-native-ddc-only-windows-host`
- 承接基线：`b1e32d0`（DS-011 当前分支已推送提交）
- 实现提交：`5068aae43c07f1a0910e1a3d2ecaef658cc4436f`
- PR / CI：按任务要求不创建 PR、不触发云端 CI；仅执行 Windows 本机验证

## 根因与修复

- `SettingsWindow::DetectProfile` 原先在 WinUI 主线程同步进入 `Controller::BeginProfileDetection`，随后同步执行 200000 次 PBKDF2、`GetAddrInfoW` 和 UDP 发送。入站消息也先投递到 UI dispatcher，再执行 PBKDF2/HMAC，因此一次检测及连续响应会阻塞 WinUI 消息泵。
- PBKDF2 迭代次数、HMAC、nonce 重放保护、协议 v2 字段和检测零硬件副作用均保持不变。没有通过降低加密强度、跳过认证或删除超时来规避卡顿。
- 检测探测使用可取消后台操作完成密钥派生、签名、地址解析和 UDP 发送；启动调用立即返回，完成或失败后才经 dispatcher 回到 UI。
- 入站消息在后台执行密钥派生和 HMAC/重放验证；只有配置代次仍匹配的已验证消息才返回 UI 线程串行推进状态机。首次 bootstrap 的 host 解析、认证和回复同样不占用 UI 线程。
- 新增容量为 16 的线程安全派生密钥缓存。键由 NFC 规范化后的配对密码与 source endpoint 组成；配对密码、endpoint、配置代次或检测会话变化时不会复用旧密钥，配置应用和检测收尾会主动清空缓存。
- 设置页检测按钮在运行时禁用并显示“正在检测…”。窗口关闭、配置切换、即时保存、超时或新代次会取消旧操作；后台迟到结果通过双层 generation 检查丢弃，回调使用 C++/WinRT 弱引用，不能访问已销毁窗口。

## 自动验证

- `Windows/build-windows.ps1` 在 Windows 主机完成 x64 Release 构建，并真实运行 `DisplaySwitcher.Tests.exe`。
- 新增可注入慢 KDF 与慢解析/发送工作的测试，验证检测启动不等待后台工作、完成经 dispatcher 回调、取消/超时/配置切换后的迟到回调不落地。
- 新增缓存测试，覆盖相同密码与 endpoint 命中、密码变化、endpoint 变化、容量上限和配置代次清空。
- 既有检测测试继续覆盖匹配、错误、过期和重复 eventID、认证失败、超时、首次 endpoint 确认、身份变化确认及全流程零硬件副作用。
- v2 公共回归继续通过 1 条 NFC、4 条认证、20 条消息和 6 条状态机向量；USB-001 至 USB-016 全部通过；DS-004、DS-007、DS-009 回归通过。
- 绿色版输出为 `Windows/dist/DisplaySwitch.exe` 及完整 `runtime/`，本轮构建目录总计 1.64 MiB，低于 20 MiB。
- 构建期间仅出现 NuGet 漏洞索引网络不可达警告；已有依赖还原、编译、链接、测试和产物检查全部成功。

## 尚需实机验证

- 单击“检测”后，设置窗口动画、拖动、标签切换和关闭操作是否始终保持响应。
- 真实局域网中的 DNS/主机名解析、探测发送、匹配响应、认证失败和超时文案。
- 连续点击、检测中切换配置以及检测中关闭窗口的实际 WinUI 交互。
- 本任务未启动正式程序，未访问真实局域网，未执行真实 USB、DDC、显示器唤醒、输入源切换、防火墙或系统设置操作。

## 范围

- 仅修改 `Windows/` 和本文件。
- 未修改 `Windows/DisplaySwitcher.Windows/`、`macOS/`、`handoffs/macos.md`、`PROTOCOL.md`、`AGENTS.md`、根 README、`coordination/`、`specs/`、`contracts/`、`.github/`、版本号、tag 或 Release。
