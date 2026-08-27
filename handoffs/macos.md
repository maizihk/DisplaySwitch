# macOS 交接记录

## 当前任务

- 日期：2026-08-28
- 功能：DS-004 / macOS 手动入口与关于页面收尾（M-004C）
- 分支：`codex/macos-ds-004-final-ui-about`
- 基线：`7703bab10eb432f9f276e35d74d3a896a556d21a`
- 当前已验证实现提交：待提交
- PR：待创建

## 完成内容

- 用户可见手动菜单只从完整且已开启的协同配置生成，标题使用配置自定义名称。
- 移除旧 `switchItem`、`switchToMacItem` 和仅服务固定平台入口的动作/状态代码；不再显示可触发的“切换到 Mac/本机”。
- USB 自动返回本机、v1 交接、输入源映射、防抖、重试与超时实现未改变；协议 v1 内部 `source=mac`、`target=windows` 字段保持不变。
- 设置、连接状态和提示在可用时显示配置名称或“本机/对端”，不再把用户目标固定写成 Windows/Mac。
- 关于页面使用公开 Bundle/静态信息展示图标、名称、简介、版本、架构、协议 v1、GitHub、MIT 许可证和第三方说明，并明确源码测试包不等同于正式签名公证版本。
- C-023 纯测试验证只读取 `CFBundleName`、`CFBundleShortVersionString`、`CFBundleVersion`，不读取或呈现 IP、配对码、USB/显示器标识或本机路径；内容模型没有 UDP、USB、DDC、唤醒或输入源切换依赖。
- C-021/C-022 补齐多 USB 候选等待明确选择，以及取消、30 秒超时、配置删除、迟到结果保留原绑定和学习期间零自动副作用测试。

## 本地自动验证

- 本机选定的 Xcode 27 Beta 6：
  - Debug 测试构建：`TEST BUILD SUCCEEDED`。
  - 相关 C-023/菜单测试：2 项，0 失败。
  - 配置及 C-021/C-022 测试：29 项，0 失败。
  - 全部 XCTest：54 项，0 失败。
  - 公共协议回归：17 条消息向量、16 条状态机向量继续通过。
  - Release：`BUILD SUCCEEDED`，包含 Standard Architectures。
- `DEVELOPER_DIR="$DEVELOPER_DIR" ./macOS/scripts/build-app.sh`：成功。
- 产物：`macOS/outputs/DisplaySwitcher.app`、`macOS/outputs/DisplaySwitcher-macOS-arm64.zip`。
- `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app`：通过。
- 文件同步提供程序曾向被忽略的输出 App 附加 Finder 扩展属性；仅清理该构建产物并重新临时签名后严格验签通过，未修改系统信任或工程签名设置。
- `git diff --check`：通过。
- GitHub Actions：等待 PR 创建后验证。

## 尚未执行

- 关于页面真实布局、深浅色显示、图标、链接点击。
- 菜单配置名称刷新和真实 USB 多候选选择交互。
- 真实 DDC、USB、网络、显示器唤醒和输入源切换；本任务没有访问这些接口。

## 安全与边界

- 只修改 `macOS/` 和 `handoffs/macos.md`。
- 未修改 Windows、协议、contracts、specs、coordination、GitHub Actions、根 README、版本、tag 或 Release。
- 未记录真实 IP、配对码、USB/显示器标识、本机绝对路径或个人硬件信息。
- `macOS/.build/` 和 `macOS/outputs/` 保持 Git 忽略。

## 回滚

- 回退本任务实现提交即可恢复旧菜单/关于页和 USB 候选处理；本任务不含协议、schema 或版本迁移。
