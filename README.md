# 显示器控制

一个轻量的原生 macOS 菜单栏 App。它不显示 Dock 图标，也不会打开 Terminal，可以替代日常使用中的 MonitorControl 菜单栏功能。

当前 macOS 版本为 `2.1.0 (18)`。正式工程为原生 Swift/AppKit `DisplaySwitcher.xcodeproj`，最低支持 macOS 12。

功能包括：

- 分别调节显示器 1、显示器 2 的亮度、对比度和音量。
- 默认联动两台显示器；关闭“联动两台显示器”后可分别调节。
- 打开菜单时自动读取显示器当前值和最大值。
- 对显示器错误回报的 `max=0/1` 自动回退到 100，避免滑块被缩成一格。
- 当一台显示器的三个读取值同时异常为 0 时，不用错误值覆盖界面；显示上次设置值，`≈` 表示该值来自缓存而非硬件回读。
- 一键把两台显示器切换到 Windows 输入源。
- 启动时在后台读取显示器名称和 System UUID，并使用 UUID 作为稳定控制目标。
- 原生设置窗口，可配置 Windows 输入源、DDC 回读和登录启动。
- 设置窗口从标题栏到正文统一使用白色背景，内容卡片为浅灰色；鼠标进入顶部标签区时，贯穿整个窗口宽度的分隔线淡入，进入内容区时淡出。紧凑的“图标 + 文字”标签会同步更新窗口标题，选中项在 macOS 26 及以上使用不带蓝色染色的原生液态玻璃效果，图标和文字变蓝，并使用完整轮廓与均匀柔影强化四条边，旧系统自动回退为中性半透明材质。所有开关类功能使用 macOS 原生滑动开关，底部保存按钮始终可见。
- 单实例保护：重复打开 App 时，后启动的实例立即退出，避免出现多个菜单栏图标和重复执行自动切换。
- 可学习 USB 切换器上的键盘、鼠标或 USB Hub；设备消失时自动切到 Windows，也可选择是否在设备回到 Mac 时切换显示器。
- 可与 Windows 托盘版协同：目标端确认 USB 已接入并唤醒显示输出后，源端才切换显示器；网络失败时自动退化为直接切屏。

## 设置

点击菜单栏图标，选择“设置…”，可以配置：

- 是否联动调节两台显示器。
- 是否在登录 macOS 时自动启动；macOS 13 及以上使用系统 `SMAppService` 登录项。
- 自动检测到的显示器名称和 System UUID（只读）。
- 每台显示器的 Mac 输入源和 Windows 输入源编号。
- 切换到 Windows 时使用的输入源编号。
- 是否读取 DDC 当前值。Dell S2319HS 默认关闭读取，因为当前 HDMI 链路只能可靠写入、不能回读。

名称和 UUID 不写死在程序中，由下面的命令在每次启动时自动读取：

```text
/opt/homebrew/bin/m1ddc display list detailed
```

检测成功后会缓存结果；检测失败时保留上次成功检测到的名称和 UUID。菜单中的“重新检测显示器”可以手动刷新设备信息。

## USB 自动切换

1. 打开“设置…”。
2. 点击“学习 USB 设备…”。
3. 按一次 USB 切换器，让键鼠从当前电脑切到另一台电脑。
4. 从发生变化的设备中选择一个稳定的设备，优先选择有序列号的 USB Hub 或键盘。
5. 检查两台显示器的 Mac/Windows 输入源编号，启用“USB 自动切换”并保存。

自动切换规则：

```text
触发设备出现在 Mac   → 可检查显示器活动状态，只切换尚未在 Mac 上活动的显示器
触发设备从 Mac 消失   → 两台显示器切换到 Windows 输入源
```

“键鼠回到 Mac 时检查并按需切换显示器”默认关闭；打开后，App 使用自动检测到的显示器 UUID 与 macOS 当前活动显示器比较。两台都已在 Mac 时不发送命令，只有一台缺失时也只切换该显示器。少数显示器切换输入后仍会向 Mac 保持连接，此时 App 会保守地不操作，避免重复或错误切换。App 每 250 毫秒检查一次 USB 设备；USB 离开使用 150 毫秒防抖，回到 Mac 后的可选显示器检查仍使用 1 秒防抖。启动时只记录当前 USB 状态，不会立即切换显示器。默认输入源为：显示器 1 的 Mac/Windows 为 `15/18`，显示器 2 为 `17/15`，均可在设置中修改。

## Mac / Windows 双端协同

两端设置相同的 UDP 端口和配对码，并分别填写对方的局域网 IP。协同开启后，以 USB Hub 的实际归属作为物理确认：

```text
源端 USB 消失 → 通知目标端并重试 → 目标端唤醒显示输出
目标端确认 USB 已接入 → 回复确认 → 源端执行 DDC 切屏
```

USB 消失防抖为 150 ms。最近收到过对端心跳时，确认等待上限为 600 ms；对端离线时发送一次通知后立即切屏，不再等待无效超时。确认消息短间隔重复发送，等待期间 USB 回到源端会取消交接；超时后仍会切屏，退化成没有网络协同时的原有行为。重复、过期和乱序请求不会重复触发切换。具体消息格式见 `PROTOCOL.md`。

