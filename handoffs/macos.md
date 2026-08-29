# macOS 交接记录

## 当前任务

- 日期：2026-08-29
- 功能：DS-009 / macOS 多显示器输入源并发
- 分支：`codex/macos-ds-009-native-display-control`
- 基线：`b611dbd0cdbceaa4dbccb0e4f933a2c49a0083e8`
- 本轮实现提交：本提交
- PR：[#46](https://github.com/maizihk/DisplaySwitch/pull/46)

## 原因与决策

- 原输入服务逐目标循环，且所有显示器共用一个全局硬件锁，导致多显示器输入切换被不必要地串行。
- 仲裁改为按规范化 selector 建立独立 lane：不同显示器并发；同一显示器跨事件仍串行，并继续与该显示器的亮度、对比度和音量互斥。
- 同一批次重复 selector 只执行一次写入，结果按原输入顺序和 stable ID 返回；单台失败不取消其他目标。
- USB、手动和协同入口继续共用同一个 `InputSourceSwitchService`。未改变 C2C、writeCycles/writeAttempts、VCP 帧、地址、matcher、租约、诊断、协议或 Windows。

## 修改范围

- `InputSourceSwitching.swift`：批次目标并发执行、selector 去重、结果稳定归位，并将硬件仲裁拆为按显示器 lane。
- `NativeDDC.swift`：普通原生 DDC 读写使用相同 selector lane，维持同显示器互斥。
- `InputSourceSwitchingTests.swift`：覆盖跨显示器并发、同显示器串行、批次去重、故障隔离、结果关联及跨显示器不互阻。
- `macOS/DEVELOPMENT_CHECKLIST.md`：校准 DS-009 多显示器输入切换状态。
- 未修改协议、Windows、版本号、tag、Release 或 GitHub Actions。

## 自动验证

- 输入源切换专项：15/15；完整 XCTest：107/107。
- 全新 Debug、Release 构建通过。
- `./macOS/scripts/build-app.sh` 在 `/private/tmp` 的干净源码副本通过；App 打包前和 ZIP 实际解压后严格 codesign 验证均通过。
- 仓库内脚本构建本身成功，但 File Provider 会即时恢复输出 App 的 FinderInfo，导致仓库输出路径直接验签失败；交付 ZIP 来自无该元数据的同源码干净构建。
- 所有测试使用模拟 resolver/transport；未执行真实 DDC、USB、网络、唤醒或输入源切换。
- 未触发云端 CI；PR #46 保持开放，不合并。

## 测试包

- 路径：`macOS/outputs/DisplaySwitcher-DS-009-parallel-input-macOS-test.zip`
- SHA-256：`09f98405bbea8a9c489d69586287d203896a4ec7489292ba010d7a204986dc3a`
- 无 `__MACOSX`、AppleDouble 和 Finder 扩展属性；实际解压后严格验签通过；构建产物不进入 Git。

## 尚需用户实机验证

1. 同一事件三台显示器是否近同时开始切换，且单台失败不影响其他显示器。
2. 同一显示器连续触发时是否仍保持串行，不与该显示器的亮度、对比度或音量操作并发。
3. C2C 偶发不执行问题仍保留，本轮没有调整其重试、服务生命周期或 matcher。

## 安全与工作区

- 三个未知重复文件保持未跟踪且不提交。
- `macOS/.build/` 和 `macOS/outputs/` 是忽略的本机构建产物。
