# macOS 交接记录

## 当前任务

- 日期：2026-08-29
- 功能：DS-009 / macOS M-009 输入 service 一次性生命周租约实验
- 分支：`codex/macos-ds-009-native-display-control`
- 基线：`5bb668eca6317794dcad00cc1456dd7c4a23d91f`
- 本轮实现提交：本提交
- PR：[#46](https://github.com/maizihk/DisplaySwitch/pull/46)

## 原因与决策

- 实机新证据是专用输入服务版约 25 次偶尔成功 1 次：VCP `0x60`、目标值和显示器能力已被证明有效，但 service 生命周期或 selector 映射仍存在竞争。
- 本轮是单变量实验：`writeInput` 返回后仅把当次 transport 移交给专用 retainer，异步强引用 1 秒后自动释放；不 sleep、不阻塞切换线程。
- 下一次切换仍必须调用 resolver 获得不同 transport，绝不复用租约对象。retainer 默认最多保留 32 个 transport，快速操作超限时释放最旧租约。
- 未改动 matcher、resolver 映射、VCP 报文/目标值/写次数、读取事务、串行顺序、USB、协同、协议或 UI。

## 修改范围

- `InputSourceSwitching.swift` 仅增加可注入的租约调度器、上限 32 的 retainer，以及 SetVCP 返回后的一次性移交。
- `InputSourceSwitchingTests.swift` 将原 fresh resolve 测试扩展为“立即保留、1 秒到期释放、第二次不同 transport”，并新增 100 次快速切换租约上限测试。
- 未修改网络协议、Windows、版本号、tag 或 Release。

## 自动验证

- 全新 Debug DerivedData `build-for-testing` 通过。
- 输入源隔离与租约专项：7/7 通过；完整 XCTest：99/99 通过。
- 干净 Release、`./macOS/scripts/build-app.sh` 和严格 codesign 在本提交前执行，结果在最终交付报告记录。
- 全部自动测试使用模拟 resolver/transport/cache；未执行真实 DDC、USB、网络、唤醒或输入源切换。

## 测试包

- 路径：`macOS/outputs/DisplaySwitcher-DS-009-input-lease-macOS-test.zip`
- 打包要求：无 `__MACOSX`、AppleDouble 和 Finder 扩展属性；实际解压后再次严格验签。
- SHA-256、大小与本次构建时间在最终交付报告中记录，构建产物不进入 Git。

## 尚需用户实机验证

1. 连续执行 30 次输入源切换，记录 Type-C 显示器成功次数，同时确认其他显示器不退化。
2. 成功率显著高于旧包的约 1/25：支持 service 生命周期假设，再决定是否保留租约。
3. 成功率仍接近 1/25：停止继续修改生命周期，下一阶段转向审计 selector 到 `IOAVService` 映射。
4. 普通亮度、对比度和音量调节、缓存恢复及协议行为不在本轮实机变量内。

## 安全与工作区

- 三个未跟踪的 `* 2.*` 旧副本完整保留，不在 Xcode 正式源文件中，不提交。
- `macOS/.build/` 和 `macOS/outputs/` 是忽略的本机构建产物。
- 本轮不手动触发云端 CI，不合并 PR。
