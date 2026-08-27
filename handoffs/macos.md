# macOS 交接记录

## 当前任务

- 日期：2026-08-27
- 分支：`codex/macos-directory-layout`
- 清单：M-003A macOS 平台目录隔离
- 实现提交：`1a0faab`
- PR：[#1](https://github.com/maizihk/DisplaySwitch/pull/1)

## 完成内容

- 将 Xcode 工程、Swift 源码、资源、测试、第三方许可和构建脚本统一迁入 `macOS/`。
- 更新根目录项目约束、README、贡献说明、第三方声明和 macOS GitHub Actions 路径。
- 未修改 Windows 源码或 `PROTOCOL.md`，运行时行为和协议版本保持不变。

## 自动验证

- Xcode 27 Beta Debug 构建通过。
- Xcode 27 Beta Release 构建通过。
- 13 项单元测试全部通过。
- `macOS/scripts/build-app.sh` 构建、打包和签名验证通过。
- `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app` 通过。
- GitHub Actions [run 33041637028](https://github.com/maizihk/DisplaySwitch/actions/runs/33041637028) 通过。

## 尚需验证

- 本次为纯目录迁移，不需要执行真实 DDC、USB 交接、显示器唤醒或 GUI 实机测试。

## 对 Windows 端的影响

- Windows 源码和构建入口没有变化。
- Windows 开发开始前应同步合并后的 `main`，并按根目录 `AGENTS.md` 维护自己的 `handoffs/windows.md`。
