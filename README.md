# DisplaySwitch

[![macOS CI](https://github.com/maizihk/DisplaySwitch/actions/workflows/macos.yml/badge.svg)](https://github.com/maizihk/DisplaySwitch/actions/workflows/macos.yml)
[![Windows CI](https://github.com/maizihk/DisplaySwitch/actions/workflows/windows.yml/badge.svg)](https://github.com/maizihk/DisplaySwitch/actions/workflows/windows.yml)

DisplaySwitch 是一个面向多台 macOS / Windows 电脑共享显示器和 USB 键鼠场景的原生工具。macOS 菜单栏 App 与 Windows 托盘 App 可以分别控制显示器，也可以通过可信局域网执行用户明确选择的定向协同。USB 本机切换独立运行，不依赖网络确认。

项目不会替新用户猜测显示器、USB 设备、输入源、IP 或配对码。自动硬件操作在配置完整并由用户启用前保持关闭。

## 当前实现

| 平台 | 技术 | 主要能力 | 构建入口 |
| --- | --- | --- | --- |
| macOS | Swift / AppKit | 菜单栏控制、动态多显示器、亮度/对比度/音量、USB 学习与自动切换、本机协同配置 | `macOS/DisplaySwitcher.xcodeproj` |
| Windows | C++ / WinUI 3 | 托盘控制、动态多显示器、亮度/对比度/音量、原生 DDC/CI、USB 自动切换、本机协同配置 | `Windows/build-windows.ps1` |

当前 macOS 源码版本为 `2.1.0 (19)`，最低支持 macOS 12。Windows 端为 framework-dependent 绿色版，需要 Microsoft Windows App Runtime 2.4 x64，不依赖 .NET。历史 v2.1.0 安装包不代表当前 `main` 的安全基线，已暂时撤下公开下载；当前请从源码构建并将产物视为未签名测试版本。

两端实现遵循 [`PROTOCOL.md`](PROTOCOL.md) 中的 UDP v2 协同协议。公共认证、消息校验和状态机行为由 [`contracts/protocol-v2/`](contracts/protocol-v2/) 中的脱敏 schema 与测试向量约束。

## 工作方式

手动协同与 USB 本机切换是两条独立路径：

```text
手动选择“切换到 {配置名称}”          本机 USB 离开
        ↓                                  ↓
目标端唤醒并回复 target_ready          立即执行本机 DDC
        ↓                                  ├─ 可选：并行发送一次 wake_display
源端执行 DDC 并发送 committed             └─ 网络失败不等待、不回滚 DDC
```

手动协同只联系用户选择的目标；最近在线目标在 600 ms 内未确认时，仅对该目标执行本地兜底。USB 接入只请求本机唤醒。重复、过期、乱序和方向错误的消息不会重复触发硬件动作。

## 使用前须知

- 显示器必须支持 DDC/CI，并在显示器菜单中启用相关功能。
- 输入源编号取决于显示器和接口，必须由用户根据自己的设备填写。
- GPU 驱动、线材、转接器、扩展坞或 KVM 可能不透传 DDC/CI。
- 两台电脑需要位于可信局域网；防火墙放行时只选择专用网络。
- UDP v2 使用配对码派生的 HMAC-SHA256 验证消息身份和完整性；通信内容本身不加密，因此仍应只在可信局域网中使用。
- 当前构建产物是本地临时签名或未签名测试包，不等同于经过公证或商业代码签名的正式发行版。

完整平台、连接方式、验证等级和反馈模板见 [`COMPATIBILITY.md`](COMPATIBILITY.md)。

## macOS 快速开始

### 构建

需要完整 Xcode。项目使用原生 Xcode 工程；正式运行时只使用 Apple Silicon 原生 DDC 路径，不执行外部 DDC 工具。

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

需要在同一台开发 Mac 上稳定识别应用身份时，可以使用钥匙串中有效的 Apple Development 身份进行本地签名：

```bash
DISPLAYSWITCH_CODESIGN_IDENTITY="<codesigning identity SHA-1 or exact name>" \
  ./macOS/scripts/build-app.sh
```

该环境变量不写入工程、配置或产物名称；未设置时脚本仍使用 ad-hoc 签名，GitHub Actions 也不访问个人证书。Apple Development 只用于本机开发测试，不等同于 Developer ID、公证或正式发行签名。为避免 macOS 本地网络权限把不同测试副本记录为多个应用，签名身份和 Bundle Identifier 应保持不变，并始终将测试 App 替换安装到固定的 `/Applications/DisplaySwitcher.app`，不要直接运行不同解压目录中的副本。既有重复权限记录不会因稳定签名自动消失。

### 安装与配置

将 ZIP 解压到 `/Applications` 后启动 `DisplaySwitcher.app`。首次使用时：

1. 在菜单栏打开“设置…”。
2. 检查自动检测到的显示器，为每台配置名称、本机输入源和各协同配置对应的对端输入源。
3. 如需 USB 自动切换，使用“学习 USB 设备…”选择稳定的 Hub 或键盘。
4. 确认配置后再主动启用 USB 自动切换或双端协同。

macOS 端支持动态数量的显示器，可联动或分别调节亮度、对比度和音量。Apple Silicon 只使用内置 DDC/CI 后端；失败会明确报告，不调用 `m1ddc` 或软件调光回退。内置后端使用私有 CoreDisplay/IOAVService 接口，macOS 大版本升级后需要重新验证。Intel Mac 当前明确不支持原生 DDC。

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
4. 按需开启亮度、对比度、音量和显式回读；正式运行时只使用 Windows 原生 Dxva2，链路不兼容时会明确失败。
5. 配置完成后再启用自动切换和登录启动。

Windows 端的详细安装、原生 DDC 边界和首次测试说明见 [`Windows/README.md`](Windows/README.md)。`Windows/DisplaySwitcher.Windows/` 是旧 C# 迁移参照，不参与正式构建。

## 配置协同

两端都使用本机保存的“协同配置”描述目标电脑。配置名称由用户自定义，不根据名称推断对方是 Mac 还是 Windows。每个准备启用的配置至少需要：

- 对方的局域网 IP 或主机名；
- 相同的 UDP 端口，默认 `49731`；
- 相同且至少 8 位的配对码；
- 手动协同所需的每显示器对端输入映射。

菜单只为完整且已开启的配置显示 `切换到 {配置名称}`，不提供“切换到本机”，也不硬编码目标平台。当前仅支持 UDP v2；多个配置可以同时保存和启用，但每次手动协同只定向用户明确选择的一个配置。USB 自动切换使用独立的本机设备与显示器映射；可选网络联动也只能指定一个完整配置，不会广播或选择列表第一项。

首次实机测试应保持参与电脑均处于运行状态，并确保可以恢复显示器输入源；不要从整机睡眠、无人值守或远程环境开始测试。

## 自动测试与 CI

GitHub Actions 分别在 macOS 和 Windows 托管 runner 上执行构建、测试和测试包上传：

- macOS：Debug 构建、XCTest、Release 构建、打包和严格签名验证。
- Windows：x64 Release 构建、自动测试、绿色版结构/体积检查和 artifact 上传。
- 公共协议：两端共同验证 1 条 NFC 规范化向量、4 条认证向量、20 条消息向量和 6 条状态机向量。

自动测试使用虚拟时间、模拟网络和模拟硬件接口，不访问真实 UDP、USB、DDC、睡眠或唤醒设备。CI artifact 是短期保留的未签名测试产物，不是 GitHub Release。

公共向量也可以独立验证结构：

```bash
python3 contracts/protocol-v2/validate.py
```

## 仓库结构

```text
macOS/                 Swift/AppKit 正式实现、测试和构建脚本
Windows/               C++/WinUI 3 正式实现、测试和构建脚本
contracts/protocol-v2/ v2 公共 schema 与脱敏测试向量
specs/proposals/       尚未进入生效协议的协调提案
coordination/          跨平台功能状态与验收记录
handoffs/              两个平台 Agent 的交接记录
COMPATIBILITY.md       平台、连接路径、验证等级与脱敏反馈模板
PROTOCOL.md            当前唯一生效的双端网络协议
```

开发或提交变更前请阅读 [`AGENTS.md`](AGENTS.md)、对应平台的开发清单以及 [`CONTRIBUTING.md`](CONTRIBUTING.md)。安全问题请按 [`SECURITY.md`](SECURITY.md) 提交。公开仓库治理和旧安装包状态记录在 [`coordination/DS-006.md`](coordination/DS-006.md)。

## 隐私与安全

显示器 UUID、USB 标识、IP、配对码、本机路径和硬件配置只应保存在本机。它们不得进入网络同步数据、公共测试向量、日志、Issue 或 Git 提交。提交诊断信息前请手动检查并脱敏。

未经明确确认，不应通过开发或测试命令执行真实 DDC 输入源切换、USB 交接、显示器睡眠/唤醒、防火墙修改或其他可能造成黑屏的操作。

## 许可证

项目使用 [`MIT License`](LICENSE)。macOS 内置 DDC 后端基于 MIT 许可的 [AppleSiliconDDC](https://github.com/waydabber/AppleSiliconDDC)，第三方许可见 [`macOS/ThirdParty/AppleSiliconDDC/LICENSE`](macOS/ThirdParty/AppleSiliconDDC/LICENSE)。
