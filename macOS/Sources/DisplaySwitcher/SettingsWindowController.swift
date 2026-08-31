import AppKit
import Foundation
import ServiceManagement

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension NSColor {
    func cgColor(using appearance: NSAppearance) -> CGColor {
        var result = NSColor.clear.cgColor
        appearance.performAsCurrentDrawingAppearance {
            result = cgColor
        }
        return result
    }
}

private final class DisplayInputMappingRowView: NSStackView {
    let inputField = NSTextField()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.maximumNumberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inputField.placeholderString = "0–65535"
        inputField.widthAnchor.constraint(equalToConstant: 108).isActive = true
        inputField.setContentHuggingPriority(.required, for: .horizontal)
        inputField.setContentCompressionResistancePriority(.required, for: .horizontal)
        setViews([titleLabel, inputField], in: .center)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = 10
        distribution = .fill
        widthAnchor.constraint(equalToConstant: 590).isActive = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(title: String, value: String, delegate: NSTextFieldDelegate) {
        titleLabel.stringValue = title
        inputField.stringValue = value
        inputField.delegate = delegate
    }
}

private final class HoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

private final class AppearanceBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor
            .cgColor(using: effectiveAppearance)
        layer?.cornerRadius = 12
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private class AppearancePageView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor(using: effectiveAppearance)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class FlippedDocumentView: AppearancePageView {
    override var isFlipped: Bool { true }
}

private final class SettingsTabButton: NSControl {
    private let selectionShadowView = NSView()
    private let selectedBackground: NSView
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    var state: NSControl.StateValue = .off {
        didSet { updateAppearance() }
    }

