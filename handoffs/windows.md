# Windows 交接记录

## 当前任务

- 日期：2026-08-28
- 功能：DS-006 / Windows 公开文档清理
- 分支：`codex/windows-ds-006-public-docs`
- 任务起始基线：`04b7a9397d84735d28de709a142950b3670f4cb1`（已合并 DS-006 协调 PR 的 `main`）
- 公开文档提交：`69c867c281421e9c929283ac28372296075a46fa`
- CI 验证 head：`029a6954a6229de62b64e06da4bd21422e3f25d7`
- PR：[#27](https://github.com/maizihk/DisplaySwitch/pull/27)，保持开放、未合并
- Windows CI：run [#16](https://github.com/maizihk/DisplaySwitch/actions/runs/33099549484)（run ID `33099549484`）全部通过

## 完成内容

- 从 Windows 开发清单中移除具体旧 USB VID/PID，改为不含个人硬件标识的通用约束。
- 更新 Windows README，使配置说明与 schema v3 一致：显示器目录和多个协同配置分离，配置支持角色中性的自定义名称、启用状态、排序、对端信息、显示器输入映射和本机触发设备引用。
- 明确旧 C# 配置和固定双显示器字段仍是迁移兼容输入；未删除兼容字段或修改迁移代码。迁移不能安全完成时仍进入不执行硬件或网络副作用的安全状态。
- 补充 W-201 当前能力和边界：Dxva2/ControlMyMonitor 独立后端、输入源及亮度/对比度/音量 VCP、逐显示器开关、提交式写入、显式联动、缓存与故障隔离。
- 补充 Windows 10/11、x64 framework-dependent、Windows App Runtime 2.4、未签名构建、DDC/CI 环境限制、协议 v1 配对边界及隐私注意事项。
- 本任务仅修改公开文档和本交接记录；没有修改 Windows 运行时代码、测试、协议、共享规范、macOS、Actions、版本号、tag 或 Release。

## 自动验证

- Windows Markdown 本地链接检查通过；文档引用的仓库内路径均存在。
- Windows 公开文档扫描未发现旧 USB VID/PID、私网 IP、真实配对码、个人用户路径、私钥或 GitHub token 模式。
- `Windows/build-windows.ps1` x64 Release 完整通过。
- 自动测试输出：`DS-004 passed C-001 through C-015 local-model scenarios`。
- W-201 模拟后端输出：`DS-004 passed C-016 through C-020 and C-024 DDC-control scenarios`。
- v1 公共回归输出：`DS-001 passed 17 message vectors and 16 state-machine vectors`。
- `Windows/dist/` 入口、`runtime/` 和必需文件检查通过；framework-dependent 绿色版总大小 1.44 MiB，小于 20 MiB。构建产物未进入 Git。
- 本机构建的 NuGet 漏洞元数据查询出现 `NU1900` 网络警告，但依赖恢复、编译、测试和产物检查均成功；该警告不通过删除或降低检查规避。
- GitHub 托管 CI 在 `windows-2025-vs2026` 上完成相同的 x64 Release 构建、显式自动测试和产物检查；日志明确显示 C-001..C-015、C-016..C-020/C-024、17 条消息向量和 16 条状态机向量全部通过，dist 为 1.45 MiB。
- CI artifact：`DisplaySwitcher-Windows-x64-unsigned-framework-dependent`，artifact ID `9658014613`，压缩包 705630 字节；上传步骤通过并保留完整 `Windows/dist/` 结构。

## 尚需实机验证

- 本任务不改变运行时能力，因此不新增实机功能结论。
- W-201 留存的真实 Dxva2、ControlMyMonitor、不同连接链路和高 DPI 设置页验证仍待另行授权执行。
- 本任务未访问真实 DDC、显示器、UDP、USB、蓝牙、唤醒、防火墙或系统设置。

## 范围与后续

- 允许范围内仅修改 `Windows/DEVELOPMENT_CHECKLIST.md`、`Windows/README.md` 和本文件。
- framework-dependent 绿色版仍要求目标电脑安装 Windows App Runtime 2.4 x64。
- PR #27 等待评审，不自动合并，不创建 tag 或 Release。
