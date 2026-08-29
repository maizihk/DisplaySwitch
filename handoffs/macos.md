# macOS 交接记录

## 当前任务

- 日期：2026-08-29
- 功能：DS-009 / macOS M-009 止损回退
- 分支：`codex/macos-ds-009-native-display-control`
- 回退前 HEAD：`669fd5d03912423223ce67047ec4a0779ba9a6eb`
- 目标行为基线：`e2d0dd7`
- 本轮实现提交：本提交
- PR：[#46](https://github.com/maizihk/DisplaySwitch/pull/46)

## 原因与决策

- `669fd5d` 同时改动 GetVCP 事务时序、request-echo 分类、单显示器 service rediscover、输入源 fresh-resolution 和读取取消设施，扩大了已知写入正常路径的变更面。
- 实机故障已不值得继续在本轮放大原生读取策略；因此用可审计的反向补丁把 Native DDC 读写和 service 管理完整恢复到 `e2d0dd7`。
- 唯一保留的修正是禁止自动 DDC 读取：启动、托盘打开、显示器重检和配置重载只恢复缓存；只有设置页用户显式点击“读取 DDC 参数”才进入硬件读取。
- 输入源 SetVCP 保持 `e2d0dd7` 实现，不依赖读取成功，不增加 service 重建。Dell 原生读取失败本轮允许保留。

## 修改范围

- `DDCBackend.swift`、`NativeDDC.swift`、`DDCController.swift` 及 `DDCBackendTests.swift` 已逐字核对为 `e2d0dd7` 内容。
- `main.swift` 移除所有自动 VCP 读取入口和托盘“刷新当前数值”，自动入口改为只投影持久缓存。
- `PublicPresentationModels.swift` 增加最小读取来源策略；纯测试覆盖四个自动入口为缓存、设置页按钮为硬件读取。
- 未修改网络协议、Windows、版本号、tag 或 Release。

## 自动验证

- 全新 Debug DerivedData `build-for-testing` 通过。
- 完整 XCTest：92/92 通过，包含 37 项恢复后的 DDCBackendTests 和 1 项自动读取门控回归。
- 使用本机选定的 Xcode 27 Beta 6 从空 DerivedData 执行通用 `$DEVELOPER_DIR ./macOS/scripts/build-app.sh`：通过。
- 清理构建产物的 Finder/File Provider 非签名扩展属性后，`codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app` 通过。
- 全部自动测试使用模拟依赖；未执行真实 DDC、USB、网络、唤醒或输入源切换。

## 测试包

- 路径：`macOS/outputs/DisplaySwitcher-DS-009-stoploss-macOS-test.zip`
- 打包要求：无 `__MACOSX`、AppleDouble 和 Finder 扩展属性；实际解压后再次严格验签。
- SHA-256、大小与本次构建时间在最终交付报告中记录，构建产物不进入 Git。

## 尚需用户实机验证

1. 小米显示器显式点击读取 DDC。
2. 小米显示器连续执行输入源切换。
3. 两台 Dell 显示器分别执行输入源切换。
4. Dell 原生 DDC 读取失败本轮不作为验收阻塞。

## 安全与工作区

- 两个未跟踪的 `* 2.swift` 旧副本完整保留，不在 Xcode 正式源文件中，不提交。
- `macOS/.build/` 和 `macOS/outputs/` 是忽略的本机构建产物。
- 本轮不手动触发云端 CI，不合并 PR。
