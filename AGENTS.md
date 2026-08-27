# DisplaySwitch 项目约束

Codex 在本仓库中执行任何开发、修复、测试、构建或发布任务时，都必须遵守本文件。具体任务状态分别记录在 `MACOS_DEVELOPMENT_CHECKLIST.md` 和 `Windows/DEVELOPMENT_CHECKLIST.md`，不要把临时任务写进本文件。

## 信息来源与平台边界

- `PROTOCOL.md` 是 Mac/Windows 双端通信的唯一规范。任何协议变化必须先更新规范、定义兼容策略和测试向量，再同步修改两端。
- macOS 正式实现位于 `Sources/DisplaySwitcher/`，使用 Swift/AppKit，由 `DisplaySwitcher.xcodeproj` 管理。
- Windows 正式实现位于 `Windows/DisplaySwitcher.Native/`，使用原生 C++/WinUI 3；`Windows/DisplaySwitcher.Launcher/` 是绿色版启动器。
- `Windows/DisplaySwitcher.Windows/` 只是旧 C# 迁移参照，不参与正式构建，不在其中实现新功能。
- 单平台任务不得顺手修改另一平台。确需跨端修改时，先说明原因、协议影响和需要同时验证的范围。
- 先检查现状和最近提交，从已完成的实现继续；禁止从头重写或重复已经完成的工作。

## 每次开始必须执行

1. 只读检查：

   ```text
   git status
   git branch --show-current
   git log --oneline -8
   git remote -v
   ```

2. 如果工作区不干净，先识别现有改动归属并完整保留；不要 pull、rebase、覆盖或丢弃未知改动。
3. 如果工作区干净且当前位于 `main`，执行：

   ```text
   git pull --ff-only origin main
   ```

4. 阅读 `PROTOCOL.md`，并按任务平台完整阅读：

   - macOS：`MACOS_DEVELOPMENT_CHECKLIST.md`、`README.md` 和相关 Swift/Xcode 文件。
   - Windows：`Windows/DEVELOPMENT_CHECKLIST.md`、`Windows/README.md` 和相关 C++/WinUI 3 文件。

5. 确认当前基线已经包含另一台电脑最近推送的提交。先说明准备处理的清单编号、发现的现状和最小修改范围，再开始编辑。
6. 除维护本文件这类一次性仓库设置外，不直接在 `main` 开发。新任务使用独立分支：

   ```text
   codex/macos-<task>
   codex/windows-<task>
   ```

   如果当前已有未提交工作，先保护现有改动，再决定如何切换分支；不要为了遵循分支规则而丢失工作。

## 实施原则

- 每次只完成一个可独立验证的主题；避免无关格式化、重命名和大范围重构。
- 保留现有 AppKit、WinUI 3、USB、UDP、DDC、登录启动和设置存储行为，除非当前任务明确要求修改。
- 配置迁移必须向后兼容。迁移失败时保留原数据，并进入不执行硬件动作的安全状态。
- 新安装不得猜测 USB、显示器、输入源、IP、路径或配对码。
- 网络状态探测不得触发 USB、DDC、显示器唤醒或输入源切换。
- 自动测试必须使用模拟时间、模拟网络和模拟硬件接口，不依赖真实局域网或设备。
- 代码、测试、文档和日志不得包含真实配对码、凭据、个人 IP、用户目录、签名密钥或未经脱敏的诊断信息。
- 不提交 `.build/`、`outputs/`、`bin/`、`obj/`、`dist/`、DerivedData、证书、本机配置或诊断日志。

## 硬件与系统安全

- 未经用户在当前任务中明确确认，不执行真实 DDC 输入源切换、真实 USB 交接、睡眠/唤醒测试或可能让显示器黑屏的命令。
- 未经确认，不修改防火墙、系统网络、登录项、系统权限或签名信任设置。
- 如果实机验证确有必要，先列出准确命令、目标设备、预期影响和恢复方法，然后等待确认。
- 枚举设备、读取不改变状态的信息、构建、单元测试、签名验证和普通 `status_probe/status_response` 可以执行，但不得输出配对码。

## 双机 Git 协作

- Mac 与 Windows 使用各自任务分支，禁止两个 Codex 同时自动 push `main`。
- 平台代码尽量只在对应平台目录修改；根 README、`PROTOCOL.md`、`AGENTS.md` 和社区文件属于共享文件，修改前先确认远端是否变化。
- 提交保持小而完整，每个提交必须处于可构建状态。
- 推送前执行 `git fetch origin`。远端发生变化时先审查差异；不要覆盖其他电脑的提交。
- 正常 push 当前任务分支并创建 PR。禁止 force push，禁止自动合并存在冲突或 CI 失败的 PR。
- PR 合并到 `main` 后，另一台电脑在开始新工作前必须重新同步 `main`。

## 每次结束必须执行

1. 运行与风险相称的自动测试和平台构建：

   - macOS：至少运行相关 XCTest；正式变更还要运行 `./scripts/build-app.sh` 和 `codesign --verify --deep --strict outputs/DisplaySwitcher.app`。
   - Windows：至少运行相关自动测试和 `Windows/build-windows.ps1` 的 x64 Release 构建。

2. 不启动真实硬件流程来凑测试结果。把自动验证与仍需实机验证的项目分开记录。
3. 执行并审查：

   ```text
   git diff --check
   git status
   git diff
   ```

4. 检查没有构建产物、配对码、凭据、本机秘密、个人路径或无关文件进入 Git。
5. 更新对应平台清单的真实状态；未完成或未实机验证的项目不得勾选为完全完成。
6. 创建清晰提交，fetch 并复查远端，然后正常 push 当前任务分支、创建或更新 PR，并检查 GitHub Actions。
7. 最终报告必须包含：

   - 完成的清单编号和问题原因。
   - 所有修改文件。
   - 自动测试、构建和 CI 结果。
   - 尚需实机验证的项目。
   - 分支、提交 SHA、PR 链接和最终 `git status`。

## 明确禁止

- 禁止 force push、破坏性重置或覆盖另一台电脑的提交。
- 禁止为了提速删除协议校验、重放保护、USB 防抖或超时兜底。
- 禁止擅自创建 Release、tag、修改版本号或写入个人开发者 Team ID。
- 禁止将 macOS 改成 SwiftUI、将 Windows 改回 C#，或创建第三套实现。
