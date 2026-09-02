# macOS 交接记录

## 当前状态：DS-022 稳定本地开发签名

- 日期：2026-08-31
- 分支：`codex/macos-stable-local-signing`
- 基线：`origin/main@c7c08f999d4c8d58c37401379e15f60ad34969d9`
- 实现提交：`e0da1296b43054dfd7a6dc571484d32eafac4709`
- PR：[#62](https://github.com/maizihk/DisplaySwitch/pull/62)
- CI：macOS run `33376900709` 全绿；Debug、149 项 XCTest、Release、打包、严格验签及 artifact 上传通过。
- 根因：持续使用 ad-hoc 签名并从不同解压路径启动测试包，不能为 macOS 本地网络权限提供稳定的 Apple 代码签名身份，造成大量同名权限记录；本机最初还只有已过期的旧 WWDR 中间证书，导致新 Apple Development 身份无法建立可信链。
- 本机准备：用户已将 WWDR G3 导入登录钥匙串，`security find-identity -p codesigning -v` 确认 1 个有效 Apple Development 身份；证书和私钥不进入仓库。
- 实现：`build-app.sh` 在可选环境变量设置时使用有效钥匙串身份，未设置时保持 ad-hoc；三份 App 均严格验签，身份模式额外拒绝 ad-hoc 或缺少 TeamIdentifier 的结果。
- 自动验证：完整 XCTest 149/149 通过；默认 ad-hoc 与 Apple Development 两种 Release 构建成功；输出 App、打包副本及 ZIP 解压副本均通过 `codesign --verify --deep --strict`，身份模式确认包含 TeamIdentifier 且不是 ad-hoc。
- 测试说明：完整套件首次运行有一项并行 resolver 调用顺序断言波动，单项复跑和随后完整 149 项复跑均通过；没有为签名任务修改输入源并发行为。
- 使用边界：Apple Development 只用于同一开发 Mac，不替代 Developer ID、公证或正式发布；测试 App 固定替换到 `/Applications/DisplaySwitcher.app`，不会自动清理已有权限记录。
- 待验证：固定路径替换后的本地网络权限复用；本任务未修改 TCC，也未执行网络、USB、DDC、唤醒或输入源动作。

## 上一任务：DS-021 发布准备事实同步

- 日期：2026-08-31
- 分支：`codex/docs-ds-021-release-readiness`
- 基线：`origin/main@ee6bc5bacc582841351c4b89b23ae842151a21cc`
- PR：[#61](https://github.com/maizihk/DisplaySwitch/pull/61)
- 范围：仅公共兼容性、清单与交接文档；不修改 macOS 运行时、协议、schema、合约、workflow、版本或硬件状态。
- 主线集成：PR [#59](https://github.com/maizihk/DisplaySwitch/pull/59) 已合并为 `ee6bc5bacc582841351c4b89b23ae842151a21cc`；macOS run `33316481986` 全绿。
- 用户验收：三台显示器诊断状态均保留成功；内建 HDMI、直连 C2DP、扩展坞 HDMI 读取通过；C2DP 诊断样本 3/3，C2C 2/3。
- 剩余边界：DS-010 的真实 TCC 允许/拒绝/重新允许、通用浅深色/键盘/辅助功能，以及清单中明确保留的未覆盖硬件场景。

## 上一任务：M-006 诊断与脱敏预览

- 日期：2026-08-30
- 功能：M-006 / 诊断与脱敏预览
- 分支：`codex/macos-m006-diagnostics`
- 基线：`origin/main@0ddf9ae`
- 实现提交：`21dcbe3`；诊断状态生命周期修复：`9c09212`、`7e56bf6`
- PR：[#59](https://github.com/maizihk/DisplaySwitch/pull/59)，已合并为 `ee6bc5bacc582841351c4b89b23ae842151a21cc`
- 修复版 CI：macOS run `33316481986` 全绿；149 项 XCTest、Release 打包、严格验签和 artifact 上传均通过

## M-006 原因与决策

- 现有输入源与协同诊断由两个菜单项直接写入剪贴板，用户无法在复制前核对内容，也没有涵盖版本、协议、USB、显示器匹配和 DDC 后端能力的统一快照。
- 诊断页只读取配置快照与会话内存状态；刷新和复制均不发网络请求，不执行 USB、唤醒、DDC 写入或输入源切换。
- 报告不输出配置名称、主机地址、配对码、endpoint、USB 标识、显示器原始 UUID 或本机路径。对端、显示器、会话和操作使用会话内 `P`、`D`、`S`、`O` 匿名编号。
- 菜单只负责打开诊断预览；只有诊断页的“复制诊断”按钮会复制，而且复制内容与当前可见预览完全一致。
- 首版实机验收发现按 D1、D2、D3 依次读取后，统一诊断只保留 D3 成功。根因是每次显式 DDC 操作前的全量重新枚举把所有已匹配显示器的最后操作状态覆盖为 `idle`，显示器页自身保存的成功文本未受影响。
- 修复后，相同 selector、service identity 和传输类型的重新枚举保留最后操作结果；service、接口或匹配状态变化时仍重置，避免把旧链路成功状态错误关联到新链路。

## M-006 实现与自动验证

- 新增统一 `DiagnosticReport`，报告应用版本、架构、协议与配置安全状态、协同配置状态、USB 状态、DDC 后端能力、显示器匹配与会话诊断。
- 设置窗口新增第六个“诊断”页，提供只读可选择的等宽文本预览、刷新与复制操作。
- 输入源诊断操作 ID 由随机 UUID 改为会话内 `O1`、`O2` 编号；既有协同诊断继续使用匿名标识。
- 新增脱敏测试，注入私网 IP、配对码、UUID、USB 引用以及配置、显示器和设备名称，验证报告均不泄露，同时保留决策所需状态。
- 新增三项 DDC 诊断状态回归测试，覆盖相同绑定保留结果、service identity 变化重置和传输类型变化重置。
- 本机 Command Line Tools 环境以 `swiftc -warnings-as-errors -typecheck` 完成全部 macOS 正式 Swift 源码类型检查。此环境没有完整 Xcode 和 XCTest SDK，因此本机未声称运行 XCTest 或打包。
- PR #59 修复版 CI 已完成 149/149 XCTest、Debug/Release 构建、`build-app.sh`、`codesign --verify --deep --strict` 和 artifact 上传。

## M-006 尚需 GUI 验证

1. 浅色和深色模式打开设置，确认六页导航、诊断预览和按钮布局正常。
2. 从菜单选择“查看诊断预览…”，确认只打开预览且不会自动改写剪贴板；点击“复制诊断”后再核对剪贴板与可见文本一致。
3. 人工检查真实配置生成的预览不含 IP、配对码、UUID、USB 标识、显示器原始设备标识或本机路径。
4. 依次读取三台显示器，重新打开诊断页；D1、D2、D3 均应保留各自最后一次 `read-succeeded`，而不是只有最后读取的显示器成功。
5. 本任务未执行真实 USB、唤醒、输入源切换或协同网络探测。

## M-006 实机验收结果

- 用户使用修复版依次读取三台显示器后重新打开诊断页并复制预览，D1、D2、D3 均保留各自的 `read-succeeded`。
- D1 内建 HDMI 保留 `offset 0 · attempts 1 · checksum standard`；D2 直连 C2DP 保留 `offset 0x51 · attempts 1 · checksum legacy`；D3 扩展坞 HDMI 保留 `offset 0 · attempts 11 · checksum standard`。
- 导出文本未出现 IP、配对码、endpoint、显示器 UUID、USB 标识或本机路径；对端与显示器继续使用 `P1`、`D1`、`D2`、`D3` 会话匿名编号。
- 诊断状态生命周期修复复验通过，M-006 满足合并条件；通用浅色/深色、键盘和辅助功能检查仍归 DS-007 总体验收，不伪记为本轮已完成。

## M-006 修改文件

- `macOS/Sources/DisplaySwitcher/InputSourceSwitching.swift`
- `macOS/Sources/DisplaySwitcher/DDCBackend.swift`
- `macOS/Sources/DisplaySwitcher/NativeDDC.swift`
- `macOS/Sources/DisplaySwitcher/PublicPresentationModels.swift`
- `macOS/Sources/DisplaySwitcher/SettingsWindowController.swift`
- `macOS/Sources/DisplaySwitcher/main.swift`
- `macOS/Tests/DisplaySwitcherTests/InputSourceSwitchingTests.swift`
- `macOS/Tests/DisplaySwitcherTests/DDCBackendTests.swift`
- `macOS/Tests/DisplaySwitcherTests/PublicPresentationModelsTests.swift`
- `macOS/DEVELOPMENT_CHECKLIST.md`
- `handoffs/macos.md`

## 上一任务：DS-020 扩展坞 HDMI Get VCP 校验策略

- 日期：2026-08-30
- 功能：DS-020 / 扩展坞 HDMI Get VCP 校验策略
- 基线：`origin/main@edeacd0`
- 实现提交：`b2f22d7`；实机验收记录：`71081ab`
- PR：[#57](https://github.com/maizihk/DisplaySwitch/pull/57)，已 squash 合并为 `aeadc9d`
- CI：macOS run `33313325787` 全绿；Debug、145 项 XCTest、Release 打包、验签和 artifact 均通过

## DS-020 原因与决策

- 第二台显示器经 USB-C 扩展坞 HDMI 接入，但当前 IORegistry 拓扑只把上游链路分类为 `typec-dp-alt`。其失败回复包含旧 Get VCP 请求的 `FD` 校验字节，与 DS-019 已确认的“显示器未接受请求、驱动读回请求或无关帧”证据一致。
- 不能按显示器名称、第二台、扩展坞品牌或枚举顺序写死，也不能把全部 Type-C/DP 改成标准校验，因为第一台直连 C2DP 已连续严格成功。
- 因此先用当前显示器当前 service 的首选策略；严格失败且请求写入未被拒绝时，再从最后失败 offset 以另一校验方式重试。成功立即停止，并把 offset + 校验策略绑定当前 selector/service/transport 缓存。

## DS-020 实现与验证边界

- 新增纯校验策略 runner：默认保留 Type-C/DP 的 legacy 帧，失败后尝试 DS-019 已验证的 standard 帧；缓存 standard 后下次从该策略起步，失败仍可回到 legacy。
- service identity 或 transport 变化时既有读取偏好自动失效；同型号显示器仍保持一对一 selector/service 匹配。
- 设置页诊断增加 `checksum legacy` 或 `checksum standard`，便于实机确认实际胜出策略。
- 写入、输入源 VCP `0x60`、USB、协同网络和共享协议未修改；自动测试不访问真实显示器。
- DDC 专项 XCTest 60/60、完整 XCTest 145/145 通过；Release `build-app.sh`、App 与 ZIP 解压后严格 codesign、ZIP 完整性验证通过。
- 测试包：`macOS/outputs/DisplaySwitcher-DS-020-dock-hdmi-read-macOS-test.zip`；SHA-256 `f85f4637f6a873a5217b460fcb2f3fbd40b0c0351e3466e877f88469e82fb5e3`；大小 660625 bytes。

## DS-020 实机验收结果

- 用户截图确认内建 HDMI 为 `read-succeeded · offset 0 · attempts 1 · checksum standard`。
- 第一台直连 C2DP 为 `read-succeeded · offset 0x51 · attempts 1 · checksum legacy`，既有成功路径没有回归。
- 第二台 USB-C 扩展坞 HDMI 虽枚举为 `typec-dp-alt`，首次读取在 legacy 严格失败后以 `offset 0 · attempts 11 · checksum standard` 成功，证明下游 HDMI 需要标准校验和。
- 用户继续读取后确认只有第一次较慢、后续明显加快，符合成功的 `standard + offset 0` 偏好在当前 selector/service/transport 上命中缓存。
- DS-020 满足合并条件；结论是动态链路策略差异，不是显示器型号、枚举序号或固定接口映射。

## DS-020 用户实机验收

1. 完全退出 BetterDisplay，运行 DS-020 测试包。
2. 第一台直连 C2DP 读取 3 次，应继续显示 `checksum legacy` 且严格成功。
3. 第二台 USB-C 扩展坞 HDMI 读取 10 次；若 standard 是根因，首次可能先经历 legacy 回退，成功后应显示 `checksum standard`，后续读取从缓存策略起步。
4. 本轮不需要调节亮度或切换输入源；写路径没有变化。

## 上一任务：DS-019 内建 HDMI Get VCP 请求校验和

- 日期：2026-08-30
- 功能：DS-019 / 内建 HDMI Get VCP 请求校验和
- 堆叠基线：`codex/macos-ds-017-production-read-transactions@85691cf`
- 分支：`codex/macos-ds-017-production-read-transactions`
- 实现提交：`8ed8830`；实机验收记录为本次后续提交
- PR：[#56](https://github.com/maizihk/DisplaySwitch/pull/56)，面向 `main` 的最终净状态；等待 CI 通过后 squash 合并

## DS-019 原因与决策

- DS-018 实机中小米内建 HDMI 连续 20 次读取全部失败，同一构建的 Dell C2DP 保持严格成功；service 生命周期假设被否定，因此本任务完整撤回 service 复用实现。
- 旧公开 AppleSiliconDDC 对单字节 Get VCP 请求使用 `chipWriteAddress` 作为校验和种子，却漏掉实际写入目标地址 `0x51`。当前代码由此发送 `82 01 10 FD`；包含 `0x51` 的标准帧应为 `82 01 10 AC`。
- 既有 HDMI 诊断曾把回复解析为 `payloadLength=0x82 / opcode=0x01 / result=0x10 / command=0xFD`，字段与本机错误请求逐字对应。这说明显示器没有接受请求，ReadI2C 随后读回了请求或无关数据，不是权限、offset、service 生命周期或严格回复校验问题。
- 静态审计 BetterDisplay 当前生产二进制确认普通 Get VCP 构造校验和时同时异或 chip 写地址和 `0x51`。动态 interpose 受运行时保护限制，未取得动态调用记录，因此不把动态验证写成已完成。

## DS-019 实现与自动验证

- 新增纯 `NativeDDCRequestPacketBuilder`，由调用点显式决定校验和是否包含数据地址，不再用 `request.count == 1` 隐式推断。
- 内建 HDMI Get VCP 使用包含 `0x51` 的标准校验和；已实机稳定的 Type-C/DP Get VCP 保留旧 Apple Silicon 兼容帧。Set VCP 一直包含 `0x51`，本轮输出字节不变。
- 删除 DS-018 的 service 复用模型、发现逻辑和测试，恢复每次显式硬件操作根据当前拓扑新建 service。
- 帧测试固定 HDMI Get VCP=`82 01 10 AC`、Type-C/DP Get VCP=`82 01 10 FD`、Set VCP 亮度 100=`84 03 10 00 64 CC`。
- DDC 专项 XCTest 56/56；完整 XCTest 141/141。完整测试仍报告一条既有输入源并发 QoS 警告，测试通过，本任务未修改该调度逻辑。
- Release `build-app.sh`、adhoc 签名、`codesign --verify --deep --strict` 与 ZIP 完整性验证通过。

## DS-019 测试包与实机边界

- 测试包：`macOS/outputs/DisplaySwitcher-DS-019-hdmi-getvcp-checksum-macOS-test.zip`
- SHA-256：`f3f3ef2c9f64b2f6480d692a45228da52190ad5750ace79062836ed581b149c4`
- 大小：656466 bytes。
- 完全退出 BetterDisplay 后，先对小米内建 HDMI 连续读取 20 次，记录成功次数与 attempt；再对 Dell C2DP 连续读取 3 次，必须保持第 1 次严格成功。
- 本轮无需输入源切换；Set VCP 字节和写路径未变。小米仍 0 次成功或 Dell 出现回归时不得合并。

## DS-019 实机验收结果

- 用户完全退出 BetterDisplay 后确认：小米内建 HDMI 连续 20/20 次严格读取成功，Dell C2DP 连续 3/3 次严格读取成功。
- 首张验收截图中两条链路均为 `read-succeeded`、`chip 0x37`、`attempts 1`；HDMI 使用 offset 0，C2DP 使用 offset 0x51，符合各自传输策略。
- 根因确认：内建 HDMI 单字节 Get VCP 请求漏算写入目标地址 `0x51`，显示器此前不接受 `82 01 10 FD`；改为 `82 01 10 AC` 后稳定回复。
- DS-019 满足合并条件；DS-018 的 service 复用仍保持撤回状态，不作为修复的一部分。

## 上一任务：DS-018 IOAVService 生命周期稳定化

## DS-018 原因与决策

- DS-017 已证明内建 HDMI 能偶尔得到严格 DDC/CI 回复，但随后连续 20 次失败；增加完整事务重试只是在随机数据流中提高撞帧概率，不是可靠性根因。
- BetterDisplay 的能力查询是独立的 MCCS `0xF3/0xE3` 分块事务。它能获得能力表不能证明该查询是亮度读取前置，因此本轮不加入“能力预热”或宽松校验。
- 更关键差异是 service 生命周期：BetterDisplay 在全局串行 DDC 队列中长期持有同一 `IOAVService`；DS-015 为防止旧拓扑串台，在每次操作前重验拓扑时也每次重新创建并替换 service。退出重开偶尔恢复及第 8 次才撞到有效帧均与该差异一致，但是否为根因仍以本轮实机结果为准。

## DS-018 实现与自动验证

- 每次显式 DDC 操作仍重新枚举在线 CoreDisplay 与 IORegistry 当前拓扑，不回退到历史品牌、名称、端口或枚举顺序匹配。
- 当前 selector、registry service identity、transport、chip 与在线状态均未变化时，枚举阶段直接沿用现有 `IOAVService`，不再调用 `IOAVServiceCreateWithService`；仅 service 枚举位置变化不会触发替换。
- 热插拔、接口/transport/chip、registry identity、在线状态变化，或现有失败恢复主动失效后，才按当前拓扑创建新 service。
- DDC 请求帧、offset、重试和等待、严格 validator、Set VCP、输入源、USB、网络与协议均未修改。
- DDC 专项 XCTest 55/55；完整 XCTest 140/140。首次完整运行有一项既有输入并发顺序测试波动失败，单项复跑及第二次完整运行通过；本任务未修改该调度逻辑。
- Release `build-app.sh`、adhoc 签名、`codesign --verify --deep --strict` 与 ZIP 完整性验证通过。

## DS-018 测试包与实机边界

- 测试包：`macOS/outputs/DisplaySwitcher-DS-018-persistent-service-macOS-test.zip`
- SHA-256：`31732e52969bd414af6bd522b22648290925304b18f983bdcb9421591895ade2`
- 必须完全退出 BetterDisplay，首次启动测试包后保持应用不退出：先对小米内建 HDMI 连续读取 20 次，记录成功次数与 attempt；再对 Dell C2DP 连续读取 3 次，必须保持严格成功。
- 本轮无需输入源切换；写路径完全未改。任何 C2DP 回归或 HDMI 仍无可靠性改善都不得合并。

## DS-018 实机结果

- 用户完全退出 BetterDisplay 后，对小米内建 HDMI 连续读取 20 次，严格成功 0 次；同一构建中 Dell C2DP 保持严格成功。
- 结论：持久复用 IOAVService 没有任何改善，service 生命周期不是当前 HDMI 读取失败的根因；实现已由 DS-019 撤回，不得合并 DS-018。

## 上一任务：DS-017 内建 HDMI 生产读取事务

## DS-017 原因与决策

- 当前公开 AppleSiliconDDC 源码仍是旧的“双写后单读”实现，但 BetterDisplay 5.0.3 生产二进制已经改成最多 8 次完整的“单写、等待、单读”事务；此前只改写次数的 DS-016 没有复刻这个状态机，不能用于否定该根因。
- 生产二进制中的 `0x50` 是独立的 `ddc2ab` 备用寻址，说明文字明确主要用于部分 LG 输入源控制；普通亮度 Get VCP 继续使用标准 `0x51` 请求寻址，未增加盲探。
- 用户当前的 Dell C2DP 已恢复严格读取，因此本轮只修改内建 HDMI；Type-C/DP 和所有纯写路径保持原样。

## DS-017 实现与自动验证

- 内建 HDMI 最多执行 8 次完整事务：每次单次 WriteI2C，等待 10 ms，再单次 ReadI2C；严格失败后等待 5 ms 再重试，每次使用全新 11 字节零缓冲区。
- 收到首个严格有效回复立即结束；失败继续保留严格 checksum、opcode、command、范围校验，不接受坏回复，不覆盖可信缓存。
- DDC 专项 XCTest 54/54，完整 XCTest 139/139；既有 USB 并发测试有 QoS 提示但通过。
- Release `build-app.sh`、adhoc 签名及 `codesign --verify --deep --strict` 通过。
- 未执行真实 DDC、输入源切换、USB、网络或唤醒；未修改协议或系统权限。

## DS-017 测试包与实机边界

- 测试包：`macOS/outputs/DisplaySwitcher-DS-017-hdmi-production-read-macOS-test.zip`
- SHA-256：`9f11ca8deca75c7d3edb87bee324cb7e0997ecd2a4de54f94f57339d72fd1a3d`
- 大小：661152 bytes。
- 先对 Dell C2DP 连续读取 3 次，必须保持严格成功；再对小米内建 HDMI 连续读取 10 次，记录严格成功次数与数值。最后做一次输入源切换，确认纯写路径无回归。
- 任一已成功路径回归时立即停止，不合并；只有小米获得严格 DDC/CI 回复才确认本根因。

## DS-017 首轮实机结果

- 用户截图确认小米内建 HDMI 的前 3 次完整事务均被严格校验拒绝为非 DDC 数据，第 4 次得到 `strict-valid` 亮度回复，读数为 100；这证明 HDMI service 可读取，但回复通道会混入无关帧，完整事务重试是必要条件。
- 同一构建中的 Dell C2DP 保持第 1 次严格读取成功，读数为 100；本轮没有复现此前全局改单写导致的 Type-C/DP 回归。
- 当前只确认“严格读取可以成功”，尚未获得连续多次点击的成功率统计；在稳定性数据完成前保持分支未合并。

## 上一任务：DS-015 IOAVService 拓扑绑定

## DS-015 原因与决策

- 旧枚举在整棵 IORegistry 上递归遍历，并用一个可变的 `currentFramebuffer` 把随后遇到的 `DCPAVServiceProxy` 归给“最近出现”的 framebuffer；结果依赖遍历顺序，接口变化或同型号多屏时可能选错 service。
- CoreDisplay 当前 framebuffer 与 IOAVService 当前 endpoint 是更强的系统拓扑证据。实现只接受当前在线 `IODisplayLocation`，并按 endpoint 一对一匹配；缺失、重复或歧义时明确不可用，不用名称、品牌、顺序或历史缓存猜测。
- Apple Silicon 当前系统拓扑中，内建 HDMI framebuffer `disp0` 对应 service endpoint `dispextE`；数字 `dispextN` 仅对应同名 service。这是平台节点关系，不是显示器型号规则。

## DS-015 实现

- framebuffer 与 DCPAV service 分别独立枚举，再由纯拓扑匹配器关联，删除“相邻节点”推断。
- CoreDisplay `IODisplayLocation` 必须精确命中当前 framebuffer；匹配后的 service metadata 才参与稳定显示器身份匹配。
- 显示器身份匹配改为双向唯一最佳：同型号等分候选、同一 service 被多个显示器竞争时均安全拒绝。
- 每次设置页显式 DDC 读写前重新发现当前 service；重连或接口变化不会继续使用旧 IOAVService、transport 或读取偏好。
- DDC/CI 请求格式、chip/offset、读取安全策略、Set VCP、输入源切换、USB、网络与协议均未改变。

## DS-015 自动验证

- DDC 专项 XCTest：54/54。
- 完整 XCTest：139/139；一条既有 USB 测试产生 QoS 性能提示，测试通过。
- `./macOS/scripts/build-app.sh` Release 构建、打包及 `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app` 通过。
- 自动测试覆盖 M4 `disp0 -> dispextE`、数字 `dispextN`、枚举反序、同型号歧义、重复/未知 endpoint、安全拒绝以及接口变化后的重新绑定。
- 未执行真实 DDC、输入源切换、USB、网络或唤醒，未修改系统权限。

## DS-015 尚需用户实机验证

1. 小米显示器保持内建 HDMI，连续执行多次显式“读取 DDC 参数”，确认绑定到当前 HDMI service；读取协议是否受系统限制仍与 service 绑定分开判断。
2. 两台同型号显示器分别读写一次，确认操作始终落到目标物理显示器，不串台。
3. 热插拔或把同一显示器在 HDMI、USB-C/DP 间切换后刷新，再执行显式读取，确认旧 service 失效且重新绑定。
4. 输入源切换路径不属于本次修改，但应做一次最小回归，确认现有同时切换行为未退化。

## DS-015 修改范围

- `macOS/Sources/DisplaySwitcher/DDCBackend.swift`
- `macOS/Sources/DisplaySwitcher/NativeDDC.swift`
- `macOS/Tests/DisplaySwitcherTests/DDCBackendTests.swift`
- `macOS/DEVELOPMENT_CHECKLIST.md`
- `handoffs/macos.md`

## 上一任务：DS-014 内建 HDMI 原生 DDC 读取收敛

## DS-014 收敛结论

- 实机已经证明：内建 HDMI 的既定 `chip = 0x37` 下，offset 0 与 0x51 的系统调用虽返回成功，但回复均未通过严格 DDC/CI 校验，其中包含 EDID-like 数据；该连接当前只验证 Set VCP 写入可用，读取不可用。
- 同一构建中的 Type-C/DP 严格成功样本证明请求格式、validator 和连续缓冲区并非全局失效；另一个 Type-C/DP 失败样本后续单独诊断，不与内建 HDMI 根因合并。
- 因此停止继续试探 chip、offset、延迟、写周期、回复长度或宽松校验，不把系统调用成功伪装成设备读取成功。

## DS-014 正式实现

- 内建 HDMI Get VCP 只执行一次既定 offset 0 严格事务；失败后不再运行十次诊断循环、不尝试 offset 0x51、不进入 checksum 兼容读取，也不触发 service 重建重试。
- 失败时保留并显示按稳定显示器 ID 保存的上次可信值；没有缓存则不制造数值。
- 普通设置页只显示“当前连接不支持可靠读取”或“当前连接不支持可靠读取，显示上次可信值”，不展示 IOReturn、chip、offset、attempts 或原始回复。
- 保留严格校验、EDID-like 拒绝、显式连续 `withUnsafeBytes`/`withUnsafeMutableBytes` 缓冲区及原始回复不出界面/日志的隐私边界。
- Type-C/DP 读取策略、Set VCP、输入源切换、显示器匹配、网络和 USB 行为均未改变。

## DS-014 最终自动验证

- DDC 专项 XCTest：50/50。
- 完整 XCTest：135/135。首次完整运行仅有一项既有跨显示器并发测试因 resolver 调用顺序波动失败；单项复跑及第二次完整运行均通过，本任务未修改该调度逻辑。
- Debug、Release、`./macOS/scripts/build-app.sh` 与 `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app` 均通过。
- 使用本机选定的 Xcode 27 Beta 6；命令仅记录通用的 `$DEVELOPER_DIR` 表达。
- 未执行新的真实 DDC、输入源切换、USB、网络或唤醒；未创建 PR、未触发云端 CI。

## DS-014 后续边界

- 不需要新的内建 HDMI 读取诊断包：本轮已无待验证的新读取变量，继续打包只会重复已确认失败的硬件路径。
- 如需界面确认，可在后续合并候选中验证安全提示与缓存展示；不作为继续试探读取参数的理由。
- 第二个 Type-C/DP 失败样本需要独立任务和独立证据范围。

## DS-014 第二阶段根因证据

- 第一阶段实机中，内建 HDMI 目标的 offset 0 与 0x51 共十次 WriteI2C/ReadI2C 均返回成功，但全部严格 checksum 失败；回复包含与当前显示器 EDID 衍生名称一致的连续窗口。原始字节和真实名称未写入本文件。
- 同一构建中另一条 Type-C/DP 样本可一次严格读取成功，证明 Get VCP 请求格式、严格 validator 和 Swift/C 桥接路径并非全局失效；另一个 Type-C/DP 失败样本继续单列，不与 HDMI 数据源问题混合。
- 当前枚举只证明选中了 `DCPAVServiceProxy`、`Location=External` 且相邻 endpoint 为 `dispextE`；这些证据能确认内建 HDMI 路由和 `chip=0x37` 写入路径，但不能证明私有 ReadI2C 被驱动复用到 DDC/CI 数据源。
- 因此本阶段不新增 chip、offset、延迟、写周期或回复长度探测。若连续缓冲区实验后仍分类为 `non-ddcci/edid-like`，结论是该内建 HDMI 原生路径当前只验证写入，读取不可用并安全显示上次可信值。

## DS-014 第二阶段实现

- `NativeDDCBridge.h` 将 WriteI2C 输入声明为只读指针；Swift 调用统一使用 `withUnsafeBytes`/`withUnsafeMutableBytes`，明确传入连续缓冲区的首地址和实际长度。
- 枚举仅在本机内存中保留当前 service/framebuffer 的原始 EDID（若系统提供）及 EDID 衍生产品名字节，拒绝回复只做连续窗口比对。
- 原始 11 字节回复仍用于严格校验，但不再进入界面诊断；展示只保留 IOReturn、offset、尝试次数、长度、严格结果及 `ddcci/strict-valid`、`non-ddcci/edid-like` 或未分类来源。
- 未改变 Set VCP、输入源切换、显示器匹配、Type-C/DP 读取策略、chip、offset、延迟、写周期和回复长度。

## DS-014 第二阶段诊断构建自动验证（历史）

- DDC 专项 XCTest：45/45。
- 完整 XCTest：130/130；存在一条既有 USB 并发测试 QoS 警告，测试本身通过。
- 纯测试覆盖连续输入/输出缓冲区长度与字节、EDID-like 窗口分类、严格 DDC/CI 优先、未匹配数据隔离及原始回复不出现在用户诊断。
- Debug、Release、`./macOS/scripts/build-app.sh` 和严格 codesign 验证通过。
- 未执行真实 DDC、输入源切换、USB、网络或唤醒；未创建 PR、未触发云端 CI。

## DS-014 第二阶段实机结果（已完成）

1. 用户保持目标显示器直连内建 HDMI，完成诊断读取。
2. offset 0 与 0x51 均未得到严格 DDC/CI 回复；连续缓冲区没有改变结果。
3. 结果已经用于上方正式安全策略，不再安排新的 HDMI 参数探测。

## DS-014 第一阶段原因与决策

- 已确认内建 HDMI 的原生 Set VCP 正常，而 Get VCP 在固定 offset 0 下失败；同一显示器经 Type-C/DP 时可以读取，因此本轮只验证 read offset，不改匹配、chip、延迟、写周期或回复长度。
- 诊断仅适用于当前已唯一匹配、`chip = 0x37`、`builtin-hdmi-converter` 的亮度 `0x10` 读取；明确 MCDP/0xB7、其他 VCP 和 Type-C/DP 保持既有行为。
- offset 0 严格失败后才诊断 offset 0x51。offset 0x51 必须连续两次产生严格有效且 current/max 一致的回复，才能标记为本次诊断成功；不接受移位、坏 checksum、null reply 或弱校验估算。

## DS-014 第一阶段实现

- 新增纯 `NativeDDCHDMIReadDiagnosticRunner`，对 offset 0 与 0x51 执行相同的有界次数和 50 ms 延迟；request-write-failed 不进入回退。
- 每个 attempt 记录 offset、固定延迟、两次写调用的 IOReturn、ReadI2C IOReturn、完整 11 字节回复和严格校验结果；输出只包含 DDC/CI 公共事务字段。
- 诊断成功显示 `read-diagnostic-succeeded`，不把实验策略描述成正式默认；失败保持精确拒绝原因。
- 读取偏好缓存从 selector 单键升级为 selector + 当前 IORegistry service identity + transport，重新发现、service 替换、取消和失效会清理旧偏好。

## DS-014 第一阶段自动验证

- DDC 专项 XCTest：42/42。
- 完整 XCTest：127/127；Type-C/DP、输入源切换、USB、协同、缓存与安全闸门模拟回归通过。
- 自动测试覆盖 HDMI offset 0 → 0x51 有界回退、request-write-failed 不回退、移位/坏 checksum/null reply/语义不一致拒绝、连续两次严格成功，以及 service/transport 绑定缓存失效。
- 未执行真实 DDC、输入源切换、USB、网络或唤醒。

## DS-014 第一阶段实机验证（已完成）

1. 用户已按要求完成内建 HDMI 亮度读取诊断。
2. offset 0 与 0x51 均未得到严格 DDC/CI 回复；原始回复暴露问题已在第二阶段修复。

## 上一任务：DS-011 原生 DDC 单后端清理

## DS-011 原因与决策

- 运行时虽然已只选择原生后端，仓库仍保留完整的外部进程实现、路径检测、历史回退路由、配置字段和设置选择器；这些死路径会让公开能力边界与代码事实不一致。
- DS-011 将路由收敛为一个注入式 `DDCBackend`，正式 App 只注入 `NativeDDCBackend`。原生不可用或读写失败直接返回原生错误，不尝试替代后端。
- VCP/cache 属性改成平台无关名称，但继续生成完全相同的 `LastValue.stable.*` 键，避免清空已有可信缓存。
- schemaVersion 保持 5；旧后端选择字段由 Codable 作为未知字段忽略，后续编码不再保存。
- 根 `README.md` 仍有历史回退描述，但本平台任务禁止修改共享文件；需由协调端在合并阶段统一校准。

## DS-011 实现

- 删除外部 DDC 后端、`Process`/`Pipe` 调用、Homebrew/可执行路径探测、专属错误和显示器列表文本解析。
- `DDCBackendRouter` 改为单后端路由，保留统一枚举、读写、取消、诊断、缓存和安全闸门接口。
- 删除配置模型、启动和重载路径中的后端选择；显示器页不再展示无可选项的“控制后端”说明，仅保留检测/刷新入口，Intel Mac 在原生后端不可用时显示不支持。
- 显示器控制标题与“检测/刷新”、显示器名称与“读取 DDC 参数”分别采用同一行左右布局；读取结果移到下一行全宽展示，控制逻辑和诊断语义不变。
- 本机配置检查弹窗将内部校验枚举替换为可执行的中文说明；只有原生后端确实不可用时才附加后端状态。
- 已启用配置在逐项编辑期间若暂时不完整，会保存当前有效输入并自动停用；不再因整份完整性校验回滚刚输入的映射。
- 测试覆盖原生成功、不可用、读写失败显式返回、旧配置字段不再写回，以及旧可信缓存键继续读取。

## DS-011 自动验证

- 相关 XCTest：54/54（DDC 37 项、配置 17 项）。
- 完整 XCTest：122/122；现有输入源切换、队列、USB、v2 网络和安全闸门模拟回归继续通过。
- Debug、Release、`./macOS/scripts/build-app.sh` 与 `codesign --verify --deep --strict macOS/outputs/DisplaySwitcher.app` 均通过。
- 使用本机选定的 Xcode 27 Beta 6；命令只记录通用的 `$DEVELOPER_DIR` 表达，不记录本机绝对路径。
- 未执行真实 DDC、输入源切换、USB、网络或唤醒，未修改系统权限、签名信任或防火墙。

## DS-011 尚需用户实机验证

1. Apple Silicon 原生显示器枚举与稳定名称保持正确。
2. 设置页显式读取，以及亮度、对比度、音量写入保持现有行为。
3. USB、手动和协同入口的多显示器输入源切换不回归。
4. Intel Mac 只显示原生 DDC 不支持，不执行外部进程。

## DS-011 修改范围

- `macOS/Sources/DisplaySwitcher/DDCBackend.swift`
- `macOS/Sources/DisplaySwitcher/DDCController.swift`
- `macOS/Sources/DisplaySwitcher/DisplayConfigurationStore.swift`
- `macOS/Sources/DisplaySwitcher/SettingsWindowController.swift`
- `macOS/Sources/DisplaySwitcher/main.swift`
- `macOS/Tests/DisplaySwitcherTests/DDCBackendTests.swift`
- `macOS/Tests/DisplaySwitcherTests/DisplayConfigurationStoreTests.swift`
- `macOS/Tests/DisplaySwitcherTests/PeerProtocolV2Tests.swift`
- `macOS/Tests/DisplaySwitcherTests/PublicPresentationModelsTests.swift`
- `macOS/DEVELOPMENT_CHECKLIST.md`
- `handoffs/macos.md`

## 上一任务：DS-010 本地网络权限引导

- 日期：2026-08-30
- 功能：DS-010 / macOS 本地网络权限引导
- 基线：`main@5e382569466139193cab0828865af6c3c91d4c49`
- 分支：`codex/macos-ds-010-local-network-permission-ux`
- 实现提交：本提交，最终完整 SHA 以分支 HEAD 和交付报告为准
- PR / CI：按任务边界不创建 PR、不触发云端 CI

## DS-010 原因与决策

- macOS 的本地网络权限由系统管理，原界面没有入口或保守状态说明，用户无法区分权限、地址、对端、防火墙和认证问题。
- 当前直接 BSD UDP socket 没有可靠公开信号可单独证明本地网络 TCC 被拒绝。超时、零响应、发送失败、认证失败和普通网络错误一律显示一般连接失败。
- “系统明确拒绝”只接受显式系统拒绝证据；本轮不改 UDP 架构，不增加 Bonjour、组播或旁路探测。

## DS-010 实现

- 协同页顶部新增紧凑的“本地网络权限”模块，说明用途、当前状态和“检测并申请权限”入口；不新增标签或 App 内权限开关。
- 入口复用现有协同配置校验、绑定源端口、v2 状态探测、HMAC 和响应验证路径；检测仍为零 USB、DDC、唤醒和输入源切换副作用。
- 状态限制为“未检测”“协同连接正常”“系统明确拒绝”“连接失败，请检查权限、地址和防火墙”。明确拒绝时保留“系统设置 → 隐私与安全性 → 本地网络”文字路径。
- 更新 `NSLocalNetworkUsageDescription`，说明连接检测、协同唤醒和用户配置的显示器切换，不暗示同步原始 USB 或硬件标识。

## DS-010 自动验证

- 相关 `PublicPresentationModelsTests`：11/11，通过四状态、模糊错误不误报、模拟网络入口和零硬件副作用。
- 完整 XCTest：118/118；既有 v2、固定源端口、重放保护、USB 和 DDC 模拟回归继续通过。
- Debug、Release、`./macOS/scripts/build-app.sh` 和严格 codesign 验证通过，保持 ad-hoc 签名。
- 使用本机选定的 Xcode 27 Beta 6；命令仅使用通用的 `$DEVELOPER_DIR` 表达，不记录本机绝对路径。
- 未访问真实局域网，未弹授权框，未执行真实 USB、DDC、唤醒或输入源切换，未修改 TCC 或防火墙。

## DS-010 尚需用户实机验证

1. macOS 15 及以上首次点击“检测并申请权限”是否出现系统本地网络授权框。
2. 分别选择允许、拒绝，并在“系统设置 → 隐私与安全性 → 本地网络”重新允许后的恢复行为。
3. 错误地址、对端未运行、现有防火墙阻断和错误配对码只显示一般连接失败，不显示“系统明确拒绝”。
4. 模块在浅色/深色模式及紧凑窗口中的真实 AppKit 布局。

## DS-010 修改范围

- `macOS/Resources/Info.plist`
- `macOS/Sources/DisplaySwitcher/PublicPresentationModels.swift`
- `macOS/Sources/DisplaySwitcher/SettingsWindowController.swift`
- `macOS/Tests/DisplaySwitcherTests/PublicPresentationModelsTests.swift`
- `macOS/DEVELOPMENT_CHECKLIST.md`
- `handoffs/macos.md`

## 上一任务：DS-009 协同检测诊断

- 日期：2026-08-29
- 功能：DS-009 / macOS 非对称协同检测第一阶段诊断
- 分支：`codex/macos-ds-009-collaboration-diagnostics`
- 堆叠基线：`codex/macos-ds-009-hardware-acceptance@85c975b`
- 本轮实现提交：`21d24a3`
- 前置验收记录：PR #49 保持开放
- 本轮 PR：#50，目标为 `codex/macos-ds-009-hardware-acceptance`，保持开放

## 审计结论

- 从设置页检测到 UI 结果的链路为：`beginPeerCapabilityInspection` → 同一 BSD UDP socket 同步绑定本机监听端口 → `sendto` → `recvfrom` 携带来源地址/端口 → pending eventID 匹配 → v2 endpoint/HMAC/时间验证 → 设置页状态。
- 现有实现没有证据表明 1 秒超时是根因；本轮保持 1 秒不变。
- 已确认的首要问题是可观测性缺失：监听、发送和接收错误只进入系统日志，event/endpoint/HMAC/时间窗等拒绝统一折叠成“无响应”，无法判断非对称故障发生在哪一层。
- 另确认两项协议路径缺口：检测响应此前绕过 nonce 重放分类；超时后的迟到响应会进入普通 v2 路径并可能刷新在线状态。本轮分别改为明确拒绝 `nonce-reuse`/重复响应和 `late-response`。
- 未修改 PROTOCOL、Windows、检测超时、DDC、USB、唤醒或显示器行为；非对称故障的最终根因仍需用户双向诊断日志判定。

## 实现

- `PeerTransport.swift`：监听启动和发送返回结构化成功/错误类别；接收回调携带来源 endpoint；仍由同一个已绑定 socket 收发。
- `PeerProtocolV2.swift`：响应校验返回精确拒绝原因；增加脱敏诊断、event 生命周期、来源端口和 envelope 投影模型。
- `main.swift`：每次检测记录监听、发送、收包、校验、重放、迟到响应和超时；菜单新增“复制协同检测诊断”。
- `PeerTransportTests.swift`、`PeerProtocolV2Tests.swift`：模拟监听绑定失败、同一 socket 发送、正确响应、错误来源端口、event/endpoint/HMAC/时间窗错误、迟到响应、零收包超时和脱敏输出。
- `macOS/DEVELOPMENT_CHECKLIST.md`：记录该诊断阶段的自动验证状态。

## 自动验证

- 相关 XCTest：24/24。
- 完整 XCTest：115/115；全部使用模拟 socket、时间和协议消息。
- Debug 测试构建、Release `build-app.sh` 构建及严格 codesign 验证通过。
- 测试包实际解压后严格验签通过，ZIP 不含 `__MACOSX` 或 AppleDouble 条目。
- 使用本机选定的 Xcode 27 Beta 6；handoff 不记录个人绝对路径。
- 未执行真实 UDP、USB、DDC、唤醒或输入源切换，未修改防火墙。

## 诊断测试包

- `macOS/outputs/DisplaySwitcher-DS-009-collaboration-diagnostic-v2-macOS-test.zip`
- SHA-256：`0e98ea8a83c6f00814d26c50668fd2d0c0e42f889e1224240a20b9038f266298`
- 大小：648709 bytes

## 用户最短验证步骤

1. 两端保持现有配置和防火墙不变，先在 Windows 端对 macOS 点击一次“检测”。
2. 再在 macOS 协同页对同一 Windows 配置点击一次“检测”，等待结果。
3. 从 macOS 菜单选择“复制协同检测诊断”，将文本发回；导出不含 IP 原文、配对码、authTag 或 endpoint 原值。

## 待验与边界

- 根据日志区分：listener 未启动、sendto 失败、完全零收包、来源端口不符、event 不符、endpoint/HMAC/时间窗/重放拒绝或迟到响应。
- 本任务没有继续处理 C2C、DDC 原生读取或其他协同状态机行为。
- 多显示器同时切换已由用户实机确认通过；该结论与本次网络诊断分开记录。
