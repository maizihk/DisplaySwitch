# macOS 交接记录

## 当前任务

- 日期：2026-08-29
- 功能：DS-009 / macOS M-009 输入源切换与普通 DDC 调节隔离
- 分支：`codex/macos-ds-009-native-display-control`
- 基线：`e815742fd33d0d093a803d2fd223aa1a6dff6fdf`
- 本轮实现提交：本提交
- PR：[#46](https://github.com/maizihk/DisplaySwitch/pull/46)

## 原因与决策

- 实机表现为 Type-C 显示器普通亮度写入正常，但输入源连续切换需重启 App 才暂时恢复；两台其他显示器基本稳定。这将根因收窄到 Type-C `IOAVService` 生命周期和缓存复用，而非 VCP `0x60` 编码或目标值。
- 输入源切换因此使用独立服务：每个事件按稳定 selector 重新枚举并解析当前 `IOAVService`，完成 SetVCP 后即释放，不缓存 service。
- 输入服务不持有普通 DDC 的 display map、读取偏好、诊断状态或值缓存，只写入已验证的 VCP `0x60`，不发起 GetVCP/readback。
- 普通 DDC 与输入源服务只共享一个窄原生 I2C 仲裁器；已在执行的硬件操作完成后，等待的输入切换先于后续普通读写进入，两路失败和缓存仍彻底隔离。

## 修改范围

- 新增 `InputSourceSwitching.swift`，定义专用 VCP `0x60` 服务、短生命周 resolver、批次结果和输入优先的窄 I2C 仲裁。
- `NativeDDC.swift` 为普通原生读写接入同一仲裁，并提供每个输入事件都重新发现 service 的临时 transport；保持既有 VCP 数值、报文、写入周期和读取逻辑不变。
- `main.swift` 将 USB 本地切换与手动/协同最终切换统一到专用串行入口，不再通过普通 `DDCController` 或并发全局队列写入输入源。
- `InputSourceSwitchingTests.swift` 覆盖每事件 fresh resolve、service 不保留、3 台串行、零读取、普通 DDC 失败/缓存隔离、输入优先、失败继续与准确汇总。
- 未修改网络协议、Windows、版本号、tag 或 Release。

## 自动验证

- 全新 Debug DerivedData `build-for-testing` 通过。
- 输入源隔离专项：6/6 通过；完整 XCTest：98/98 通过。
- 干净 Release、`./macOS/scripts/build-app.sh` 和严格 codesign 在本提交前执行，结果在最终交付报告记录。
- 全部自动测试使用模拟 resolver/transport/cache；未执行真实 DDC、USB、网络、唤醒或输入源切换。

## 测试包

- 路径：`macOS/outputs/DisplaySwitcher-DS-009-input-isolation-macOS-test.zip`
- 打包要求：无 `__MACOSX`、AppleDouble 和 Finder 扩展属性；实际解压后再次严格验签。
- SHA-256、大小与本次构建时间在最终交付报告中记录，构建产物不进入 Git。

## 尚需用户实机验证

1. Windows → Mac → Windows 往返至少 10 次，Type-C 显示器不得依赖重启 App 恢复切换。
2. 同一轮往返中确认两台其他显示器仍稳定切换。
3. 分别通过 USB 本地路径和手动/协同路径验证同一专用输入源入口。
4. 普通亮度、对比度和音量调节及缓存恢复不受输入切换失败影响；Dell 原生 DDC 读取失败本轮不作为验收阻塞。

## 安全与工作区

- 三个未跟踪的 `* 2.*` 旧副本完整保留，不在 Xcode 正式源文件中，不提交。
- `macOS/.build/` 和 `macOS/outputs/` 是忽略的本机构建产物。
- 本轮不手动触发云端 CI，不合并 PR。
