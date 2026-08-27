# Windows 交接记录

## 当前任务

- 日期：2026-08-27
- 分支：`codex/windows-w004-ci`
- 共享基线：`925d9634db2e7176df9dd7678ae7468e8f2ab1e2`
- 清单：W-004 Windows CI / DS-002
- 最终功能提交：`4ffd077c44d911c72a5a9db40ea79317b952c4df`
- PR：[#9](https://github.com/maizihk/DisplaySwitch/pull/9)
- Windows workflow run：[#1](https://github.com/maizihk/DisplaySwitch/actions/runs/33056123299)

## 完成内容

- 新增 `.github/workflows/windows.yml`，在 `windows-2025-vs2026` 托管映像上执行 x64 Release 构建、自动测试、绿色版结构/体积检查和 artifact 上传。
- workflow 支持 pull request、main push 和手动触发；路径限定为 Windows、协议契约及 workflow 自身，并使用并发取消和 45 分钟超时。
- 权限仅为 `contents: read`，使用 `actions/checkout@v6` 和 `actions/upload-artifact@v6`；未使用项目 secret、签名或任何硬件配置。
- 未修改 `Windows/build-windows.ps1`、三个工程、Windows 应用运行时代码、共享协议或 macOS 源码。

## GitHub 托管 CI 验证

- runner：`windows-2025-vs2026`，Windows Server 2025，映像版本 `20260818.207.1`，Visual Studio 18.9 / MSBuild 18.9.1。
- PR #9 的 Windows run #1 从全新 GitHub 托管环境完成 NuGet 恢复、三个原生 C++ 工程的 x64 Release 构建及测试，所有步骤通过。
- 构建脚本和 workflow 的显式测试步骤均输出：`DS-001 passed 17 message vectors and 16 state-machine vectors`；没有局域网或真实硬件依赖。
- `Windows/dist/` 结构检查通过：根目录为 `DisplaySwitch.exe`，`runtime/` 包含 `DisplaySwitcher.Windows.exe`、PRI、WinMD、Windows App Runtime bootstrap DLL 和两个 XBF 文件，共 7 个文件、1.30 MiB。
- artifact：`DisplaySwitcher-Windows-x64-unsigned-framework-dependent`，完整上传 `Windows/dist/`，ZIP 637,904 bytes，保留 7 天；artifact ID `9639820437`。
- framework-dependent 产物仍要求目标电脑安装 Windows App Runtime 2.4 x64；workflow 不进行签名。

## 本机验证

- `Windows/build-windows.ps1` x64 Release 构建和全部自动测试通过，日志明确显示 17 组消息向量和 16 组状态机向量通过。
- 本机 `Windows/dist/` 为 1.28 MiB，入口和 6 个 runtime 文件均存在，构建产物未提交到 Git。
- 本机验证复用已安装的开发环境；GitHub CI 则在全新托管 runner 上恢复依赖和构建，证明构建不依赖本机缓存或个人路径。

## 尚需验证

- 未启动应用，也未执行真实 UDP 通信、DDC 输入源切换、USB 交接、显示器睡眠/唤醒或防火墙修改。
- 未创建签名、Release 或 tag；PR #9 保持未合并，等待协调层评审。

## 对其他平台和共享文件的影响

- 无。没有修改 macOS、`PROTOCOL.md`、`contracts/`、`specs/` 或 `coordination/`。

## 回滚

- 回退 workflow 提交 `4ffd077c44d911c72a5a9db40ea79317b952c4df` 即可移除 Windows CI；Windows 应用、构建脚本和配置格式均未变化。
