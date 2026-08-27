# Windows 交接记录

## 当前任务

- 日期：2026-08-28
- 功能：DS-004 / Windows USB 学习与关于页面收尾
- 分支：`codex/windows-ds-004-usb-about`
- 任务起始基线：`7703bab10eb432f9f276e35d74d3a896a556d21a`
- 实现提交：`8b525b2bcddf6b6b23d7bb2c4a1e2181bdb28968`
- 关于页面评审修正提交：`749e22abbfe3b12d0cf6316c30038903221d2428`
- CI 验证 head：`749e22abbfe3b12d0cf6316c30038903221d2428`
- PR：[#30](https://github.com/maizihk/DisplaySwitch/pull/30)，保持开放、未合并
- Windows CI：run [#21](https://github.com/maizihk/DisplaySwitch/actions/runs/33106410265)（run ID `33106410265`）全部通过

## 完成内容

- 新增纯 C++ `UsbLearningSession`，学习会话固定绑定发起时的协同配置 UUID，以开始时设备集合为基线，并使用 30 秒模拟单调时间窗口和代际号拒绝迟到结果。
- 每个协同配置提供“学习 USB 设备…”入口。窗口内新增设备成为候选；多个候选不预选，必须由用户明确选择。候选确认前不修改配置中的原 USB 绑定。
- 取消、30 秒超时、目标配置删除、窗口关闭、候选失效和旧代际回调均丢弃学习结果；只有确认仍属于原配置的候选才替换该配置的 USB trigger。
- 学习开始时先取消 DDC UI 操作，再关闭 Controller 副作用闸门、停止 UDP 与 peer health、停用 USB 自动监测并清空当前 v1 状态机；结束后才按已保存配置恢复。异步唤醒、切屏和重复发送增加代际检查，旧结果不能在恢复后重新生效。
- 新增纯公共 `AboutInfo` 数据源和常规页关于对话框。评审修正后，现有公开版本值只写入 PE 版本资源，关于页通过 Windows Version API 从当前应用可执行文件元数据读取版本和构建号，读取失败显示“未知”，不再在 `AboutInfo.cpp` 硬编码版本。
- 关于页只显示应用图标、名称、应用元数据版本、Windows 架构、UDP v1、未签名测试构建说明，以及仓库主页、MIT 许可证和第三方说明三个公开链接；不读取本机配置。
- 用户可见的单对端/连接/自动切换提示改为配置名称或“对端”；内部 v1 `source/target`、状态机时序、`MacInput` 兼容字段、迁移默认名和自动返回本机语义未改变。
- 发布脚本将已有 `AppIcon.ico` 纳入 `runtime/` 必需文件，确保绿色版关于页可加载应用图标；未修改版本号、workflow 或发布设置。

## 自动验证

- `Windows/build-windows.ps1` x64 Release 完整通过。
- 新增输出：`DS-004 passed C-021 through C-023 USB-learning and about scenarios`。
- 既有本机模型输出：`DS-004 passed C-001 through C-015 local-model scenarios`。
- 既有 DDC 输出：`DS-004 passed C-016 through C-020 and C-024 DDC-control scenarios`。
- v1 公共回归输出：`DS-001 passed 17 message vectors and 16 state-machine vectors`。
- C-021/C-022 使用模拟设备集合和模拟时间覆盖两个候选、稳定配置 ID、显式选择、取消、30 秒边界、配置删除及跨代迟到回调；模拟副作用计数保持 UDP/USB/DDC/唤醒全部为零。
- C-023 验证版本来自实际 `DisplaySwitcher.Windows.exe` 的 PE 应用元数据，缺失元数据时不会伪造版本，并验证仓库、MIT 许可证和第三方说明三个公开链接；数据源不含配对码、USB/显示器标识或本机路径，网络与硬件调用计数为零。
- `Windows/dist/` 入口、`runtime/` 和全部必需文件通过检查；`runtime/AppIcon.ico` 已包含，framework-dependent 绿色版总大小 1.49 MiB，小于 20 MiB。构建产物未进入 Git。
- 本机构建的 NuGet 漏洞元数据查询出现 `NU1900` 网络警告；依赖恢复、编译、显式测试和产物检查仍全部成功，没有通过降低或删除检查规避。
- GitHub 托管 CI run #21 在 `windows-2025-vs2026` 上针对评审修正 head 完成相同的 x64 Release 构建、两次显式自动测试和产物检查；日志明确显示 C-001..C-015、C-016..C-020/C-024、C-021..C-023 与 v1 17+16 全部通过，dist 为 1.51 MiB，并列出 `runtime/AppIcon.ico`。
- CI artifact：`DisplaySwitcher-Windows-x64-unsigned-framework-dependent`，artifact ID `9660848188`，压缩包 742915 字节，SHA-256 `7212ce031a505bc057732495ccb9ccec2fa748edb53174270e1c16e48ee4cb75`；上传步骤通过并保留完整 `Windows/dist/` 结构。

## 尚需实机验证

- WinUI 3 中逐配置学习入口、30 秒提示、单/多候选对话框、取消/超时/删除交互、关于页图标、三个链接及元数据版本显示，以及高 DPI/滚动布局。
- 真实 USB Hub、键盘或切换器的枚举名称、PNP 引用重插稳定性和保存后 v1 单配置自动触发。
- 学习开始/结束时托盘状态、协同暂停/恢复和真实设备通知的交互。
- 本任务未启动新版程序，未访问真实 UDP、USB 自动交接、DDC、显示器、蓝牙、唤醒、防火墙或系统设置。

## 范围与后续

- 仅修改 `Windows/` 和本文件；未修改 macOS、协议、AGENTS、根 README、coordination、specs、contracts、GitHub Actions、公开版本值、tag 或 Release。
- DS-005 v2、HMAC、多目标网络运行时和蓝牙学习不在本任务内。
- PR #30 等待评审，不自动合并。
