# macOS 交接记录

## 当前任务

- 日期：2026-08-27
- 功能：DS-004 / macOS 第一阶段本机模型、配置迁移和 UI
- 分支：`codex/macos-ds-004-local-model`
- 基线：`8466c120c15607e7f39645c494b2786eac1f12ac`
- 实现提交：`26c1e93`
- handoff 提交：`aad8528`
- PR：[#20 DS-004 macOS: add schema v3 local collaboration model](https://github.com/maizihk/DisplaySwitch/pull/20)

## 完成内容

- 本机配置升级为 `schemaVersion = 3`，全新安装随机生成并持久化 `localEndpointID`，不从硬件或用户信息派生。
- 显示器目录与 `collaborationProfiles` 分离：
  - 显示器使用稳定随机 UUID，保存本机输入源和三项控制能力开关。
  - 协同配置独立保存名称、host、port、pairing code、已确认 peer endpoint/协议版本、显示器输入映射和本机触发设备引用。
  - 配置支持添加、删除、重命名、排序和多个同时开启；至少保留一个配置。
- 配对码以 NFC 规范化后 8–128 UTF-8 字节验证；空配对码只允许保存未完成且未启用的配置。
- v2 迁移将 `macInput` 写入全局 `localInput`，将 `windowsInput` 按稳定显示器 ID 写入默认旧对端配置；旧 v2/v1/双显示器键不删除、不覆盖。
- 未知 schema、损坏数据、重复 UUID、重复配置名、非法范围、编码/写入/回读失败均持久进入安全状态；只有用户成功保存有效配置才解除。
- 孤立显示器映射原样保留并由本机检测报告，不自动绑定到新显示器。
- peer endpoint 或协议版本变化只返回需要用户确认的纯结果，不自动覆盖已确认值。
- 设置页“协同”支持多配置管理；检测按钮只做本机完整性和静态 DDC 后端能力检查，零网络与硬件动作。
- 菜单不再显示“切换到本机”，只为已开启配置生成 `切换到 {配置名称}`；每个入口只读取该配置的显示器映射。
- 未实现 DS-005 v2 UDP、HMAC 或新消息状态机；现有 v1 运行时和公共向量保持不变。

## 自动验证

- Xcode 27 Beta 6（`/Users/maizi/Downloads/Xcode-beta.app`）：
  - Debug：`BUILD SUCCEEDED`。
  - Release：`BUILD SUCCEEDED`。
  - XCTest bundle：32 项，0 失败。
  - 本机配置测试：19 项，覆盖 C-001 至 C-015 的 macOS 适用路径、0/1/多显示器、迁移、孤立映射、重排、非法范围、持久安全状态和 peer identity 确认。
  - 公共协议回归：17 条消息向量、16 条状态机向量继续通过。
- `DEVELOPER_DIR=/Users/maizi/Downloads/Xcode-beta.app/Contents/Developer ./macOS/scripts/build-app.sh`：成功。
- 产物：`macOS/outputs/DisplaySwitcher.app`、`macOS/outputs/DisplaySwitcher-macOS-arm64.zip`。
- `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app`：通过。
- `git diff --check`：通过。
- Xcode 27 Beta 6 的 `xcodebuild test` 在当前中文路径下错误报告找不到实际存在的 test bundle executable；使用同一 Xcode 构建出的 `xctest` 直接执行 bundle，完整 32 项测试通过。这是测试启动器问题，不是编译或测试失败。

## 尚需实机验证

- 设置页添加、删除、排序、重命名多个配置及菜单即时刷新。
- 真实 USB 学习后触发引用写入所选配置。
- 不同 macOS/硬件上的本机 DDC 后端能力提示。
- 真实 UDP、USB、蓝牙、DDC、显示器唤醒和输入源切换均未执行。

## 安全与边界

- 只修改 `macOS/` 和 `handoffs/macos.md`。
- 未修改 Windows、协议、contracts、specs、coordination、GitHub Actions、版本号、tag 或 Release。
- 未记录或提交真实配对码、用户秘密、Team ID、证书或本机签名配置。
- `macOS/.build/` 和 `macOS/outputs/` 保持 Git 忽略。

## 回滚

- 回退实现提交即可恢复 schema v2 代码。
- v3 迁移保留旧 v2/v1/双显示器数据；回退前需恢复旧数据或执行经过验证的显式反向转换，不能让旧版本直接解释 v3 文档。
