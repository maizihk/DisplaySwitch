# DisplaySwitch

[![macOS CI](https://github.com/maizihk/DisplaySwitch/actions/workflows/macos.yml/badge.svg)](https://github.com/maizihk/DisplaySwitch/actions/workflows/macos.yml)
[![Windows CI](https://github.com/maizihk/DisplaySwitch/actions/workflows/windows.yml/badge.svg)](https://github.com/maizihk/DisplaySwitch/actions/workflows/windows.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

DisplaySwitch 是一个面向多电脑共享显示器、键盘和鼠标场景的原生 macOS 菜单栏 / Windows 托盘工具。它通过 DDC/CI 调节显示器，并可在 USB 设备离开或用户手动选择目标时切换显示器输入源。

> **项目状态**
>
> 当前 `main` 为 2.1.0（build 19）源码基线。历史安装包已撤下；目前请从源码构建，并将产物视为开发测试版本，而非经过公证或商业签名的正式发行版。

## 核心能力

- **显示器控制**：分别或联动调节多台显示器的亮度、对比度和音量。
- **USB 自动切换**：监听一个由用户明确选择的本机 USB 设备；离开时切换显示器输入源，接入时唤醒本机显示器。
- **双机协同**：在可信局域网中，通过用户配置的目标和配对码协调 macOS / Windows 切换。
- **动态显示器管理**：保留暂时离线的显示器配置；只有在可信检测后才允许用户手动删除。
- **安全失败**：设备、拓扑、输入源或网络身份不完整时不猜测、不试写、不自动降级到其他工具。
- **本机诊断**：普通界面只显示简明结果；详细诊断默认关闭，并对设备与网络信息进行脱敏。

## 平台与要求

| 平台 | 正式实现 | 系统要求 | DDC 路径 |
| --- | --- | --- | --- |
| macOS | Swift / AppKit | Apple Silicon，macOS 12 或更高版本 | CoreDisplay / IOAVService 原生后端 |
| Windows | C++ / WinUI 3 | x64，Windows 10 1809 或更高版本 | Windows Dxva2 原生后端 |

Windows 绿色版需要 Microsoft Windows App Runtime 2.4 x64，不依赖 .NET。Intel Mac 当前不支持原生 DDC。

无论使用哪个平台，还需要：

- 显示器支持并已启用 DDC/CI；
- 当前 GPU、接口、线材、转接器、扩展坞或 KVM 能够透传 DDC/CI；
- 需要协同时，两台电脑位于可信局域网；
- 用户自行确认每台显示器的输入源编号。

硬件支持取决于完整连接链路，而不只取决于显示器型号。详见 [兼容性与验证边界](COMPATIBILITY.md)。

## 工作方式

USB 本机切换和手动协同是两条独立路径：

```text
USB 设备离开                         手动选择“切换到 {配置名称}”
      │                                         │
      ├─ 立即执行本机输入源切换                 ├─ 请求目标端唤醒
      └─ 可选：通知一个明确的协同目标             └─ 目标确认后执行本机输入源切换
```

USB 切换不等待网络，也不会因网络失败回滚本机 DDC。手动协同只联系用户选择的目标，不广播，也不会根据设备名称猜测目标平台。

## 快速开始

### 1. 构建

macOS 需要完整 Xcode：

```bash
xcode-select -p
xcodebuild -version
./macOS/scripts/build-app.sh
```

输出位于：

```text
macOS/outputs/DisplaySwitcher.app
macOS/outputs/DisplaySwitcher-macOS-<arch>.zip
```

Windows 需要 Visual Studio、C++ 桌面开发组件和 Windows App SDK C++ 组件：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Windows\build-windows.ps1
```

输出位于：

```text
Windows\dist\DisplaySwitch.exe
Windows\dist\runtime\...
```

Windows 分发时必须保留完整的 `Windows\dist\` 目录。更完整的构建和运行说明见 [Windows README](Windows/README.md)。

### 2. 安装

- **macOS**：解压 ZIP，将 `DisplaySwitcher.app` 放到固定的 `/Applications` 目录后启动。
- **Windows**：安装 Windows App Runtime 2.4 x64，将完整 `dist` 目录复制到固定位置，再运行 `DisplaySwitch.exe`。

macOS 构建脚本默认使用 ad-hoc 签名。需要稳定保留本机权限记录时，可指定钥匙串中的 Apple Development 身份：

```bash
DISPLAYSWITCH_CODESIGN_IDENTITY="<identity SHA-1 or exact name>" \
  ./macOS/scripts/build-app.sh
```

Apple Development 签名仅用于本机测试，不等同于 Developer ID 或公证。

### 3. 首次配置

1. 打开托盘或菜单栏中的“设置…”。
2. 检测显示器，确认数量、名称和连接状态正确。
3. 先使用只读操作验证 DDC，再开启需要的亮度、对比度或音量控制。
4. 为需要切换的显示器填写输入源；不参与切换的显示器保持留空，不要填写 `0`。
5. 如需 USB 自动切换，学习一个稳定的 Hub 或键盘，并配置对应输入源。
6. 如需双机协同，在两端填写目标地址、相同端口、相同配对码和对应输入源。
7. 所有映射确认无误后，再开启 USB 自动切换或协同配置。

输入源切换可能立即导致黑屏。首次测试前应保留显示器实体按键或其他恢复输入源的方法。

## 双机协同

两端遵循 [UDP v2 协同协议](PROTOCOL.md)，默认端口为 `49731`。每个协同配置至少包含：

- 用户自定义的配置名称；
- 对端局域网 IP 或主机名；
- 两端一致的 UDP 端口；
- 两端一致且至少 8 位的配对码；
- 需要切换的每显示器输入源映射。

协议使用 PBKDF2-HMAC-SHA256 派生密钥并验证消息身份、完整性、方向、时间窗和重放。通信内容本身不加密，因此只应在可信局域网内使用。

## 安全与隐私

- 新安装默认关闭 USB、协同和 DDC 写入，不猜测设备或输入源。
- 网络检测只验证协同能力，不执行 USB、唤醒、DDC 或输入源切换。
- 原始显示器身份、USB 标识、IP、配对码和本机路径只保存在本机，不作为双端同步数据。
- macOS DDC 使用 Apple 私有显示接口，系统大版本更新后需要重新验证。
- Windows 远程桌面、虚拟/镜像目标或不完整拓扑不会作为可信物理显示器执行 DDC。
- 自动测试使用模拟网络、USB、时钟和显示器，不能代替真实硬件验证。

提交问题前请使用 [兼容性报告模板](COMPATIBILITY.md#anonymized-compatibility-report-template) 并删除个人信息。安全漏洞请按 [安全策略](SECURITY.md) 私下报告。

## 文档

| 文档 | 内容 |
| --- | --- |
| [COMPATIBILITY.md](COMPATIBILITY.md) | 硬件兼容性、连接路径与安全测试顺序 |
| [Windows/README.md](Windows/README.md) | Windows 安装、配置、DDC 与测试说明 |
| [PROTOCOL.md](PROTOCOL.md) | 当前唯一生效的双端通信规范 |
| [contracts/protocol-v2](contracts/protocol-v2/) | 协议 schema 与跨端测试向量 |
| [contracts/usb-switch-v1](contracts/usb-switch-v1/) | USB 状态机公共测试合同 |
| [SUPPORT.md](SUPPORT.md) | 获取支持与提交问题 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 开发与贡献流程 |

正式源码位于 `macOS/` 和 `Windows/DisplaySwitcher.Native/`。`Windows/DisplaySwitcher.Windows/` 仅为旧 C# 迁移参照，不参与正式构建。

## License

DisplaySwitch 使用 [MIT License](LICENSE)。macOS DDC 后端基于 MIT 许可的 [AppleSiliconDDC](https://github.com/waydabber/AppleSiliconDDC)，完整第三方声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
