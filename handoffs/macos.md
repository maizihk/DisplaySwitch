# macOS 交接记录

## 当前任务

- 日期：2026-08-28
- 功能：DS-004 / macOS M-005 DDC 后端正式接口化
- 分支：`codex/macos-ds-004-ddc-backends`
- 基线：`7c78c537e0ba47c4613063ba5f71560e336115e9`
- 当前已验证实现提交：`7f0816607e24e94f1c57ecbdb37076effbfe07a0`
- PR：[#23 DS-004 macOS: formalize DDC backends](https://github.com/maizihk/DisplaySwitch/pull/23)

## 完成内容

- 新增纯 Swift 的统一 DDC 接口，包含：
  - 后端可用性和枚举/读取/写入能力。
  - 按稳定逻辑显示器 ID 的枚举、VCP 读取和 VCP 写入。
  - 统一错误、取消 token、后端取消及异步结果提交边界。
- Apple Silicon 私有 CoreDisplay/IOAVService 和可选 `m1ddc` 已拆为两个独立后端：
  - Apple Silicon 优先使用原生硬件 DDC。
  - 原生后端不可用、目标不可用、读取失败或写入失败时按顺序回退到 `m1ddc`。
  - Intel Mac 不启用 Apple Silicon 私有后端；存在 `m1ddc` 时使用该硬件 DDC 后端，否则明确报告不支持。
  - 未加入或描述任何软件调光后端。
- 显示器的稳定逻辑 ID 与后端 selector 分离；枚举重排不会改变缓存、功能开关或读写目标的关联。
- 亮度 `0x10`、对比度 `0x12`、音量 `0x62` 继续遵守各显示器功能开关；关闭项不生成菜单滑块，也不会进入后端读写。
- 读取和缓存语义统一到可测试服务：
  - 单项成功返回零值合法。
  - 同一显示器三项均成功返回零时仍是不可信遥测，只显示稳定 ID/VCP 缓存或未知，不覆盖缓存。
  - 单项读取失败可使用该稳定 ID/VCP 的缓存估计值。
  - 新缓存按稳定逻辑 ID 和 VCP code 保存；旧 selector/index 缓存仍可读取。
- 写入按显示器独立执行；单台或单项失败不阻断其他显示器，只有成功写入才提交缓存。
- 配置安全状态、USB 学习安全状态、显式取消和配置重载会取消活动操作；安全门关闭时不进入后端，已在途的迟到结果不会更新 UI 或缓存。
- 设置中的本机检测仅显示静态后端选择说明，不枚举硬件、不读取或写入 DDC。
- 保留现有 AppKit、输入源切换、菜单控制、schema v3、协议 v1 和状态机行为；未实现 DS-005、协议 v2 或 HMAC。

## 自动验证

- 本机选定的 Xcode 27 Beta 6：
  - Debug：`BUILD SUCCEEDED`。
  - Release：`BUILD SUCCEEDED`，产物包含 arm64 和 x86_64。
  - XCTest：50 项，0 失败。
  - DDC 模拟后端测试：10 项，覆盖 C-016、C-017、C-018、C-019、C-020、C-024，以及原生可用/不可用/失败回退、取消与迟到读写、枚举重排和配置/USB 学习安全门零调用。
  - 本机配置测试：27 项，0 失败。
  - 公共协议回归：17 条消息向量、16 条状态机向量继续通过。
- `DEVELOPER_DIR="$DEVELOPER_DIR" ./macOS/scripts/build-app.sh`：成功。
- 产物：`macOS/outputs/DisplaySwitcher.app`、`macOS/outputs/DisplaySwitcher-macOS-arm64.zip`。
- `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app`：通过。
- `git diff --check`：通过。
- GitHub Actions macOS run [`33093199681`](https://github.com/maizihk/DisplaySwitch/actions/runs/33093199681) 在实现提交 `7f0816607e24e94f1c57ecbdb37076effbfe07a0` 上通过：Debug、50 项 XCTest、Release 打包、artifact 检查和严格 codesign 均成功。

## 尚需实机验证

- 经用户授权后，对 Dell 显示器执行只读原生 DDC 三项回读；当前不声称真实读数问题已解决。
- Apple Silicon 上原生写入、失败后 `m1ddc` 回退及输入源切换。
- Intel Mac 在安装和未安装兼容 `m1ddc` 两种情况下的后端选择和不支持提示。
- 真实多显示器的单项/单台失败隔离、功能开关与缓存恢复。
- 真实 USB、网络、唤醒、DDC 和输入源操作均未执行。

## 安全与边界

- 只修改 `macOS/` 和 `handoffs/macos.md`。
- 未修改 Windows、协议、contracts、specs、coordination、GitHub Actions、版本号、tag 或 Release。
- 未记录真实显示器 UUID、IP、配对码、USB 标识、本机绝对路径或个人硬件信息。
- `macOS/.build/` 和 `macOS/outputs/` 保持 Git 忽略。

## 回滚

- 回退实现提交可恢复旧的直接 DDCController 组合方式；本任务不改变 schema 或网络协议。
- 新缓存使用独立稳定 ID 键，旧 selector/index 缓存未删除，回退不会丢失旧缓存。
