# Windows 交接记录

## 当前任务

- 日期：2026-08-27
- 分支：`codex/windows-w002`
- 清单：W-002 动态多显示器模型
- 实现提交：`46ecfd0`
- PR：[#2](https://github.com/maizihk/DisplaySwitch/pull/2)

## 完成内容

- 用带独立 UUID 的显示器配置集合替代固定双显示器字段，支持任意数量和用户排序。
- 原生 DDC/CI 与 ControlMyMonitor 共用动态配置和隔离执行器；单台失败不会阻止其他已配置显示器执行。
- 设置页支持添加、移除、上移、下移和重新选择显示器，断开时保留稳定硬件标识。
- 本机配置使用 `schemaVersion: 2`，旧双显示器 JSON 会原子迁移；解析或写回失败时保留原文件并停用自动硬件操作。
- 未修改 `PROTOCOL.md`、旧 C# 工程或 macOS 源码。

## 自动验证

- 无硬件测试覆盖 0、1、2、3、4 台显示器、UUID 稳定匹配、枚举顺序变化、旧配置迁移、迁移写回失败、新显示器安全默认值、移除重连和单台失败隔离。
- `Windows/build-windows.ps1` x64 Release 构建和测试通过。
- `Windows/dist/` 绿色版目录为 1.26 MiB，未进入 Git。

## 尚需验证

- 在实际 WinUI 3 设置页验证添加、删除、重排、后端切换以及高 DPI 布局。
- 在用户确认后验证真实显示器断开/重连匹配，以及原生 DDC/CI 和 ControlMyMonitor 的多显示器切换。
- 本任务未启动新版，未执行真实 DDC、USB 交接、睡眠唤醒或防火墙修改。

## 对 macOS 端的影响

- 无。协议和 macOS 源码均未修改。
