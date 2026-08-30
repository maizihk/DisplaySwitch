# Windows 交接记录

## 当前任务

- 日期：2026-08-30
- 功能：DS-011 / Windows 原生 DDC 单后端清理
- 分支：`codex/windows-ds-011-native-ddc-only`
- 基线：`5e382569466139193cab0828865af6c3c91d4c49`
- 实现提交：本分支当前提交
- PR：按本轮约束不创建

## 根因与修复

- DS-009 已把正式运行时固定到原生 Dxva2，但仍保留第二后端的实现、外部进程启动与等待、路径检测、字符串选择器、配置字段和设置控件；实际行为与代码/配置模型不一致，继续形成无效维护面。
- DS-011 保留 `IDdcBackend` 与 `DdcControlService` 通用抽象，但服务改为直接持有唯一注入的后端。正式代码只能通过 `CreateNativeDdcBackend()` 创建 Dxva2 实现，不再存在按 key 查找、选择或回退的结构。
- 删除外部 DDC 工具类及其命令行拼接、进程启动、取消终止、等待超时、退出码和路径存在性检查。原生枚举、能力检查、VCP 读取/写入和输入源 `0x60` 失败均明确返回。
- 删除顶层后端选择/外部工具路径和每显示器兼容路径字段。schemaVersion 仍为 5；旧 v4/v5 JSON 中的额外字段按未知字段忽略，即使类型错误也不会读取，后续保存不会再次写出。
- 设置页删除只读后端选择器、隐藏路径控件和旧路径到原生 ID 的一次性关联；页面明确正式实现仅使用原生 Dxva2。
- 原生写入失败后的一次刷新重试、批量句柄复用、取消、并行批处理、缓存、latest-wins 和运行时安全门保持不变。USB、v2 协同、DDC 时序及显示器身份逻辑未修改。

## 自动验证

- 模拟 DDC 覆盖原生成功读取/写入、原生不可用明确失败、读写失败隔离、稳定 ID 重排、一次刷新重试、缓存、取消、联动和安全门。
- 配置测试覆盖旧后端字段为错误类型时仍被忽略，以及随后保存不再写出顶层选择、工具路径和每显示器兼容路径。
- `Windows/build-windows.ps1` 在构建前静态检查正式 Native 源码不含旧后端标识，并检查 DDC 后端不含外部进程启动 API。
- 正式 Native 源码旧标识/外部进程 API 扫描与 `git diff --check` 通过。
- x64 Release 构建和 `DisplaySwitcher.Tests.exe` 未运行：当前执行主机是 arm64 macOS，且不存在 `pwsh`、`powershell.exe`、MSBuild 或 .NET；未使用被禁止的云端 CI 代跑。
- 未触发 `workflow_dispatch` 或其他云端 CI。

## 尚需实机验证

- 真实 Dxva2 显示器枚举、稳定 ID 与友好名称。
- 亮度、对比度、音量的连续读取/提交、单台失败隔离和句柄刷新。
- 输入源切换成功与失败提示；不执行任何外部工具或回退。
- 本任务未启动正式程序，未执行真实 UDP、USB、DDC、显示器唤醒、输入源切换、防火墙或系统设置操作。

## 范围

- 仅修改 `Windows/` 和本文件。
- 未修改 `macOS/`、`handoffs/macos.md`、`PROTOCOL.md`、`AGENTS.md`、根 README、`coordination/`、`specs/`、`contracts/`、`.github/` 或版本号。
- 本轮只做本地验证；提交并 push 分支，不创建 PR，不触发云端 CI，不合并，不创建 Release/tag。
