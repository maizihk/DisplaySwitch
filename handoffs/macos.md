# macOS 交接记录

## 当前任务

- 日期：2026-08-28
- 功能：DS-006 / macOS 公开文档与样例清理
- 分支：`codex/macos-ds-006-public-docs`
- 基线：`04b7a9397d84735d28de709a142950b3670f4cb1`
- 当前已验证实现提交：`55d933bd077d4f04fab5885e38fed70df1393ad1`
- PR：[#26 DS-006 macOS: sanitize public display samples](https://github.com/maizihk/DisplaySwitch/pull/26)

## 完成内容

- C-023 关于页面已按代码路径核对：
  - 展示 App 图标、公共简介、Bundle 版本和 GitHub 项目链接。
  - 页面创建只组装 AppKit 视图并读取公开 Bundle 元数据，不读取本机配置。
  - 打开页面不调用 DDC、USB、网络、显示器唤醒或输入源切换接口。
- C-024 公开模拟测试已清除具体设备品牌标签：
  - 测试名称和稳定 ID 改为中性的模拟显示器名称。
  - 三项全部成功返回零仍判为不可信遥测。
  - 已有亮度缓存继续作为估算值返回，其他无缓存项不采信，缓存写入次数保持为零。
- macOS 开发清单和交接记录不再使用具体设备品牌描述公开样例或待验硬件。
- 未改变 AppKit UI、运行代码、DDC 行为、网络协议、本机 schema、版本或签名设置。

## 自动验证

- 本机选定的 Xcode 27 Beta 6：
  - Debug 测试构建：`TEST BUILD SUCCEEDED`。
  - XCTest：50 项，0 失败。
  - DDC 模拟后端测试：10 项，0 失败；中性名称的 C-024 回归已实际执行。
  - 本机配置测试：27 项，0 失败。
  - 公共协议回归：17 条消息向量、16 条状态机向量继续通过。
  - Release：`BUILD SUCCEEDED`，包含 Standard Architectures。
- `DEVELOPER_DIR="$DEVELOPER_DIR" ./macOS/scripts/build-app.sh`：成功。
- 产物：`macOS/outputs/DisplaySwitcher.app`、`macOS/outputs/DisplaySwitcher-macOS-arm64.zip`。
- `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app`：通过。
- 输出目录由文件同步提供程序附加的 Finder 扩展属性曾导致独立严格验签拒绝；只清除被忽略构建产物的扩展属性并重新临时签名后通过，未修改系统签名信任或工程设置。
- `git diff --check`：通过。
- GitHub Actions macOS run [`33099308922`](https://github.com/maizihk/DisplaySwitch/actions/runs/33099308922) 在实现提交 `55d933bd077d4f04fab5885e38fed70df1393ad1` 上通过：Debug、50 项 XCTest、Release 打包、artifact 检查和严格 codesign 均成功。

## 尚需实机验证

- 关于页面的真实界面布局、图标、简介、版本和 GitHub 链接点击。
- 经用户另行授权后，对特定外接显示器执行只读原生 DDC 三项回读；当前不声称真实原生读数问题已解决。
- Apple Silicon 原生 DDC 与 `m1ddc` 回退、Intel Mac 后端选择及真实多显示器失败隔离。
- 真实 USB、网络、唤醒、DDC 和输入源操作均未执行。

## 安全与边界

- 只修改 `macOS/` 和 `handoffs/macos.md`。
- 未修改 Windows、协议、contracts、specs、coordination、GitHub Actions、根 README、版本号、tag 或 Release。
- 未记录真实显示器 UUID、IP、配对码、USB 标识、本机绝对路径或个人硬件信息。
- `macOS/.build/` 和 `macOS/outputs/` 保持 Git 忽略。

## 回滚

- 回退实现提交即可恢复旧测试标签和平台文档；本任务没有运行时、协议、schema 或用户配置迁移影响。
