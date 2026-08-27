# Windows 交接记录

## 当前任务

- 日期：2026-08-27
- 功能：DS-004 / Windows 第一阶段——本机模型、配置迁移和 UI
- 分支：`codex/windows-ds-004-local-model`
- 任务起始基线：`8466c120c15607e7f39645c494b2786eac1f12ac`
- push 前同步 main：`6052327de368684b3fa87e6a45e121ba3a4da612`（仅包含后续合并的 macOS CI 路径过滤，与 Windows 实现无冲突）
- 实现提交：`a6c9a7bd35bded48252b8da992c86e993692c00e`
- PR：[#21](https://github.com/maizihk/DisplaySwitch/pull/21)，保持未合并

## 完成内容

- Windows 本机设置升级为 `schemaVersion = 3`；首次启动生成随机 UUID `localEndpointID` 并原子持久化，不从硬件、主机名或用户信息派生。
- 全局显示器目录与 `collaborationProfiles` 分离。配置支持稳定 UUID、自定义唯一名称、排序、多个同时开启、对端 host/port、NFC 配对码、已确认 endpoint/协议能力、按显示器 UUID 的输入映射及本机 USB/Bluetooth 引用。
- Windows v2 的 `MacInput` 迁移到一个名为“Mac”的旧对端配置，显示器 `localInput` 保持 `null`；旧 USB 选择迁入该配置的本机触发引用。
- 迁移先保留 `.v2.backup`，完整编码、原子写入和回读成功后才生效。解析、迁移写入或回读失败会保留原文件并写入本机安全标记；重启后继续阻断 UDP、USB、DDC 和唤醒条件，用户成功保存合法 v3 配置后才解除。
- 协同设置页改为动态配置卡片，可添加、删除、重命名、排序和同时开启；删除已开启配置需要确认，界面至少保留一个配置。每个配置可编辑显示器输入映射、引用 USB 页设备并执行纯本机“检测”。
- 检测只读取编辑中的本机字段、显示器 UUID 引用和已缓存的后端枚举结果，不发送网络消息，不写 DDC，不切换输入源，不触发 USB/Bluetooth 或唤醒。
- 托盘菜单使用已启用且本机完整的配置名称生成 `切换到 {名称}`，不提供“切换到本机”。手动选择只读取所选配置的 UUID 映射并沿用现有本机 DDC 执行路径，不发送 v1 `handover_request` 冒充 DS-005 手动意图。
- 多个配置同时开启时，旧 v1 自动链路保持关闭，不选择第一项；DS-005 v2 UDP、HMAC、版本协商和多目标状态机均未实现。

## 自动验证

- `Windows/build-windows.ps1` x64 Release 完整通过。
- 自动测试输出：`DS-004 passed C-001 through C-015 local-model scenarios`。
- v1 公共回归输出：`DS-001 passed 17 message vectors and 16 state-machine vectors`。
- 覆盖：全新安装、随机 endpoint 持久化、0/1/多显示器、配置 UUID/重排/重命名/多个开启、重复 UUID/名称、控制字符、非法范围和未知版本、NFC 与 UTF-8 字节范围、endpoint 变化需确认、v2 迁移、孤立映射、显示器重排/移除/重新接入、部分映射和失败隔离、写入/解析失败及重启安全状态。
- 测试只使用临时配置和纯模型/模拟动作；未调用真实 UDP、USB、Bluetooth、DDC、显示器唤醒或防火墙。
- 绿色版输出为 `Windows/dist/DisplaySwitch.exe` 加 `runtime/`，总大小 1.37 MiB，小于 20 MiB；构建产物未进入 Git。

## 尚需实机验证

- WinUI 3 协同卡片的添加、删除确认、排序、滚动和高 DPI 布局。
- 保存后托盘菜单是否立即显示多个已启用配置的自定义名称，以及单项缺少映射时的部分失败提示。
- v2 到 v3 的真实用户配置升级和用户保存后安全状态解除。
- 上述验证若涉及实际点击托盘切换项，会执行 DDC 输入源写入；必须另行取得用户确认后再做。
- 本任务未验证真实 USB/蓝牙学习、UDP、DDC、唤醒和防火墙行为。

## 范围与后续

- 只修改 `Windows/` 和本文件；未修改 macOS、协议、contracts、specs、coordination、GitHub Actions 或根文档。
- DS-005 v2 网络运行时、HMAC、endpoint 检测协商和多目标状态机必须另开任务，不得从本分支顺带实现。
- framework-dependent 绿色版仍要求目标电脑安装 Windows App Runtime 2.4 x64。
