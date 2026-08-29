# macOS 交接记录

## 当前任务

- 日期：2026-08-29
- 功能：DS-009 / macOS M-009 C2C 输入源链路诊断
- 分支：`codex/macos-ds-009-native-display-control`
- 基线：`ae1284f8d67056abebc3f2c73cd8decbfe4844a3`
- 本轮实现提交：本提交
- PR：[#46](https://github.com/maizihk/DisplaySwitch/pull/46)

## 原因与决策

- C2C 输入切换低成功率尚不能由重试或 service 生命周期假设解释；本轮只补证据链，不改变输入写次数、延时、重试、1 秒租约或普通 DDC 行为。
- 每次切换使用一个操作 ID，将目标、resolver、候选 service、选择理由、实际 `IOAVServiceWriteI2C` 和同一 service 的 VCP `0x60` 读回串联。
- `KERN_SUCCESS` 只记录为传输层接受，绝不当作显示器执行成功；读回区分目标值、另一输入值、其他值和不可用。
- 候选 service 只记录，不向未选候选试写。service 和显示器使用进程会话匿名索引，不记录真实 UUID、序列号或 IORegistry 路径。
- 被叫停的“移除租约/首写成功即停止”实验已隔离在本机 stash，不进入本提交；三个未知重复文件继续原样保留。

## 修改范围

- `InputSourceSwitching.swift`：增加有界会话诊断存储、匿名显示器/service 索引、诊断上下文与传输/设备反馈分层事件。
- `DDCBackend.swift`：把既有 matcher 的公共匹配证据投影为脱敏候选记录，不改变 matcher 决策。
- `NativeDDC.swift`：记录实际输入源 WriteI2C 帧、chip/address/offset、attempt/cycle、返回码和耗时；写后只在同一已选 service 读取 VCP `0x60` 作为设备层反馈。
- `main.swift`：USB 与手动/协同入口传入来源和另一输入值；托盘增加“复制输入切换诊断”。
- `InputSourceSwitchingTests.swift`：增加调用链、候选、多候选零误写、设备反馈分层、匿名索引稳定和脱敏测试。
- 未修改协议、Windows、版本号、tag、Release 或 GitHub Actions。

## 自动验证

- 全新 Debug DerivedData `build-for-testing` 通过。
- 输入源诊断专项：12/12；完整 XCTest：104/104。
- Debug、Release 和 `./macOS/scripts/build-app.sh` 通过。工作区输出目录的 File Provider 会即时恢复 Finder 扩展属性，直接严格验签报告元数据污染；使用不携带扩展属性的同一构建 App 打包后，打包前及实际解压后 `codesign --verify --deep --strict` 均通过。
- 所有测试使用模拟 resolver/transport；未执行真实 DDC、USB、网络、唤醒或输入源切换。
- 未触发云端 CI；PR #46 保持开放，不合并。

## 测试包

- 路径：`macOS/outputs/DisplaySwitcher-DS-009-C2C-diagnostic-macOS-test.zip`
- 要求：无 `__MACOSX`、AppleDouble 和 Finder 扩展属性；实际解压后严格验签。
- SHA-256、大小和构建时间在最终交付报告中记录，构建产物不进入 Git。

## 尚需用户实机验证

1. C2C 连接执行 3 次输入切换，复制诊断。
2. C2DP 连接执行 3 次相同切换，复制诊断。
3. 对比候选数量、会话匿名 service、选择理由、实际 WriteI2C 返回及 VCP `0x60` 反馈，判断失败位于匹配、系统调用还是设备执行层。
4. 在日志证据确认前，不向备选 service 试写，不继续调整重试或生命周期。

## 安全与工作区

- 三个未知重复文件保持未跟踪且不提交。
- 被叫停实验保存在本机 `stash@{0}`，未恢复、未删除。
- `macOS/.build/` 和 `macOS/outputs/` 是忽略的本机构建产物。