    init(title: String, symbolName: String) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 12
            glass.tintColor = nil
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = true
            }
            selectedBackground = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .withinWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 12
            selectedBackground = material
        }

        super.init(frame: .zero)
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(symbolConfiguration)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        selectedBackground.translatesAutoresizingMaskIntoConstraints = false
        selectedBackground.isHidden = true
        selectionShadowView.wantsLayer = true
        selectionShadowView.layer?.backgroundColor = NSColor.clear.cgColor
        selectionShadowView.layer?.cornerRadius = 12
        selectionShadowView.layer?.borderWidth = 0.5
        selectionShadowView.layer?.shadowOpacity = 0.20
        selectionShadowView.layer?.shadowRadius = 4
        selectionShadowView.layer?.shadowOffset = .zero
        selectionShadowView.translatesAutoresizingMaskIntoConstraints = false
        selectionShadowView.isHidden = true
        addSubview(selectionShadowView)
        addSubview(selectedBackground)
        addSubview(iconView)
        addSubview(titleLabel)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 84),
            heightAnchor.constraint(equalToConstant: 56),
            selectionShadowView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            selectionShadowView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            selectionShadowView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            selectionShadowView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            selectedBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectedBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectedBackground.topAnchor.constraint(equalTo: topAnchor),
            selectedBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            iconView.widthAnchor.constraint(equalToConstant: 23),
            iconView.heightAnchor.constraint(equalToConstant: 23),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 3)
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        updateLayerColors()
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }

    override func layout() {
        super.layout()
        selectionShadowView.layer?.shadowPath = CGPath(
            roundedRect: selectionShadowView.bounds,
            cornerWidth: 12,
            cornerHeight: 12,
            transform: nil
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    private func updateLayerColors() {
        selectionShadowView.layer?.borderColor = NSColor.separatorColor
            .withAlphaComponent(0.32)
            .cgColor(using: effectiveAppearance)
        selectionShadowView.layer?.shadowColor = NSColor.shadowColor
            .cgColor(using: effectiveAppearance)
    }

    private func updateAppearance() {
        selectedBackground.isHidden = state != .on
        selectionShadowView.isHidden = state != .on
        iconView.contentTintColor = state == .on ? .controlAccentColor : .secondaryLabelColor
        titleLabel.textColor = state == .on ? .controlAccentColor : .secondaryLabelColor
        setAccessibilityValue(state == .on ? "已选择" : "未选择")
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onSave: (() -> Void)?
    var onConfigurationSaveFailure: ((DisplayConfigurationStoreError) -> Void)?
    var onLearnUSB: (() -> Void)?
    var onCancelUSBLearning: (() -> Void)?
    var onUSBLearningFinished: (() -> Void)?
    var onInspectPeer: ((CollaborationProfile, @escaping (PeerCapabilityInspectionResult) -> Void) -> Void)?
    var onReadDDC: ((String) -> Void)?
    var onWriteDDC: ((String, DDCCommand, Int) -> Void)?
    var onRefreshDisplays: (() -> Void)?
    var onWindowClosed: (() -> Void)?
    var collaborationStatus: ((CollaborationProfile) -> CollaborationConnectionState)?
    var cachedDDCValue: ((String, DDCCommand) -> Int?)?
    var diagnosticReportProvider: (() -> DiagnosticReport)?

    var isSettingsVisible: Bool { window?.isVisible == true }

    private let linkedCheckbox = NSSwitch()
    private let launchAtLoginCheckbox = NSSwitch()
    private let usbAutomationCheckbox = NSSwitch()
    private let usbArrivalSwitchCheckbox = NSSwitch()
    private let usbCollaborationProfilePopup = NSPopUpButton()
    private let peerCoordinationCheckbox = NSSwitch()
    private let peerHostField = NSTextField()
    private let peerPortField = NSTextField()
    private let pairingCodeField = NSSecureTextField()
    private let peerStatusLabel = NSTextField(wrappingLabelWithString: "协同未启用")
    private let localNetworkPermissionStatusLabel = NSTextField(labelWithString: "")
    private let localNetworkPermissionDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let profilePopup = NSPopUpButton()
    private let profileNameField = NSTextField()
    private let profileMappingStack = NSStackView()
    private lazy var addProfileButton = NSButton(title: "+", target: self, action: #selector(addProfile))
    private lazy var removeProfileButton = NSButton(title: "−", target: self, action: #selector(removeProfile))
    private lazy var moveProfileUpButton = NSButton(title: "↑", target: self, action: #selector(moveProfileUp))
    private lazy var moveProfileDownButton = NSButton(title: "↓", target: self, action: #selector(moveProfileDown))
    private lazy var inspectProfileButton = NSButton(title: "检测", target: self, action: #selector(inspectCurrentProfile))
    private lazy var requestLocalNetworkPermissionButton = NSButton(
        title: "检测并申请权限",
        target: self,
        action: #selector(requestLocalNetworkPermission)
    )
    private lazy var refreshDisplaysButton = NSButton(title: "检测/刷新", target: self, action: #selector(refreshDisplays))
    private lazy var refreshDiagnosticPreviewButton = NSButton(
        title: "刷新预览", target: self, action: #selector(refreshDiagnosticPreview)
    )
    private lazy var copyDiagnosticPreviewButton = NSButton(
        title: "复制诊断", target: self, action: #selector(copyDiagnosticPreview)
    )
    private let diagnosticTextView = NSTextView()
    private let diagnosticCopyStatusLabel = NSTextField(labelWithString: "")
    private let usbDeviceLabel = NSTextField(wrappingLabelWithString: "未选择触发设备")
    private let usbStatusLabel = NSTextField(wrappingLabelWithString: "USB 切换未启用")
    private let usbMappingStack = NSStackView()
    private lazy var learnUSBButton = NSButton(title: "学习 USB 设备…", target: self, action: #selector(learnUSBDevice))
    private var inputFields: [String: NSTextField] = [:]
    private var profileMappingRows: [String: DisplayInputMappingRowView] = [:]
    private var displayFeatureSwitches: [Int: [DDCCommand: NSSwitch]] = [:]
    private var displayTraySwitches: [Int: [DDCCommand: NSSwitch]] = [:]
    private var displaySliders: [Int: [DDCCommand: NSSlider]] = [:]
    private var displayValueLabels: [Int: [DDCCommand: NSTextField]] = [:]
    private var displayStatusLabels: [Int: NSTextField] = [:]
    private let displayStack = NSStackView()
    private var usbLearningPending = false
    private var usbInputFields: [String: NSTextField] = [:]
    private var usbMappingRows: [String: DisplayInputMappingRowView] = [:]
    private var configurationDocument: DisplayConfigurationStoreV5Document?
    private var editingProfiles: [CollaborationProfile] = []
    private var selectedProfileIndex = 0
    private let tabView = NSTabView()
    private let navigationSeparator = NSBox()
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private var tabButtons: [SettingsTabButton] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 690),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "常规"
        window.backgroundColor = .windowBackgroundColor
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildInterface()
        updateLocalNetworkPermissionPresentation(.notChecked)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show(tabIndex: Int = 0) {
        reloadValues()
        selectTab(at: max(0, min(tabIndex, tabView.numberOfTabViewItems - 1)))
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func showDiagnosticPreview() {
        show(tabIndex: 4)
    }

    func updatePeerConnectionStatus(_ text: String, connected: Bool) {
        peerStatusLabel.stringValue = text
        peerStatusLabel.textColor = connected ? .systemGreen : .secondaryLabelColor
    }

    func refreshSelectedCollaborationStatus() {
        guard editingProfiles.indices.contains(selectedProfileIndex) else { return }
        let state = collaborationStatus?(editingProfiles[selectedProfileIndex])
            ?? (editingProfiles[selectedProfileIndex].coordinationEnabled ? .neverChecked : .disabled)
        updatePeerConnectionStatus(state.text, connected: state.connected)
    }

    func updateDDCValues(stableID: String, values: [DDCCommand: DDCResolvedReading],
                         diagnostic: NativeDDCDiagnosticSnapshot? = nil,
                         skipReason: DDCReadSkipReason? = nil) {
        guard let offset = configurationDocument?.displays.firstIndex(where: {
            $0.id.caseInsensitiveCompare(stableID) == .orderedSame
        }) else { return }
        let index = offset + 1
        for (command, resolved) in values {
            displaySliders[index]?[command]?.maxValue = Double(max(1, resolved.reading.maximum))
            displaySliders[index]?[command]?.integerValue = resolved.reading.current
            displayValueLabels[index]?[command]?.stringValue = resolved.estimated
                ? "≈\(resolved.reading.current)" : "\(resolved.reading.current)"
        }
        let estimatedCount = values.values.filter(\.estimated).count
        let diagnosticSuffix = diagnostic.map { " · \($0.userFacingDescription)" } ?? ""
        if let skipReason {
            displayStatusLabels[index]?.stringValue = skipReason.userFacingDescription
        } else if diagnostic?.operationCategory == .reliableReadUnsupported {
            displayStatusLabels[index]?.stringValue = values.isEmpty
                ? "当前连接不支持可靠读取"
                : "当前连接不支持可靠读取，显示上次可信值"
        } else if diagnostic?.operationCategory == .readChecksumEstimated {
            displayStatusLabels[index]?.stringValue = "已读取（弱校验）\(diagnosticSuffix)"
        } else if values.isEmpty {
            displayStatusLabels[index]?.stringValue = "原生读取失败\(diagnosticSuffix)"
        } else if estimatedCount == values.count {
            displayStatusLabels[index]?.stringValue = "原生读取失败，显示上次可信值\(diagnosticSuffix)"
        } else if estimatedCount > 0 {
            displayStatusLabels[index]?.stringValue = "部分读取失败\(diagnosticSuffix)"
        } else {
            displayStatusLabels[index]?.stringValue = "已读取\(diagnosticSuffix)"
        }
    }

    func updateDDCWriteStatus(stableID: String, command: DDCCommand, value: Int?, error: Error?,
                              diagnostic: NativeDDCDiagnosticSnapshot? = nil) {
        guard let offset = configurationDocument?.displays.firstIndex(where: {
            $0.id.caseInsensitiveCompare(stableID) == .orderedSame
        }) else { return }
        let index = offset + 1
        let diagnosticSuffix = diagnostic.map { " · \($0.userFacingDescription)" } ?? ""
        if let value {
            displayValueLabels[index]?[command]?.stringValue = "\(value)"
            displayStatusLabels[index]?.stringValue = "已应用\(diagnosticSuffix)"
        } else {
            displayStatusLabels[index]?.stringValue = (error == nil ? "已取消" : "写入失败")
                + diagnosticSuffix
        }
    }

    func updateUSBSwitchStatus(_ text: String, isError: Bool) {
        usbStatusLabel.stringValue = text
        usbStatusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    func presentConfigurationSafetyWarning(_ error: DisplayConfigurationStoreError) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "配置安全模式"
        alert.informativeText = "\(error.localizedDescription)\n\n原配置已保留。请检查当前设置并成功保存；在此之前 App 不会执行 USB、DDC、显示器唤醒或网络交接。"
        alert.beginSheetModal(for: window)
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        linkedCheckbox.target = self
        linkedCheckbox.action = #selector(displaySettingChanged(_:))
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(immediateSwitchChanged(_:))
        usbArrivalSwitchCheckbox.target = self
        usbArrivalSwitchCheckbox.action = #selector(immediateSwitchChanged(_:))
        usbCollaborationProfilePopup.target = self
        usbCollaborationProfilePopup.action = #selector(usbCollaborationProfileChanged(_:))

        let tabs = [
            ("常规", "gearshape.fill"),
            ("USB 切换", "cable.connector"),
            ("协同", "network"),
            ("显示器", "display.2"),
            ("诊断", "stethoscope"),
            ("关于", "info.circle")
        ]
        tabButtons = tabs.enumerated().map { index, tab in
            let button = SettingsTabButton(title: tab.0, symbolName: tab.1)
            button.tag = index
            button.target = self
            button.action = #selector(selectTab(_:))
            return button
        }
        let tabBar = NSStackView(views: tabButtons)
        tabBar.orientation = .horizontal
        tabBar.alignment = .centerY
        tabBar.spacing = 10
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        let tabHoverRegion = HoverTrackingView()
        tabHoverRegion.translatesAutoresizingMaskIntoConstraints = false
        tabHoverRegion.addSubview(tabBar)
        tabHoverRegion.onHoverChanged = { [weak self] isHovering in
            self?.setNavigationSeparatorVisible(isHovering)
        }
        contentView.addSubview(tabHoverRegion)

        navigationSeparator.boxType = .separator
        navigationSeparator.alphaValue = 0
        navigationSeparator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(navigationSeparator)

        tabView.tabViewType = .noTabsNoBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabView)
        validationLabel.textColor = .systemRed
        validationLabel.font = .systemFont(ofSize: 11)
        validationLabel.maximumNumberOfLines = 2
        validationLabel.isHidden = true
        validationLabel.setAccessibilityLabel("设置错误")
        validationLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(validationLabel)

        tabView.addTabViewItem(makePage(label: "常规", views: [
            module(title: "常规", views: [
                switchRow(
                    button: launchAtLoginCheckbox,
                    title: "登录时启动",
                    description: "登录 macOS 后自动在菜单栏启动显示器控制。",
                    symbolName: "power"
                )
            ])
        ]))

        usbDeviceLabel.textColor = .secondaryLabelColor
        usbDeviceLabel.maximumNumberOfLines = 2
        usbStatusLabel.textColor = .secondaryLabelColor
        usbStatusLabel.font = .systemFont(ofSize: 11)
        let usbRow = NSStackView(views: [learnUSBButton, usbDeviceLabel])
        usbRow.orientation = .horizontal
        usbRow.alignment = .centerY
        usbRow.spacing = 10
        usbMappingStack.orientation = .vertical
        usbMappingStack.alignment = .leading
        usbMappingStack.spacing = 8
        let usbHint = NSTextField(wrappingLabelWithString: "只监听这里学习的一个设备。设备离开时立即按本机映射切换显示器；设备接入时只唤醒本机显示器。")
        usbHint.textColor = .secondaryLabelColor
        usbHint.font = .systemFont(ofSize: 11)
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged(_:))
        profileNameField.placeholderString = "配置名称"
        for field in [profileNameField, peerHostField, peerPortField, pairingCodeField] {
            field.delegate = self
        }
        peerCoordinationCheckbox.target = self
        peerCoordinationCheckbox.action = #selector(profileEnabledChanged(_:))
        usbAutomationCheckbox.target = self
        usbAutomationCheckbox.action = #selector(immediateSwitchChanged(_:))
        for button in [addProfileButton, removeProfileButton, moveProfileUpButton, moveProfileDownButton] {
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
        }
        let profileToolbar = NSStackView(views: [profilePopup, addProfileButton, removeProfileButton, moveProfileUpButton, moveProfileDownButton, inspectProfileButton])
        profileToolbar.orientation = .horizontal
        profileToolbar.alignment = .centerY
        profileToolbar.spacing = 6
        profilePopup.widthAnchor.constraint(equalToConstant: 270).isActive = true
        peerHostField.placeholderString = "IP 或主机名，例如 peer.example"
        peerPortField.placeholderString = "49731"
        pairingCodeField.placeholderString = "两端填写相同的配对码"
        profilePopup.setAccessibilityLabel("协同配置")
        profileNameField.setAccessibilityLabel("配置名称")
        peerHostField.setAccessibilityLabel("对端地址")
        peerPortField.setAccessibilityLabel("通信端口")
        pairingCodeField.setAccessibilityLabel("配对码")
        addProfileButton.setAccessibilityLabel("添加协同配置")
        removeProfileButton.setAccessibilityLabel("删除协同配置")
        moveProfileUpButton.setAccessibilityLabel("上移协同配置")
        moveProfileDownButton.setAccessibilityLabel("下移协同配置")
        inspectProfileButton.setAccessibilityLabel("检测当前协同配置")
        requestLocalNetworkPermissionButton.setAccessibilityLabel("检测并申请本地网络权限")
        learnUSBButton.setAccessibilityLabel("学习 USB 设备")
        let peerGrid = NSGridView(views: [
            [NSTextField(labelWithString: "配置名称"), profileNameField],
            [NSTextField(labelWithString: "对端地址"), peerHostField],
            [NSTextField(labelWithString: "通信端口"), peerPortField],
            [NSTextField(labelWithString: "配对码"), pairingCodeField]
        ])
        peerGrid.rowSpacing = 8
        peerGrid.columnSpacing = 12
        peerGrid.column(at: 0).xPlacement = .trailing
        peerGrid.column(at: 1).width = 410
        peerStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        let peerHint = NSTextField(wrappingLabelWithString: "可以同时启用多个协同配置。检测只验证连接，不执行 USB、唤醒或显示器操作。")
        peerHint.textColor = .secondaryLabelColor
        peerHint.font = .systemFont(ofSize: 11)
        let localNetworkPermissionDescription = NSTextField(
            wrappingLabelWithString: "本地网络用于检测并连接局域网中的 DisplaySwitcher 设备。权限由 macOS 管理。"
        )
        localNetworkPermissionDescription.textColor = .secondaryLabelColor
        localNetworkPermissionDescription.font = .systemFont(ofSize: 11)
        localNetworkPermissionStatusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        localNetworkPermissionDetailLabel.font = .systemFont(ofSize: 11)
        localNetworkPermissionDetailLabel.textColor = .secondaryLabelColor
        let localNetworkPermissionRow = NSStackView(views: [
            localNetworkPermissionStatusLabel,
            requestLocalNetworkPermissionButton
        ])
        localNetworkPermissionRow.orientation = .horizontal
        localNetworkPermissionRow.alignment = .centerY
        localNetworkPermissionRow.spacing = 12
        localNetworkPermissionRow.distribution = .fill
        localNetworkPermissionStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        requestLocalNetworkPermissionButton.setContentHuggingPriority(.required, for: .horizontal)
        tabView.addTabViewItem(makePage(label: "USB 切换", views: [
            module(title: "USB 切换", views: [
                switchRow(
                    button: usbAutomationCheckbox,
                    title: "USB 切换",
                    description: "根据一个本机 USB 设备的接入状态执行本机显示器动作。",
                    symbolName: "cable.connector"
                ),
                separator(),
                usbRow,
                usbMappingStack,
                separator(),
                switchRow(
                    button: usbArrivalSwitchCheckbox,
                    title: "联动协同",
                    description: "USB 离开时并行向所选配置发送一次认证显示器唤醒，不等待网络结果。",
                    symbolName: "network"
                ),
                formRow(title: "联动目标", control: usbCollaborationProfilePopup),
                usbStatusLabel,
                usbHint
            ])
        ]))

        tabView.addTabViewItem(makePage(label: "协同", views: [
            module(title: "本地网络权限", views: [
                localNetworkPermissionDescription,
                localNetworkPermissionRow,
                localNetworkPermissionDetailLabel
            ]),
            module(title: "协同配置", views: [
                profileToolbar,
                separator(),
                switchRow(
                    button: peerCoordinationCheckbox,
                    title: "启用此配置",
                    description: "用于检测连接和手动定向协同。USB 本机切换不依赖此开关。",
                    symbolName: "network"
                ),
                separator(),
                peerGrid,
                profileMappingStack,
                peerStatusLabel,
                peerHint
            ])
        ]))

        displayStack.orientation = .vertical
        displayStack.alignment = .leading
        displayStack.spacing = 12
        tabView.addTabViewItem(makeDisplayPage())
        tabView.addTabViewItem(makeDiagnosticPage())
        tabView.addTabViewItem(makeAboutPage())

        NSLayoutConstraint.activate([
            tabHoverRegion.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            tabHoverRegion.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            tabHoverRegion.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            tabHoverRegion.heightAnchor.constraint(equalToConstant: 64),
            tabBar.centerXAnchor.constraint(equalTo: tabHoverRegion.centerXAnchor),
            tabBar.centerYAnchor.constraint(equalTo: tabHoverRegion.centerYAnchor),
            navigationSeparator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            navigationSeparator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            navigationSeparator.topAnchor.constraint(equalTo: tabHoverRegion.bottomAnchor, constant: 2),
            navigationSeparator.heightAnchor.constraint(equalToConstant: 1),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            tabView.topAnchor.constraint(equalTo: navigationSeparator.bottomAnchor, constant: 4),
            tabView.bottomAnchor.constraint(equalTo: validationLabel.topAnchor, constant: -8),
            validationLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 38),
            validationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -38),
            validationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            validationLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 14)
        ])
        selectTab(at: 0)
    }

    private func setNavigationSeparatorVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            navigationSeparator.animator().alphaValue = visible ? 1 : 0
        }
    }

    @objc private func selectTab(_ sender: SettingsTabButton) {
        selectTab(at: sender.tag)
    }

    private func selectTab(at index: Int) {
        guard tabView.numberOfTabViewItems > index else { return }
        tabView.selectTabViewItem(at: index)
        tabButtons.enumerated().forEach { $0.element.state = $0.offset == index ? .on : .off }
        window?.title = tabView.tabViewItem(at: index).label
        if tabView.tabViewItem(at: index).label == "诊断" {
            refreshDiagnosticPreview()
        }
    }

    private func makePage(label: String, views: [NSView]) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        let container = AppearancePageView()
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18)
        ])
        item.view = container
        return item
    }

    private func makeDisplayPage() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "显示器")
        item.label = "显示器"
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        refreshDisplaysButton.setAccessibilityLabel("检测并刷新显示器")

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        displayStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(displayStack)
        scrollView.documentView = documentView
        displayStack.addArrangedSubview(module(title: "显示器控制", headerAccessory: refreshDisplaysButton, views: [
            separator(),
            switchRow(
                button: linkedCheckbox,
                title: "联动调节所有显示器",
                description: "只联动同时开启相同控制项的显示器。",
                symbolName: "link"
            )
        ]))
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            displayStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 18),
            displayStack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -18),
            displayStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 18),
            displayStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -18)
        ])
        item.view = scrollView
        return item
    }

    private func makeDiagnosticPage() -> NSTabViewItem {
        diagnosticTextView.isEditable = false
        diagnosticTextView.isSelectable = true
        diagnosticTextView.isVerticallyResizable = true
        diagnosticTextView.isHorizontallyResizable = false
        diagnosticTextView.autoresizingMask = [.width]
        diagnosticTextView.textContainer?.widthTracksTextView = true
        diagnosticTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnosticTextView.textContainerInset = NSSize(width: 8, height: 8)
        diagnosticTextView.string = "打开此页面后生成会话内脱敏预览。"
        diagnosticTextView.setAccessibilityLabel("诊断预览")

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = diagnosticTextView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalToConstant: 602).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: 430).isActive = true

        diagnosticCopyStatusLabel.font = .systemFont(ofSize: 11)
        diagnosticCopyStatusLabel.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [refreshDiagnosticPreviewButton, copyDiagnosticPreviewButton,
                                          diagnosticCopyStatusLabel])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10

        let explanation = NSTextField(wrappingLabelWithString:
            "预览只读取当前内存与配置状态，不执行网络检测、USB、唤醒、DDC 或输入源切换。复制内容与下方预览完全一致。")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 2

        return makePage(label: "诊断", views: [
            module(title: "诊断与隐私", views: [explanation, actions, scrollView])
        ])
    }

    private func makeAboutPage() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "关于")
        item.label = "关于"
        let content = AboutPageContent.make(metadata: Bundle.main)

        let container = AppearancePageView()
        let iconView = NSImageView(image: NSApplication.shared.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: content.productName)
        nameLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        nameLabel.alignment = .center

        let introduction = NSTextField(wrappingLabelWithString: content.summary)
        introduction.font = .systemFont(ofSize: 13)
        introduction.textColor = .secondaryLabelColor
        introduction.alignment = .center
        introduction.maximumNumberOfLines = 2
        introduction.preferredMaxLayoutWidth = 520

        let versionLabel = NSTextField(labelWithString: content.versionText)
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.alignment = .center

        let platformLabel = NSTextField(labelWithString: content.platformText)
        platformLabel.font = .systemFont(ofSize: 12)
        platformLabel.textColor = .tertiaryLabelColor
        platformLabel.alignment = .center

        let githubButton = NSButton(
            title: "GitHub · maizihk/DisplaySwitch",
            target: self,
            action: #selector(openGitHub)
        )
        githubButton.isBordered = false
        githubButton.font = .systemFont(ofSize: 13, weight: .medium)
        githubButton.contentTintColor = .linkColor
        githubButton.image = NSImage(
            systemSymbolName: "arrow.up.right.square",
            accessibilityDescription: "打开 GitHub"
        )
        githubButton.imagePosition = .imageTrailing
        githubButton.toolTip = "https://github.com/maizihk/DisplaySwitch"

        let licenseButton = NSButton(
            title: "MIT 许可证",
            target: self,
            action: #selector(openLicense)
        )
        let thirdPartyButton = NSButton(
            title: "第三方说明",
            target: self,
            action: #selector(openThirdPartyNotices)
        )
        for button in [licenseButton, thirdPartyButton] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.contentTintColor = .linkColor
        }
        let links = NSStackView(views: [githubButton, licenseButton, thirdPartyButton])
        links.orientation = .horizontal
        links.alignment = .centerY
        links.spacing = 18

        let buildNotice = NSTextField(wrappingLabelWithString: content.buildNotice)
        buildNotice.font = .systemFont(ofSize: 11)
        buildNotice.textColor = .secondaryLabelColor
        buildNotice.alignment = .center
        buildNotice.maximumNumberOfLines = 2
        buildNotice.preferredMaxLayoutWidth = 520

        let stack = NSStackView(views: [
            iconView,
            nameLabel,
            introduction,
            versionLabel,
            platformLabel,
            links,
            buildNotice
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: iconView)
        stack.setCustomSpacing(6, after: nameLabel)
        stack.setCustomSpacing(16, after: platformLabel)
        stack.setCustomSpacing(14, after: links)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 112),
            iconView.heightAnchor.constraint(equalToConstant: 112),
            introduction.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            buildNotice.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 42)
        ])

        item.view = container
        return item
    }

    private func rebuildDisplayForms(_ configurations: [DisplayConfiguration]) {
        for view in displayStack.arrangedSubviews {
            displayStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        inputFields.removeAll()
        displayFeatureSwitches.removeAll()
        displayTraySwitches.removeAll()
        displaySliders.removeAll()
        displayValueLabels.removeAll()
        displayStatusLabels.removeAll()

        displayStack.addArrangedSubview(module(title: "显示器控制", headerAccessory: refreshDisplaysButton, views: [
            separator(),
            switchRow(button: linkedCheckbox, title: "联动调节所有显示器",
                      description: "只联动同时开启相同控制项的显示器。", symbolName: "link")
        ]))

        for configuration in configurations.sorted(by: { $0.index < $1.index }) {
            let readControls = displayReadControls(index: configuration.index, name: configuration.name)
            displayStack.addArrangedSubview(module(
                title: configuration.name,
                headerAccessory: readControls.button,
                views: [readControls.status, separator(), displayForm(index: configuration.index)]
            ))
        }

        if configurations.isEmpty {
            let emptyState = NSTextField(
                wrappingLabelWithString: "尚未检测到显示器，请返回菜单栏选择“重新检测显示器”。"
            )
            emptyState.textColor = .secondaryLabelColor
            emptyState.font = .systemFont(ofSize: 12)
            emptyState.widthAnchor.constraint(equalToConstant: 630).isActive = true
            displayStack.addArrangedSubview(emptyState)
        }
    }

    private func module(title: String, headerAccessory: NSView? = nil, views: [NSView]) -> NSView {
        let heading = sectionTitle(title)
        let header: NSView
        if let headerAccessory {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let headerRow = NSStackView(views: [heading, spacer, headerAccessory])
            headerRow.orientation = .horizontal
            headerRow.alignment = .centerY
            headerRow.spacing = 10
            headerRow.widthAnchor.constraint(equalToConstant: 630).isActive = true
            header = headerRow
        } else {
            header = heading
        }
        let card = AppearanceBackgroundView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 630),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])

        let wrapper = NSStackView(views: [header, card])
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        wrapper.spacing = 8
        return wrapper
    }

    private func switchRow(
        button: NSSwitch,
        title: String,
        description: String,
        symbolName: String
    ) -> NSView {
        button.controlSize = .regular
        button.setAccessibilityLabel(title)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let descriptionLabel = NSTextField(wrappingLabelWithString: description)
        descriptionLabel.font = .systemFont(ofSize: 11)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.maximumNumberOfLines = 2

        let labels = NSStackView(views: [titleLabel, descriptionLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(icon)
        row.addSubview(labels)
        row.addSubview(button)

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: 590),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -16),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func displayReadControls(index: Int, name: String) -> (button: NSButton, status: NSTextField) {
        let readButton = NSButton(title: "读取 DDC 参数", target: self, action: #selector(readDisplayDDC(_:)))
        readButton.tag = index
        readButton.setAccessibilityLabel("读取\(name) DDC 参数")
        let status = NSTextField(wrappingLabelWithString: "尚未读取")
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.maximumNumberOfLines = DisplayDiagnosticLayout.maximumNumberOfLines
        status.lineBreakMode = DisplayDiagnosticLayout.wraps ? .byWordWrapping : .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.widthAnchor.constraint(equalToConstant: 590).isActive = true
        displayStatusLabels[index] = status
        return (readButton, status)
    }

    private func displayForm(index: Int) -> NSView {
        let headings = NSStackView(views: [
            fixedLabel("", width: 64), fixedLabel("功能", width: 44),
            fixedLabel("在托盘显示", width: 82), fixedLabel("", width: 300),
            fixedLabel("数值", width: 42)
        ])
        headings.orientation = .horizontal
        headings.spacing = 8

        let controls: [(String, DDCCommand)] = [("亮度", .luminance), ("对比度", .contrast), ("音量", .volume)]
        let rows = controls.map { title, command -> NSView in
            let feature = NSSwitch()
            let tray = NSSwitch()
            let slider = NSSlider(value: 50, minValue: 0, maxValue: 100,
                                  target: self, action: #selector(displaySliderChanged(_:)))
            let value = fixedLabel("—", width: 42)
            let tag = index * 1_000 + Int(command.rawValue)
            feature.tag = tag
            tray.tag = tag
            slider.tag = tag
            feature.target = self
            feature.action = #selector(displaySettingChanged(_:))
            tray.target = self
            tray.action = #selector(displaySettingChanged(_:))
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 300).isActive = true
            feature.setAccessibilityLabel("\(title)功能")
            tray.setAccessibilityLabel("\(title)在托盘显示")
            slider.setAccessibilityLabel("\(title)数值")
            displayFeatureSwitches[index, default: [:]][command] = feature
            displayTraySwitches[index, default: [:]][command] = tray
            displaySliders[index, default: [:]][command] = slider
            displayValueLabels[index, default: [:]][command] = value
            let row = NSStackView(views: [fixedLabel(title, width: 64), feature, tray, slider, value])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            return row
        }

        let form = NSStackView(views: [headings] + rows)
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        return form
    }

    private func fixedLabel(_ title: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func formRow(title: String, control: NSView) -> NSView {
        let row = NSStackView(views: [fixedLabel(title, width: 90), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 590).isActive = true
        return box
    }

    @objc private func immediateSwitchChanged(_ sender: NSSwitch) {
        if sender === usbArrivalSwitchCheckbox {
            if sender.state == .on, !selectedCollaborationWakeProfileIsValid() {
                sender.state = .off
                showValidationError("请选择一个已开启、完整且已确认对端身份的协同配置。")
                return
            }
            persistDocument { $0.usbSwitch.collaborationWakeEnabled = sender.state == .on }
            return
        }
        if sender === usbAutomationCheckbox {
            guard let document = configurationDocument else { return }
            if sender.state == .on,
               !DisplayConfigurationStore.isCompleteUSBConfiguration(document.usbSwitch, displays: document.displays) {
                sender.state = .off
                showValidationError("请先学习一个 USB 设备，并至少配置一台显示器的目标输入源。")
                return
            }
            persistDocument { $0.usbSwitch.enabled = sender.state == .on }
            return
        }
        if sender === launchAtLoginCheckbox {
            do {
                try updateLaunchAtLogin()
            } catch {
                reloadLaunchAtLoginState()
                showValidationError("登录启动设置失败：\n\(error.localizedDescription)\n\n请确认 App 已放入“应用程序”文件夹。")
            }
        }
    }

    @objc private func displaySettingChanged(_ sender: NSSwitch) {
        if sender === linkedCheckbox {
            persistDocument { $0.linkAllDisplays = sender.state == .on }
            return
        }
        let index = sender.tag / 1_000
        guard let command = DDCCommand(rawValue: UInt8(sender.tag % 1_000)) else { return }
        persistDocument { document in
            guard document.displays.indices.contains(index - 1) else { return }
            var display = document.displays[index - 1]
            let isFeature = self.displayFeatureSwitches[index]?[command] === sender
            switch (command, isFeature) {
            case (.luminance, true): display.brightnessEnabled = sender.state == .on
            case (.contrast, true): display.contrastEnabled = sender.state == .on
            case (.volume, true): display.volumeEnabled = sender.state == .on
            case (.luminance, false): display.brightnessShowInTray = sender.state == .on
            case (.contrast, false): display.contrastShowInTray = sender.state == .on
            case (.volume, false): display.volumeShowInTray = sender.state == .on
            case (.input, _): return
            }
            document.displays[index - 1] = display
        }
    }

    @objc private func displaySliderChanged(_ sender: NSSlider) {
        let index = sender.tag / 1_000
        guard let command = DDCCommand(rawValue: UInt8(sender.tag % 1_000)),
              let display = configurationDocument?.displays[safe: index - 1],
              displayFeatureSwitches[index]?[command]?.state == .on else { return }
        let value = sender.integerValue
        displayValueLabels[index]?[command]?.stringValue = "\(value)"
        displayStatusLabels[index]?.stringValue = "正在应用"
        onWriteDDC?(display.id, command, value)
    }

    @objc private func readDisplayDDC(_ sender: NSButton) {
        guard let display = configurationDocument?.displays[safe: sender.tag - 1] else { return }
        displayStatusLabels[sender.tag]?.stringValue = "正在读取"
        onReadDDC?(display.id)
    }

    @objc private func refreshDisplays() {
        onRefreshDisplays?()
    }

    @objc private func profileEnabledChanged(_ sender: NSSwitch) {
        persistSelectedProfileFields(requestedEnabled: sender.state == .on)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, usbInputFields.values.contains(where: { $0 === field }) {
            persistUSBDisplayMappings()
            return
        }
        persistSelectedProfileFields(requestedEnabled: nil)
    }

    @objc private func usbCollaborationProfileChanged(_ sender: NSPopUpButton) {
        let profileID = sender.selectedItem?.representedObject as? String
        persistDocument { document in
            document.usbSwitch.collaborationProfileID = profileID
            if profileID == nil { document.usbSwitch.collaborationWakeEnabled = false }
        }
    }

    private func persistUSBDisplayMappings() {
        persistDocument { document in
            document.usbSwitch.displayInputs = document.displays.compactMap { display in
                guard let field = self.usbInputFields[display.id.lowercased()],
                      let value = Int(field.stringValue), (0...65535).contains(value) else { return nil }
                return USBDisplayInputMapping(displayID: display.id, targetInput: value)
            }
            if document.usbSwitch.enabled,
               !DisplayConfigurationStore.isCompleteUSBConfiguration(document.usbSwitch, displays: document.displays) {
                document.usbSwitch.enabled = false
            }
        }
    }

    private func selectedCollaborationWakeProfileIsValid() -> Bool {
        guard var document = configurationDocument else { return false }
        document.usbSwitch.collaborationProfileID = usbCollaborationProfilePopup.selectedItem?.representedObject as? String
        document.usbSwitch.collaborationWakeEnabled = true
        return DisplayConfigurationStore.isValidCollaborationWakeSelection(document.usbSwitch, document: document)
    }

    private func persistSelectedProfileFields(requestedEnabled: Bool?) {
        guard editingProfiles.indices.contains(selectedProfileIndex), let document = configurationDocument else { return }
        var profile = editingProfiles[selectedProfileIndex]
        profile.name = profileNameField.stringValue
        profile.peerHost = peerHostField.stringValue
        profile.peerPort = peerPortField.integerValue
        profile.pairingCode = pairingCodeField.stringValue.precomposedStringWithCanonicalMapping
        if let requestedEnabled { profile.coordinationEnabled = requestedEnabled }
        let mapping = document.displays.compactMap { display -> DisplayInputMapping? in
            guard let field = inputFields[display.id.lowercased()], let value = Int(field.stringValue),
                  (0...65535).contains(value) else { return nil }
            return DisplayInputMapping(displayID: display.id, peerInput: value)
        }
        profile.displayInputs = mapping
        let decision = DisplayConfigurationStore.profileForSafeSave(profile, displays: document.displays)
        peerCoordinationCheckbox.state = decision.profile.coordinationEnabled ? .on : .off
        let didSave = persistDocument { value in
            value.collaborationProfiles[self.selectedProfileIndex] = decision.profile
        }
        if didSave, decision.disabledBecauseIncomplete {
            showValidationError("配置不完整，已自动停用并保存当前输入。请补全所有字段后重新启用。")
        }
    }

    @discardableResult
    private func persistDocument(_ mutation: (inout DisplayConfigurationStoreV5Document) -> Void) -> Bool {
        guard var document = configurationDocument else { return false }
        mutation(&document)
        do {
            try AppPreferences.saveLocalConfiguration(document)
            configurationDocument = document
            editingProfiles = document.collaborationProfiles
            clearValidationError()
            onSave?()
            reloadValues(rebuildDisplayForms: false)
            return true
        } catch let error as DisplayConfigurationStoreError {
            onConfigurationSaveFailure?(error)
            reloadValues()
            showValidationError("设置未保存，已恢复最后有效值：\n\(error.localizedDescription)")
            return false
        } catch {
            onConfigurationSaveFailure?(.writeFailed)
            reloadValues()
            showValidationError("设置未保存，已恢复最后有效值。")
            return false
        }
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(AboutPageContent.repositoryURL)
    }

    @objc private func openLicense() {
        NSWorkspace.shared.open(AboutPageContent.licenseURL)
    }

    @objc private func openThirdPartyNotices() {
        NSWorkspace.shared.open(AboutPageContent.thirdPartyURL)
    }

    @objc private func refreshDiagnosticPreview() {
        diagnosticTextView.string = diagnosticReportProvider?().text
            ?? "诊断状态暂不可用。"
        diagnosticCopyStatusLabel.stringValue = ""
    }

    @objc private func copyDiagnosticPreview() {
        let preview = diagnosticTextView.string
        guard !preview.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(preview, forType: .string)
        diagnosticCopyStatusLabel.stringValue = "已复制当前预览"
    }

    private func reloadLaunchAtLoginState() {
        guard #available(macOS 13.0, *) else { return }
        let status = SMAppService.mainApp.status
        launchAtLoginCheckbox.state = (status == .enabled || status == .requiresApproval) ? .on : .off
    }

    private func reloadValues(rebuildDisplayForms shouldRebuildDisplayForms: Bool = true) {
        learnUSBButton.isEnabled = true
        let loaded = AppPreferences.loadDisplayConfigurations()
        configurationDocument = loaded.document
        editingProfiles = loaded.collaborationProfiles
        if editingProfiles.isEmpty {
            editingProfiles = [CollaborationProfile(
                id: UUID().uuidString, name: "配置 1", peerHost: "", peerPort: 49731,
                pairingCode: "", peerEndpointID: nil, peerProtocolVersion: nil,
                coordinationEnabled: false, displayInputs: [], triggerDevices: []
            )]
        }
        selectedProfileIndex = min(selectedProfileIndex, editingProfiles.count - 1)
        usbLearningPending = false
        reloadProfilePopup()
        linkedCheckbox.state = loaded.document.linkAllDisplays ? .on : .off
        usbAutomationCheckbox.state = loaded.document.usbSwitch.enabled ? .on : .off
        usbArrivalSwitchCheckbox.state = loaded.document.usbSwitch.collaborationWakeEnabled ? .on : .off
        usbStatusLabel.stringValue = loaded.document.usbSwitch.enabled ? "等待设备状态" : "USB 切换未启用"
        usbStatusLabel.textColor = .secondaryLabelColor
        reloadUSBControls(document: loaded.document)
        refreshSelectedCollaborationStatus()
        let configurations = loaded.configurations
        if shouldRebuildDisplayForms {
            rebuildDisplayForms(configurations)
        }
        for configuration in configurations {
            let index = configuration.index
            guard let stored = loaded.document.displays[safe: index - 1] else { continue }
            let values: [(DDCCommand, Bool, Bool)] = [
                (.luminance, stored.brightnessEnabled, stored.brightnessShowInTray),
                (.contrast, stored.contrastEnabled, stored.contrastShowInTray),
                (.volume, stored.volumeEnabled, stored.volumeShowInTray)
            ]
            for (command, enabled, inTray) in values {
                displayFeatureSwitches[index]?[command]?.state = enabled ? .on : .off
                displayTraySwitches[index]?[command]?.state = inTray ? .on : .off
                displayTraySwitches[index]?[command]?.isEnabled = enabled
                displaySliders[index]?[command]?.isEnabled = enabled
            }
        }
        restoreCachedDDCValues(in: loaded.document)
        loadSelectedProfileFields()
        refreshSelectedCollaborationStatus()

        if #available(macOS 13.0, *) {
            reloadLaunchAtLoginState()
            launchAtLoginCheckbox.isEnabled = true
        } else {
            launchAtLoginCheckbox.state = .off
            launchAtLoginCheckbox.isEnabled = false
            launchAtLoginCheckbox.toolTip = "需要 macOS 13 或更高版本"
        }
    }

    private func restoreCachedDDCValues(in document: DisplayConfigurationStoreV5Document) {
        guard let cachedDDCValue else { return }
        let entries = DisplayCachedValuePresentation.entries(
            displays: document.displays,
            cachedValue: cachedDDCValue
        )
        let indexByStableID = Dictionary(uniqueKeysWithValues: document.displays.enumerated().map {
            ($0.element.id.lowercased(), $0.offset + 1)
        })
        for entry in entries {
            guard let index = indexByStableID[entry.stableID] else { continue }
            displaySliders[index]?[entry.command]?.integerValue = entry.value
            displayValueLabels[index]?[entry.command]?.stringValue = entry.label
        }
    }

    private func reloadProfilePopup() {
        profilePopup.removeAllItems()
        profilePopup.addItems(withTitles: editingProfiles.map(\.name))
        profilePopup.selectItem(at: selectedProfileIndex)
        removeProfileButton.isEnabled = editingProfiles.count > 1
        moveProfileUpButton.isEnabled = selectedProfileIndex > 0
        moveProfileDownButton.isEnabled = selectedProfileIndex + 1 < editingProfiles.count
    }

    private func reloadUSBControls(document: DisplayConfigurationStoreV5Document) {
        updateUSBDeviceLabel()
        usbCollaborationProfilePopup.removeAllItems()
        usbCollaborationProfilePopup.addItem(withTitle: "未选择")
        usbCollaborationProfilePopup.lastItem?.representedObject = nil
        for profile in document.collaborationProfiles {
            usbCollaborationProfilePopup.addItem(withTitle: profile.name)
            usbCollaborationProfilePopup.lastItem?.representedObject = profile.id
        }
        if let selectedID = document.usbSwitch.collaborationProfileID,
           let index = document.collaborationProfiles.firstIndex(where: {
               $0.id.caseInsensitiveCompare(selectedID) == .orderedSame
           }) {
            usbCollaborationProfilePopup.selectItem(at: index + 1)
        } else {
            usbCollaborationProfilePopup.selectItem(at: 0)
        }
        usbCollaborationProfilePopup.isEnabled = true

        let mappings = Dictionary(uniqueKeysWithValues: document.usbSwitch.displayInputs.map {
            ($0.displayID.lowercased(), $0.targetInput)
        })
        let descriptors = DisplayInputMappingPresentation.rows(
            displays: document.displays, context: .usb
        )
        var reconciled: [String: DisplayInputMappingRowView] = [:]
        for descriptor in descriptors {
            let row = usbMappingRows[descriptor.displayID] ?? DisplayInputMappingRowView()
            row.update(
                title: descriptor.title,
                value: mappings[descriptor.displayID].map(String.init) ?? "",
                delegate: self
            )
            reconciled[descriptor.displayID] = row
        }
        replaceMappingRows(in: usbMappingStack, rows: descriptors.compactMap {
            reconciled[$0.displayID]
        })
        usbMappingRows = reconciled
        usbInputFields = reconciled.mapValues(\.inputField)
    }

    private func loadSelectedProfileFields() {
        guard editingProfiles.indices.contains(selectedProfileIndex) else { return }
        let profile = editingProfiles[selectedProfileIndex]
        profileNameField.stringValue = profile.name
        peerHostField.stringValue = profile.peerHost
        peerPortField.integerValue = profile.peerPort
        pairingCodeField.stringValue = profile.pairingCode
        peerCoordinationCheckbox.state = profile.coordinationEnabled ? .on : .off
        rebuildProfileMappings(profile: profile)
    }

    private func rebuildProfileMappings(profile: CollaborationProfile) {
        profileMappingStack.orientation = .vertical
        profileMappingStack.alignment = .leading
        profileMappingStack.spacing = 6
        let mappings = Dictionary(uniqueKeysWithValues: profile.displayInputs.map {
            ($0.displayID.lowercased(), $0.peerInput)
        })
        let descriptors = DisplayInputMappingPresentation.rows(
            displays: configurationDocument?.displays ?? [], context: .collaboration
        )
        var reconciled: [String: DisplayInputMappingRowView] = [:]
        for descriptor in descriptors {
            let row = profileMappingRows[descriptor.displayID] ?? DisplayInputMappingRowView()
            row.update(
                title: descriptor.title,
                value: mappings[descriptor.displayID].map(String.init) ?? "",
                delegate: self
            )
            reconciled[descriptor.displayID] = row
        }
        replaceMappingRows(in: profileMappingStack, rows: descriptors.compactMap {
            reconciled[$0.displayID]
        })
        profileMappingRows = reconciled
        inputFields = reconciled.mapValues(\.inputField)
    }

    private func replaceMappingRows(in stack: NSStackView, rows: [DisplayInputMappingRowView]) {
        let desired = Set(rows.map(ObjectIdentifier.init))
        for view in stack.arrangedSubviews where !desired.contains(ObjectIdentifier(view)) {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        stack.setViews(rows, in: .center)
    }

    @objc private func profileSelectionChanged(_ sender: NSPopUpButton) {
        selectedProfileIndex = max(0, sender.indexOfSelectedItem)
        reloadProfilePopup()
        loadSelectedProfileFields()
    }

    @objc private func addProfile() {
        var counter = editingProfiles.count + 1
        var name = "配置 \(counter)"
        let names = Set(editingProfiles.map { $0.name.lowercased() })
        while names.contains(name.lowercased()) { counter += 1; name = "配置 \(counter)" }
        editingProfiles.append(CollaborationProfile(id: UUID().uuidString, name: name, peerHost: "", peerPort: 49731,
            pairingCode: "", peerEndpointID: nil, peerProtocolVersion: nil, coordinationEnabled: false,
            displayInputs: [], triggerDevices: []))
        selectedProfileIndex = editingProfiles.count - 1
        persistDocument { $0.collaborationProfiles = self.editingProfiles }
    }

    @objc private func removeProfile() {
        guard editingProfiles.count > 1, editingProfiles.indices.contains(selectedProfileIndex) else { return }
        let alert = NSAlert()
        alert.messageText = "删除协同配置？"
        alert.informativeText = "此操作会取消该配置尚未完成的本机操作。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let removedProfileID = editingProfiles[selectedProfileIndex].id
        editingProfiles.remove(at: selectedProfileIndex)
        selectedProfileIndex = min(selectedProfileIndex, editingProfiles.count - 1)
        persistDocument {
            $0.collaborationProfiles = self.editingProfiles
            if $0.usbSwitch.collaborationProfileID?.caseInsensitiveCompare(removedProfileID) == .orderedSame {
                $0.usbSwitch.collaborationProfileID = nil
                $0.usbSwitch.collaborationWakeEnabled = false
            }
        }
    }

    @objc private func moveProfileUp() { moveSelectedProfile(by: -1) }
    @objc private func moveProfileDown() { moveSelectedProfile(by: 1) }

    private func moveSelectedProfile(by delta: Int) {
        let target = selectedProfileIndex + delta
        guard editingProfiles.indices.contains(target) else { return }
        editingProfiles.swapAt(selectedProfileIndex, target)
        selectedProfileIndex = target
        persistDocument { $0.collaborationProfiles = self.editingProfiles }
    }

    @objc private func inspectCurrentProfile() {
        performCurrentProfileInspection()
    }

    @objc private func requestLocalNetworkPermission() {
        performCurrentProfileInspection()
    }

    private func performCurrentProfileInspection() {
        guard editingProfiles.indices.contains(selectedProfileIndex), let document = configurationDocument else { return }
        let localIDs = DDCController.hasLocalBackendWithoutHardwareAccess
            ? Set(document.displays.map { $0.id.lowercased() }) : Set<String>()
        let inspection = DisplayConfigurationStore.inspectProfile(editingProfiles[selectedProfileIndex], displays: document.displays,
                                                                  ddcAvailableDisplayIDs: localIDs)
        guard inspection.isComplete else {
            let alert = NSAlert()
            alert.messageText = "本机配置需要检查"
            var messages = inspection.issues.map(\.userFacingDescription)
            if !inspection.ddcUnavailableDisplayIDs.isEmpty {
                messages.append(DDCController.backendSummaryWithoutHardwareAccess)
            }
            alert.informativeText = messages.map { "• \($0)" }.joined(separator: "\n")
            alert.beginSheetModal(for: window!)
            return
        }
        let profile = editingProfiles[selectedProfileIndex]
        guard let onInspectPeer else {
            updateLocalNetworkPermissionPresentation(.ordinaryNetworkFailure)
            showPeerInspectionResult(.noResponse, profileID: profile.id)
            return
        }
        inspectProfileButton.isEnabled = false
        requestLocalNetworkPermissionButton.isEnabled = false
        peerStatusLabel.stringValue = "正在检测 \(profile.name)…"
        LocalNetworkPermissionInspectionAction.perform(using: { completion in
            onInspectPeer(profile, completion)
        }) { [weak self] result, permissionEvidence in
            DispatchQueue.main.async {
                self?.inspectProfileButton.isEnabled = true
                self?.requestLocalNetworkPermissionButton.isEnabled = true
                self?.updateLocalNetworkPermissionPresentation(permissionEvidence)
                self?.showPeerInspectionResult(result, profileID: profile.id)
            }
        }
    }

    private func updateLocalNetworkPermissionPresentation(_ evidence: LocalNetworkPermissionEvidence) {
        let presentation = LocalNetworkPermissionPresentation.make(for: evidence)
        localNetworkPermissionStatusLabel.stringValue = presentation.statusText
        localNetworkPermissionStatusLabel.textColor = presentation.isFailure ? .systemRed : .labelColor
        localNetworkPermissionDetailLabel.stringValue = presentation.detailText
    }

    private func showPeerInspectionResult(_ result: PeerCapabilityInspectionResult, profileID: String) {
        guard let index = editingProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        let profile = editingProfiles[index]
        switch result {
        case .v2(let endpointID):
            let identity = DisplayConfigurationStore.checkPeerIdentity(profile, endpointID: endpointID, protocolVersion: 2)
            if identity == .unchanged {
                peerStatusLabel.stringValue = "\(profile.name)：v2 可用"
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = identity.requiresConfirmation ? "确认对端逻辑身份" : "检测结果无效"
            alert.informativeText = "\(profile.name) 返回了新的逻辑身份。只有确认这是预期对端后才会用于协同。"
            alert.addButton(withTitle: "确认")
            alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window!) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn,
                      let current = self.editingProfiles.firstIndex(where: { $0.id == profileID }) else { return }
                self.editingProfiles[current].peerEndpointID = endpointID.lowercased()
                self.editingProfiles[current].peerProtocolVersion = 2
                self.persistDocument { $0.collaborationProfiles = self.editingProfiles }
            }
        case .authenticationFailed:
            peerStatusLabel.stringValue = "\(profile.name)：认证失败"
        case .noResponse:
            peerStatusLabel.stringValue = "\(profile.name)：无响应"
        }
    }

    @available(macOS 13.0, *)
    private func setLaunchAtLogin(enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status == .notRegistered {
                try service.register()
            }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    }

    private func updateLaunchAtLogin() throws {
        guard #available(macOS 13.0, *) else { return }
        try setLaunchAtLogin(enabled: launchAtLoginCheckbox.state == .on)
    }

    private func showValidationError(_ message: String) {
        validationLabel.stringValue = message.replacingOccurrences(of: "\n", with: " ")
        validationLabel.isHidden = false
    }

    private func clearValidationError() {
        validationLabel.stringValue = ""
        validationLabel.isHidden = true
    }

    @objc private func learnUSBDevice() {
        usbLearningPending = true
        usbDeviceLabel.stringValue = "等待 USB 变化，请按一次切换器…"
        learnUSBButton.isEnabled = false
        onLearnUSB?()
    }

    @discardableResult
    func presentDetectedUSBDevices(_ devices: [USBDevice]) -> Bool {
        guard usbLearningPending else {
            updateUSBDeviceLabel()
            return false
        }
        guard !devices.isEmpty else {
            usbLearningPending = false
            learnUSBButton.isEnabled = true
            updateUSBDeviceLabel()
            onUSBLearningFinished?()
            return true
        }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 430, height: 26))
        devices.forEach { popup.addItem(withTitle: $0.displayName) }

        let alert = NSAlert()
        alert.messageText = "选择 USB 触发设备"
        alert.informativeText = "以下设备在切换动作中发生了变化。请选择一个稳定存在于键鼠链路上的设备。"
        alert.accessoryView = popup
        alert.addButton(withTitle: "使用此设备")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard let self else { return }
            defer {
                self.usbLearningPending = false
                self.learnUSBButton.isEnabled = true
                self.updateUSBDeviceLabel()
                self.onUSBLearningFinished?()
            }
            if response == .alertFirstButtonReturn, popup.indexOfSelectedItem >= 0,
               self.usbLearningPending {
                let device = devices[popup.indexOfSelectedItem]
                self.persistDocument {
                    $0.usbSwitch.triggerDevice = CollaborationTriggerDevice(
                        kind: "usb",
                        localReference: device.localReference,
                        displayName: device.name
                    )
                    $0.usbSwitch.enabled = false
                }
            }
        }
        return true
    }

    private func updateUSBDeviceLabel() {
        usbDeviceLabel.stringValue = configurationDocument?.usbSwitch.triggerDevice?.displayName ?? "未选择触发设备"
    }

    func windowWillClose(_ notification: Notification) {
        usbLearningPending = false
        learnUSBButton.isEnabled = true
        onCancelUSBLearning?()
        onWindowClosed?()
    }
}
