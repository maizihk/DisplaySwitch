# macOS 交接记录

## 当前任务

- 日期：2026-08-27
- 分支：`codex/macos-ds-004-config-safety`
- 清单：DS-004 / M-004A 配置迁移失败安全
- 基线：`2770cf86729dd109559582ce59d78edc461d82ab`
- PR：[#15 DS-004 macOS: Fail-safe configuration migration](https://github.com/maizihk/DisplaySwitch/pull/15)
- 最终实现提交：`6ac7c9274bcdb74f49804d0681a2b3bbbd526f8b`

## 完成内容

- 将旧 `Displays.Configuration.v1` Codable 数组明确视为本机 schema v1，新增 `Displays.Configuration.v2` 版本化文档：
  - `schemaVersion = 2`
  - `displays` 保留现有 `DisplayConfiguration` 字段和语义。
- 兼容读取和迁移 v1 Codable 数组以及更早的 `Display.1` / `Display.2` 键。
- 全新安装仍返回空配置，不猜测显示器、UUID 或输入源。
- 迁移先编码并验证写入新 v2 键；v1 数组和旧键均保留，不在迁移前删除或覆盖原数据。
- 损坏数据、未知 `schemaVersion`、编码失败和文档写入失败均返回显式错误，并持久记录需要用户检查。
- 已修复 PR #15 协调评审阻塞：v2、v1 数组和旧双显示器键均不存在时，加载路径仍会检查 `Displays.Configuration.RequiresReview`；标记为 `true` 时返回 `requiresUserReview(.previousFailureRequiresReview)`，不再误恢复为 `ready`。
- 自动重试、迁移或显示器检测不能清除安全标记；只有用户在设置窗口成功保存有效配置才能退出安全状态。
- 安全门已接入 App 运行路径：
  - 停止 USB 轮询并取消待执行 USB 交接。
  - 阻断 DDC 检测、回读、调节和输入源切换。
  - 阻断显示器唤醒。
  - 停止 UDP transport，取消状态机计时任务并阻断后续发送。
- `DDCController` 不再在构造时隐式读取配置，确保 App 先得到配置加载结果，再决定是否允许硬件和网络路径。
- 设置窗口会说明安全模式原因；保存失败时保持窗口和安全状态，不会部分启用自动化。
- 已校准 `macOS/DEVELOPMENT_CHECKLIST.md`：
  - M-004 依据已合并 PR #4、主线提交和 CI 标记为完成。
  - 新增 M-004A 真实自动验证状态，实机项保持未勾选。

## 自动验证

- 隔离 `UserDefaults` 和可替换失败存储共 16 项配置测试通过：
  - v1 数组成功迁移且原数据未覆盖。
  - 旧双显示器键成功迁移。
  - schema v2 正常读写。
  - 未知版本、损坏 JSON、编码失败和写入失败安全拒绝并保留原数据。
  - 迁移写入失败后的自动重试仍保持 review-required，用户成功保存后才解除。
  - 全新安装首次编码失败或 `writeDocument` 失败后，在无任何配置文档的模拟重启中仍保持 blocked，四类副作用均为 0；用户成功保存后才恢复 `ready`。
  - 安全状态下 USB、DDC、唤醒和网络副作用计数均为 0。
  - 全新安装和替换显示器仍不猜测输入源。
- PR #15 GitHub Actions run `33063113013` 在实现提交 `6ac7c9274bcdb74f49804d0681a2b3bbbd526f8b` 上完整通过：
  - Debug：`BUILD SUCCEEDED`。
  - 全部 XCTest：29 项，0 失败；包含 16 项配置测试以及现有 17 条消息向量、16 条状态机向量。
  - Release 与 `./macOS/scripts/build-app.sh`：`BUILD SUCCEEDED`，生成 App 和 arm64 ZIP。
  - 构建脚本内严格验签以及 CI 独立 `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app` 均通过。
- 本机环境仅可见 Command Line Tools，不具备可用的完整 Xcode；本地已完成 Swift 前端语法检查、`git diff --check` 和公共 17+16 向量结构校验，完整构建/测试/签名结论来自 Xcode 27 GitHub runner。

## 尚需实机验证

- 未人为损坏真实用户配置，未实际操作安全模式恢复 UI。
- 未执行真实 USB 交接、DDC 读写/输入源切换、显示器唤醒或 UDP 交接。
- 未改变网络协议、公共数据、Windows 实现或版本号。

## 回滚

- 回退 DS-004 macOS 实现提交即可恢复原读取逻辑。
- 旧 `Displays.Configuration.v1` 数组和 `Display.1` / `Display.2` 键在迁移后仍保留；回退时不需要从 v2 反向迁移。
