# macOS 端开发清单

> macOS 端开发遵守仓库根目录 `AGENTS.md` 的通用开始、结束、Git 协作和硬件安全规则。
> 本文件只记录 macOS 任务、验收条件和进度，不重复通用约束。

## 当前基线

- 原生 Swift/AppKit 菜单栏 App，正式工程为 `macOS/DisplaySwitcher.xcodeproj`。
- Bundle Identifier：`local.maizi.DisplaySwitcher`；最低支持 macOS 12。
- 正式构建脚本：`macOS/scripts/build-app.sh`。
- 构建产物：`macOS/outputs/DisplaySwitcher.app` 和当前架构 ZIP。
- 当前版本：2.1.0（build 19）。
- 已支持动态多显示器配置、旧双显示器配置迁移和未知显示器安全空输入源。
- Apple Silicon 优先使用内置 CoreDisplay/IOAVService DDC，`m1ddc` 为可选回退；Intel Mac 尚无内置原生 DDC 后端。
- App Sandbox 和 Hardened Runtime 当前保持关闭，正式公证前必须评估私有 API、USB、DDC 与登录启动兼容性。

## 已完成

### M-001 Xcode 原生工程迁移

- [x] 标准 macOS Application Target 和共享 Scheme。
- [x] Xcode Debug/Release 构建和 `macOS/scripts/build-app.sh`。
- [x] App 资源、Info.plist、Framework 和本地临时签名。
- [x] 删除已经过时的 `Package.swift`。

### M-002 动态多显示器配置

- [x] 任意数量的显示器配置集合。
- [x] UUID 稳定匹配和枚举顺序变化测试。
- [x] 旧两显示器配置迁移。
- [x] 新显示器和替换显示器不继承或猜测输入源。

### M-003 开源仓库基础

- [x] MIT License、第三方声明和社区文件。
- [x] Issue/PR 模板。
- [x] macOS GitHub Actions Debug、测试、Release、签名验证和 artifact。
- [x] 当前可达 Git 历史的常见私钥/Token 模式检查。

### M-003A macOS 平台目录隔离

- [x] Xcode 工程、源码、资源、测试、第三方许可和构建脚本统一放入 `macOS/`。
- [x] Xcode、命令行构建、GitHub Actions 和文档统一使用新路径。
- [x] 共享协议和仓库级文件保留在根目录，Windows 源码不受影响。

## P0：公开源码前继续完成

### M-004 交接状态机可测试化（下一项）

- [ ] 从 App/UI/硬件控制中分离纯交接状态机。
- [ ] 时钟、UDP 发送、USB 状态、唤醒和 DDC 操作通过可替换接口注入。
- [ ] 使用虚拟时钟覆盖 150 ms 防抖、150 ms 重发、最多 4 次、600 ms 兜底和 6 秒在线窗口。
- [ ] 覆盖 USB 等待期间返回、USB 与请求到达顺序互换、确认丢包和对端离线。
- [ ] 覆盖重复、过期、乱序、错误 source/target、错误配对码和错误 version。
- [ ] 验证 `status_probe/status_response` 使用相同 eventID 且不产生任何硬件动作。
- [ ] 测试不得访问真实 UDP、USB、DDC 或显示器唤醒接口。

验收：所有状态机测试可在无硬件、无局域网环境重复运行，现有协议 v1 行为和切换时序不变。

### M-005 DDC 后端正式接口化

- [ ] 定义统一的枚举、能力、读取、写入、错误、取消和后端可用性接口。
- [ ] Apple Silicon 私有 API 和 `m1ddc` 回退成为独立后端实现。
- [ ] 明确 Intel Mac 的后端选择与不支持状态，不把软件调光描述成硬件 DDC。
- [ ] 单台显示器失败不得影响或误操作其他显示器。
- [ ] 为模拟后端增加无硬件测试。

### M-006 诊断与脱敏

- [ ] 增加诊断页面：版本、架构、协议、对端状态、USB 状态、显示器匹配和 DDC 后端能力。
- [ ] 日志不记录配对码；IP、路径、UUID 和设备标识按需脱敏。
- [ ] 导出或复制诊断前允许用户预览。
- [ ] 诊断操作不得触发输入源切换或 USB 交接。

### M-007 兼容性与限制文档

- [ ] 写清私有 CoreDisplay/IOAVService API 的系统升级风险。
- [ ] 写清 Apple Silicon、Intel、不同线材、扩展坞、转接器和显示器的 DDC 差异。
- [ ] 区分“编译/签名验证”“GUI 验证”和“真实硬件验证”。
- [ ] 提供脱敏的硬件兼容性反馈模板。

## P1：正式 macOS 分发

### M-101 Developer ID、公证与 Hardened Runtime

- [ ] 获取并配置 Developer ID Application 身份，但不把 Team ID 或证书写入仓库。
- [ ] 在不破坏 USB、DDC 和登录启动的前提下评估 Hardened Runtime。
- [ ] 使用独立发布脚本完成签名、notarytool 提交和 stapler 验证。
- [ ] CI secret 只保存签名所需加密材料，PR 构建不得访问发布凭据。
- [ ] 在另一台干净 Mac 上验证下载、解压、移动到 `/Applications` 和首次启动。

### M-102 发布自动化

- [ ] 版本号有唯一来源，App、ZIP、tag 和 GitHub Release 一致。
- [ ] 生成 SHA-256 校验和和发布说明。
- [ ] 未公证测试包与正式公证包使用清晰不同的名称。

## P2：通用 3.0

### M-201 首次运行向导

- [ ] 引导检测显示器、学习 USB、填写输入源和配置协同。
- [ ] 完成前保持自动切换关闭。
- [ ] 真实输入源测试必须说明影响并由用户主动确认。

### M-202 协议 v2/HMAC

- [ ] 与 Windows 共同设计版本协商、HMAC、nonce、时间窗和重放保护。
- [ ] 使用标准密码学库和双端共享测试向量。
- [ ] 定义从 v1 升级和拒绝降级的策略。

### M-203 Bonjour/mDNS 自动发现

- [ ] 在协议 v2 安全模型确定后实施。
- [ ] 自动发现只列出候选设备，不自动信任、配对或触发硬件动作。

## 进度记录

| 日期 | 清单项 | 状态 | 提交 SHA | 验证说明 |
| --- | --- | --- | --- | --- |
| 2026-08-27 | M-002 动态多显示器 | 完成 | 1229b9b | 6 项配置与迁移测试通过 |
| 2026-08-27 | M-003 开源仓库基础 | 完成 | f46eb28、0a1ee8c | 本地与 GitHub Actions 均通过 |
| 2026-08-27 | M-003A macOS 平台目录隔离 | 本地完成；CI 待验证 | 待提交 | Debug、Release、13 项测试、脚本打包和严格验签通过 |
