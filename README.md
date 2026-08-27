# DisplaySwitch

[![macOS CI](https://github.com/maizihk/DisplaySwitch/actions/workflows/macos.yml/badge.svg)](https://github.com/maizihk/DisplaySwitch/actions/workflows/macos.yml)
[![Windows CI](https://github.com/maizihk/DisplaySwitch/actions/workflows/windows.yml/badge.svg)](https://github.com/maizihk/DisplaySwitch/actions/workflows/windows.yml)

DisplaySwitch 是一个面向 Mac / Windows 双机共享显示器和 USB 键鼠场景的原生工具。macOS 菜单栏 App 与 Windows 托盘 App 可以分别控制显示器，也可以通过可信局域网协同：USB 切换完成后，目标端确认就绪，源端再执行 DDC/CI 输入源切换。

项目不会替新用户猜测显示器、USB 设备、输入源、IP 或配对码。自动硬件操作在配置完整并由用户启用前保持关闭。

## 当前实现

| 平台 | 技术 | 主要能力 | 构建入口 |
| --- | --- | --- | --- |
| macOS | Swift / AppKit | 菜单栏控制、动态多显示器、亮度/对比度/音量、USB 自动切换、双端协同 | `macOS/DisplaySwitcher.xcodeproj` |
| Windows | C++ / WinUI 3 | 托盘控制、动态多显示器、原生 DDC/CI、ControlMyMonitor 回退、USB 自动切换、双端协同 | `Windows/build-windows.ps1` |

当前 macOS 版本为 `2.1.0 (19)`，最低支持 macOS 12。Windows 端为 framework-dependent 绿色版，需要 Microsoft Windows App Runtime 2.4 x64，不依赖 .NET。

两端实现遵循 [`PROTOCOL.md`](PROTOCOL.md) 中的 UDP v1 交接协议。公共消息校验和状态机行为由 [`contracts/protocol-v1/`](contracts/protocol-v1/) 中的脱敏 schema 与测试向量约束。

## 工作方式

```text
源端检测到 USB 离开
        ↓
通过局域网通知目标端并短间隔重试
        ↓
目标端唤醒显示输出，等待 USB 接入
        ↓
目标端确认就绪
        ↓
源端执行 DDC/CI 输入源切换并发送 committed
```

网络不可用不会让切换永久卡住：对端离线时源端立即降级为本地切换；在线但未收到确认时，等待上限为 600 ms。等待期间 USB 返回源端会取消交接。重复、过期、乱序和方向错误的消息不会重复触发硬件动作。

## 使用前须知

- 显示器必须支持 DDC/CI，并在显示器菜单中启用相关功能。
- 输入源编号取决于显示器和接口，必须由用户根据自己的设备填写。
- GPU 驱动、线材、转接器、扩展坞或 KVM 可能不透传 DDC/CI。
- 两台电脑需要位于可信局域网；防火墙放行时只选择专用网络。
- UDP v1 配对码用于降低局域网误触发风险，不提供加密或强身份认证。
- 当前构建产物是本地临时签名或未签名测试包，不等同于经过公证或商业代码签名的正式发行版。

## macOS 快速开始

### 构建

需要完整 Xcode。项目使用原生 Xcode 工程，`m1ddc` 仅作为可选兼容回退，不是运行依赖。

```bash
xcode-select -p
xcodebuild -version
./macOS/scripts/build-app.sh
```

构建脚本生成：

```text
macOS/outputs/DisplaySwitcher.app
macOS/outputs/DisplaySwitcher-macOS-<arch>.zip
```

脚本会构建 Release、进行本地临时签名、严格验签，并解压 ZIP 再次验证。推荐分发和安装 ZIP，而不是直接复制构建目录中的 `.app`。

### 安装与配置

将 ZIP 解压到 `/Applications` 后启动 `DisplaySwitcher.app`。首次使用时：

1. 在菜单栏打开“设置…”。
2. 检查自动检测到的显示器，为每台填写 Mac 与 Windows 输入源编号。
3. 如需 USB 自动切换，使用“学习 USB 设备…”选择稳定的 Hub 或键盘。
4. 确认配置后再主动启用 USB 自动切换或双端协同。

macOS 端支持动态数量的显示器，可联动或分别调节亮度、对比度和音量。Apple Silicon 优先使用内置 DDC/CI 后端，失败时可回退到已安装的 `m1ddc`。内置后端使用私有 CoreDisplay/IOAVService 接口，macOS 大版本升级后需要重新验证。

## Windows 快速开始

### 构建

构建机需要 Visual Studio，并安装“使用 C++ 的桌面开发”和 Windows App SDK C++ 组件。在 PowerShell 中执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Windows\build-windows.ps1
```

脚本会执行 x64 Release 构建和无硬件自动测试，生成：

```text
Windows\dist\DisplaySwitch.exe
Windows\dist\runtime\...
```

这是 framework-dependent 绿色版。复制或分发时必须保留整个 `Windows\dist\` 目录；构建会检查目录结构和小于 20 MiB 的体积限制。

### 安装与配置

1. 安装 Microsoft Windows App Runtime 2.4 x64。
2. 复制完整 `Windows\dist\` 目录并运行 `DisplaySwitch.exe`。
3. 从托盘菜单打开“设置…”，选择 USB 设备并添加实际显示器。
4. 优先尝试“Windows 原生 DDC/CI”；硬件链路不兼容时可配置 ControlMyMonitor 回退。
5. 配置完成后再启用自动切换和登录启动。

Windows 端的详细安装、后端选择和首次测试说明见 [`Windows/README.md`](Windows/README.md)。`Windows/DisplaySwitcher.Windows/` 是旧 C# 迁移参照，不参与正式构建。

## 启用双端协同

在两端分别配置：

- 对方的局域网 IP；
- 相同的 UDP 端口，默认 `49731`；
- 相同且至少 8 位的配对码；
- 同一个物理 USB Hub 或稳定 USB 设备；
- 每台显示器对应的本机与对端输入源。

随后在两端主动启用 USB 自动切换和 Mac / Windows 网络协同。首次实机测试应保持两台电脑均处于运行状态，并确保可以恢复显示器输入源；不要从整机睡眠、无人值守或远程环境开始测试。

## 自动测试与 CI

GitHub Actions 分别在 macOS 和 Windows 托管 runner 上执行构建、测试和测试包上传：

- macOS：Debug 构建、XCTest、Release 构建、打包和严格签名验证。
- Windows：x64 Release 构建、自动测试、绿色版结构/体积检查和 artifact 上传。
- 公共协议：两端共同验证 17 条消息向量和 16 条状态机向量。

自动测试使用虚拟时间、模拟网络和模拟硬件接口，不访问真实 UDP、USB、DDC、睡眠或唤醒设备。CI artifact 是短期保留的未签名测试产物，不是 GitHub Release。

公共向量也可以独立验证结构：

```bash
python3 contracts/protocol-v1/validate.py
```

## 仓库结构

```text
macOS/                 Swift/AppKit 正式实现、测试和构建脚本
Windows/               C++/WinUI 3 正式实现、测试和构建脚本
contracts/protocol-v1/ 公共 schema 与脱敏测试向量
specs/proposals/       尚未进入生效协议的协调提案
coordination/          跨平台功能状态与验收记录
handoffs/              两个平台 Agent 的交接记录
PROTOCOL.md            当前唯一生效的双端网络协议
```

开发或提交变更前请阅读 [`AGENTS.md`](AGENTS.md)、对应平台的开发清单以及 [`CONTRIBUTING.md`](CONTRIBUTING.md)。安全问题请按 [`SECURITY.md`](SECURITY.md) 提交。

## 隐私与安全

显示器 UUID、USB 标识、IP、配对码、本机路径和硬件配置只应保存在本机。它们不得进入网络同步数据、公共测试向量、日志、Issue 或 Git 提交。提交诊断信息前请手动检查并脱敏。

未经明确确认，不应通过开发或测试命令执行真实 DDC 输入源切换、USB 交接、显示器睡眠/唤醒、防火墙修改或其他可能造成黑屏的操作。

## 许可证

项目使用 [`MIT License`](LICENSE)。macOS 内置 DDC 后端基于 MIT 许可的 [AppleSiliconDDC](https://github.com/waydabber/AppleSiliconDDC)，第三方许可见 [`macOS/ThirdParty/AppleSiliconDDC/LICENSE`](macOS/ThirdParty/AppleSiliconDDC/LICENSE)。
