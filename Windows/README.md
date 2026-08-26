# Windows 托盘版安装与测试

## 安装

1. 在目标电脑安装一次 Microsoft Windows App Runtime 2.4 x64（已安装则跳过）。程序本身不依赖 .NET。
2. 将整个 `Windows\dist\` 目录复制到固定位置，例如 `D:\Soft\DisplaySwitcher\`。这是 C++/WinUI 3 framework-dependent 绿色版，必须保留 EXE 旁的 DLL、XBF、PRI 和 WinMD 文件。
3. 确认 `D:\Soft\ControlMyMonitor\ControlMyMonitor.exe` 已存在。
4. 双击启动。程序没有主窗口，会显示在 Windows 右下角托盘区域。
5. Windows 防火墙询问时，只允许“专用网络”。
6. 右键托盘图标，打开“设置…”。

程序是本地构建、未购买商业代码签名证书的版本。SmartScreen 如果提示未知发布者，请检查文件来源后选择“更多信息”→“仍要运行”。

## 两端设置

Windows 端填写：

- Mac 的局域网 IP。
- 通信端口，默认 `49731`。
- 至少 8 位配对码。
- 点击“读取当前 USB”，选择 `4-Port USB 2.0 Hub (0BDA:5409)`。
- 检查 ControlMyMonitor 和两台显示器参数。
- 根据需要开启“登录 Windows 时自动启动”。

Mac 端进入菜单栏“设置…”→“双端协同”，填写：

- Windows 的局域网 IP。
- 与 Windows 相同的端口和配对码。
- 开启“启用 Mac / Windows 网络协同”。
- USB 自动切换也必须开启，并使用同一个物理 Hub 作为触发设备。

## 首次测试

先保持两台电脑都处于运行状态，不测试整机睡眠：

1. 显示器和 USB 键鼠都在 Mac。
2. 按 USB 切换器切到 Windows。
3. Windows 收到 USB 后唤醒显示输出并回复；Mac 随后把显示器切到 Windows。
4. 再按一次切回 Mac。
5. Mac 收到 USB 后唤醒显示输出并回复；Windows 按“小米 16、Dell 17”切回 Mac。

如果网络通信失败，2.5 秒后源端仍会执行切屏，不会永久卡住。托盘菜单顶部会显示最近状态。

## 默认 ControlMyMonitor 参数

```text
小米：\\.\DISPLAY2\Monitor0，VCP 60，Mac 输入 16
Dell：\\.\DISPLAY1\Monitor0，VCP 60，Mac 输入 17
```

程序按“小米 → Dell”的顺序执行，每台失败后重试一次。设备路径变化时可直接在设置中修改。

## 构建

构建机需要 Visual Studio（安装“使用 C++ 的桌面开发”和 Windows App SDK C++ 组件）。执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Windows\build-windows.ps1
```

脚本生成 `Windows\dist\DisplaySwitcher.Windows.exe` 及其少量伴随文件，并检查整个目录小于 20 MiB。目标电脑只需 Windows App Runtime 2.4 x64；不需要 .NET SDK，也不需要 Visual C++ Redistributable（本项目 Release 使用静态 C/C++ 运行库）。