Windows 托盘版当前源码位于 `Windows/DisplaySwitcher.Native`，使用原生 C++/WinUI 3；托盘、USB、UDP 和登录启动分别调用 Win32 API。旧的 `Windows/DisplaySwitcher.Windows` C# 工程保留为迁移行为参照，不再由构建脚本发布。默认配置沿用已验证的环境：

```text
显示器后端：Windows 原生 DDC/CI 或 ControlMyMonitor（兼容模式）
ControlMyMonitor：D:\Soft\ControlMyMonitor\ControlMyMonitor.exe
小米：\\.\DISPLAY2\Monitor0，切到 Mac 输入 16
Dell：\\.\DISPLAY1\Monitor0，切到 Mac 输入 17
USB Hub：0BDA:5409
```

构建机安装 Visual Studio 的 C++ 桌面开发和 Windows App SDK C++ 组件后，以 PowerShell 执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Windows\build-windows.ps1
```

生成 framework-dependent 绿色版目录 `Windows\dist\`，根入口为 `DisplaySwitch.exe`，WinUI 程序及依赖集中在 `runtime` 子目录；整个目录构建时强制小于 20 MiB。分发时必须复制整个 `dist` 文件夹。目标电脑需预装 Microsoft Windows App Runtime 2.4 x64，不需要 .NET；首次运行进入托盘，打开“设置…”填写 Mac IP、与 Mac 相同的配对码，并选择原生 DDC/CI 或 ControlMyMonitor。Windows 防火墙提示时只允许“专用网络”。设置窗口可以读取当前 USB 设备并选择触发 Hub。

点击菜单栏的双显示器图标，再点“切换到 Windows”，App 会在后台并行执行：

```text
/opt/homebrew/bin/m1ddc display 1 set input 18
/opt/homebrew/bin/m1ddc display 2 set input 15
```

两台显示器的命令会并行执行，以缩短切屏时间。失败时会显示错误提示，方便判断是 `m1ddc` 路径、显示器编号还是输入源编号的问题。

## 亮度、对比度和音量

点击菜单栏图标，把鼠标移到“显示器 1”或“显示器 2”，即可使用三个滑块。松开滑块时，App 会在后台执行对应命令，例如：

```text
/opt/homebrew/bin/m1ddc display 1 set luminance 60
/opt/homebrew/bin/m1ddc display 1 set contrast 70
/opt/homebrew/bin/m1ddc display 1 set volume 30
```

显示器必须支持对应的 DDC/CI 控制项。没有扬声器或不支持 DDC 音量的显示器无法用音量滑块控制；这是显示器能力限制，不是 App 故障。

## 前置检查

确认已安装完整 Xcode，当前开发者目录指向 Xcode，并检查 `m1ddc` 是否就绪：

```bash
xcode-select -p
xcodebuild -version
test -x /opt/homebrew/bin/m1ddc && echo "m1ddc 已就绪"
/opt/homebrew/bin/m1ddc display list detailed
```

## 编译

在本项目目录执行：

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
```

项目的正式构建入口是 Xcode 原生工程，可直接打开：

```bash
open DisplaySwitcher.xcodeproj
```

完成后会生成：

```text
outputs/DisplaySwitcher.app
```

`scripts/build-app.sh` 使用 `xcodebuild` 构建 Release，自动使用当前 Mac 架构，将产物复制到输出目录后做本地临时签名和严格验证。`Package.swift` 仅作为迁移期参考，不再是正式构建入口。

如果 Xcode Beta 不在系统当前开发者目录，可在单次构建时指定：

```bash
DEVELOPER_DIR="/path/to/Xcode-beta.app/Contents/Developer" ./scripts/build-app.sh
```

将项目放在 NAS 或 File Provider 同步目录时，同步软件可能在构建后重新添加 Finder 扩展属性。脚本会在签名前清理它；若稍后手动严格验证时再次出现 `resource fork, Finder information`，先执行：

```bash
xattr -d com.apple.FinderInfo outputs/DisplaySwitcher.app 2>/dev/null || true
codesign --verify --deep --strict outputs/DisplaySwitcher.app
```

## 安装与运行

将 App 复制到“应用程序”目录，然后打开：

```bash
cp -R outputs/DisplaySwitcher.app /Applications/
open /Applications/DisplaySwitcher.app
```

顶部菜单栏会出现双显示器图标。App 使用临时本地签名；首次运行若被 macOS 拦截，可在 Finder 中右键 App，选择“打开”，再确认一次。

## 设置登录启动

1. 打开“系统设置”。
2. 进入“通用”→“登录项与扩展”。
3. 在“登录时打开”区域点击 `+`。
4. 选择 `/Applications/DisplaySwitcher.app`。

以后登录 macOS 时，它会静默出现在顶部菜单栏。

## 修改显示器参数

编辑 `Sources/DisplaySwitcher/main.swift` 中的 `commands` 数组，然后重新运行构建脚本。输入源编号由显示器决定；当前配置保持为显示器 1 使用 `18`、显示器 2 使用 `15`。
