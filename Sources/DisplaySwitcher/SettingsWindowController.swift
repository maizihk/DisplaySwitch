import AppKit
import Foundation
import ServiceManagement

private extension NSColor {
    func cgColor(using appearance: NSAppearance) -> CGColor {
        var result = NSColor.clear.cgColor
        appearance.performAsCurrentDrawingAppearance {
            result = cgColor
        }
        return result
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

private final class FlippedDocumentView: NSView {
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

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onSave: (() -> Void)?
    var onImmediateChange: (() -> Void)?
    var onLearnUSB: (() -> Void)?
    var onCancelUSBLearning: (() -> Void)?

    private let linkedCheckbox = NSSwitch()
    private let launchAtLoginCheckbox = NSSwitch()
    private let usbAutomationCheckbox = NSSwitch()
    private let usbArrivalSwitchCheckbox = NSSwitch()
    private let peerCoordinationCheckbox = NSSwitch()
    private let peerHostField = NSTextField()
    private let peerPortField = NSTextField()
    private let pairingCodeField = NSSecureTextField()
    private let peerStatusLabel = NSTextField(wrappingLabelWithString: "协同未启用")
    private let usbDeviceLabel = NSTextField(wrappingLabelWithString: "未选择触发设备")
    private lazy var learnUSBButton = NSButton(title: "学习 USB 设备…", target: self, action: #selector(learnUSBDevice))
    private var nameFields: [Int: NSTextField] = [:]
    private var selectorFields: [Int: NSTextField] = [:]
    private var macInputFields: [Int: NSTextField] = [:]
    private var inputFields: [Int: NSTextField] = [:]
    private var readCheckboxes: [Int: NSSwitch] = [:]
    private let displayStack = NSStackView()
    private var pendingUSBDevice: USBDevice?
    private let tabView = NSTabView()
    private let navigationSeparator = NSBox()
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
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildInterface()
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

    func updatePeerConnectionStatus(_ text: String, connected: Bool) {
        peerStatusLabel.stringValue = text
        peerStatusLabel.textColor = connected ? .systemGreen : .secondaryLabelColor
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        linkedCheckbox.target = self
        linkedCheckbox.action = #selector(immediateSwitchChanged(_:))
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(immediateSwitchChanged(_:))
        usbArrivalSwitchCheckbox.target = self
        usbArrivalSwitchCheckbox.action = #selector(immediateSwitchChanged(_:))

        let tabs = [
            ("常规", "gearshape.fill"),
            ("USB 切换", "cable.connector"),
            ("双端协同", "network"),
            ("显示器", "display.2"),
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

        let generalHint = NSTextField(wrappingLabelWithString: "以上选项点击后立即生效，不需要再按保存。")
        generalHint.textColor = .secondaryLabelColor
        generalHint.font = .systemFont(ofSize: 11)
        tabView.addTabViewItem(makePage(label: "常规", views: [
            module(title: "常规", views: [
                switchRow(
                    button: linkedCheckbox,
                    title: "联动调节所有显示器",
                    description: "调节亮度、对比度或音量时同步控制已检测到的显示器。",
                    symbolName: "link"
                ),
                separator(),
                switchRow(
                    button: launchAtLoginCheckbox,
                    title: "登录时启动",
                    description: "登录 macOS 后自动在菜单栏启动显示器控制。",
                    symbolName: "power"
                )
            ]),
            generalHint
        ]))

        usbDeviceLabel.textColor = .secondaryLabelColor
        usbDeviceLabel.maximumNumberOfLines = 2
        let usbRow = NSStackView(views: [learnUSBButton, usbDeviceLabel])
        usbRow.orientation = .horizontal
        usbRow.alignment = .centerY
        usbRow.spacing = 10
        let usbHint = NSTextField(wrappingLabelWithString: "触发设备消失时切换到 Windows；回到 Mac 时只切换未在 Mac 上活动的显示器。学习时请按一次 USB 切换器。")
        usbHint.textColor = .secondaryLabelColor
        usbHint.font = .systemFont(ofSize: 11)
        peerHostField.placeholderString = "Windows IP，例如 192.168.1.20"
        peerPortField.placeholderString = "49731"
        pairingCodeField.placeholderString = "两端填写相同的配对码"
        let peerGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Windows IP"), peerHostField],
            [NSTextField(labelWithString: "通信端口"), peerPortField],
            [NSTextField(labelWithString: "配对码"), pairingCodeField]
        ])
        peerGrid.rowSpacing = 8
        peerGrid.columnSpacing = 12
        peerGrid.column(at: 0).xPlacement = .trailing
        peerGrid.column(at: 1).width = 410
        peerStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        let peerHint = NSTextField(wrappingLabelWithString: "协同开启后，USB 离开时先通知 Windows；确认 Hub 已接入并唤醒后再切屏。通信失败时会超时退化为直接切屏。")
        peerHint.textColor = .secondaryLabelColor
        peerHint.font = .systemFont(ofSize: 11)
        tabView.addTabViewItem(makePage(label: "USB 切换", views: [
            module(title: "USB 自动切换", views: [
                switchRow(
                    button: usbAutomationCheckbox,
                    title: "USB 自动切换",
                    description: "监测指定 USB Hub 的接入和离开，自动触发电脑交接。",
                    symbolName: "cable.connector"
                ),
                separator(),
                switchRow(
                    button: usbArrivalSwitchCheckbox,
                    title: "回到 Mac 时按需切屏",
                    description: "仅切换没有在 Mac 上活动的显示器；双端协同时由握手流程接管。",
                    symbolName: "display.2"
                ),
                separator(),
                usbRow,
                usbHint
            ])
        ]))

        tabView.addTabViewItem(makePage(label: "双端协同", views: [
            module(title: "双端协同", views: [
                switchRow(
                    button: peerCoordinationCheckbox,
                    title: "Mac / Windows 网络协同",
                    description: "目标电脑确认 USB 已接入并唤醒后，源电脑才执行切屏。",
                    symbolName: "network"
                ),
                separator(),
                peerGrid,
                peerStatusLabel,
                peerHint
            ])
        ]))

        displayStack.orientation = .vertical
        displayStack.alignment = .leading
        displayStack.spacing = 12
        tabView.addTabViewItem(makeDisplayPage())
        tabView.addTabViewItem(makeAboutPage())

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "保存", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttons)

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
            tabView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)
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
    }

    private func makePage(label: String, views: [NSView]) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        let container = NSView()
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
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        displayStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(displayStack)
        scrollView.documentView = documentView
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

    private func makeAboutPage() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "关于")
        item.label = "关于"

        let container = NSView()
        let iconView = NSImageView(image: NSApplication.shared.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "DisplaySwitcher"
        let nameLabel = NSTextField(labelWithString: appName)
        nameLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        nameLabel.alignment = .center

        let introduction = NSTextField(
            wrappingLabelWithString: "一款在 macOS 与 Windows 之间协同切换显示器和 USB 设备的原生菜单栏工具。"
        )
        introduction.font = .systemFont(ofSize: 13)
        introduction.textColor = .secondaryLabelColor
        introduction.alignment = .center
        introduction.maximumNumberOfLines = 2
        introduction.preferredMaxLayoutWidth = 520

        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "未知"
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "未知"
        let versionLabel = NSTextField(
            labelWithString: "版本 \(shortVersion) (\(buildVersion))"
        )
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.alignment = .center

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

        let stack = NSStackView(views: [
            iconView,
            nameLabel,
            introduction,
            versionLabel,
            githubButton
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: iconView)
        stack.setCustomSpacing(6, after: nameLabel)
        stack.setCustomSpacing(20, after: versionLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 112),
            iconView.heightAnchor.constraint(equalToConstant: 112),
            introduction.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 64)
        ])

        item.view = container
        return item
    }

    private func rebuildDisplayForms(_ configurations: [DisplayConfiguration]) {
        for view in displayStack.arrangedSubviews {
            displayStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        nameFields.removeAll()
        selectorFields.removeAll()
        macInputFields.removeAll()
        inputFields.removeAll()
        readCheckboxes.removeAll()

        for configuration in configurations.sorted(by: { $0.index < $1.index }) {
            displayStack.addArrangedSubview(module(
                title: "显示器 \(configuration.index)",
                views: [displayForm(index: configuration.index)]
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

    private func module(title: String, views: [NSView]) -> NSView {
        let heading = sectionTitle(title)
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

        let wrapper = NSStackView(views: [heading, card])
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

    private func displayForm(index: Int) -> NSView {
        let nameField = NSTextField()
        let selectorField = NSTextField()
        let macInputField = NSTextField()
        macInputField.placeholderString = "例如 15"
        let inputField = NSTextField()
        inputField.placeholderString = "例如 18"
        let readCheckbox = NSSwitch()

        nameFields[index] = nameField
        selectorFields[index] = selectorField
        macInputFields[index] = macInputField
        inputFields[index] = inputField
        readCheckboxes[index] = readCheckbox

        for detectedField in [nameField, selectorField] {
            detectedField.isEditable = false
            detectedField.isSelectable = true
            detectedField.backgroundColor = .controlBackgroundColor
            detectedField.toolTip = "由 App 启动时自动检测"
        }

        for field in [nameField, selectorField, macInputField, inputField] {
            field.controlSize = .small
            field.font = .systemFont(ofSize: 12)
        }
        readCheckbox.controlSize = .small
        readCheckbox.setContentHuggingPriority(.required, for: .horizontal)

        func compactLabel(_ title: String, width: CGFloat) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
            return label
        }

        nameField.widthAnchor.constraint(equalToConstant: 132).isActive = true
        selectorField.widthAnchor.constraint(equalToConstant: 258).isActive = true
        macInputField.widthAnchor.constraint(equalToConstant: 132).isActive = true
        inputField.widthAnchor.constraint(equalToConstant: 72).isActive = true

        func fieldGroup(label: String, labelWidth: CGFloat, field: NSTextField) -> NSStackView {
            let group = NSStackView(views: [compactLabel(label, width: labelWidth), field])
            group.orientation = .horizontal
            group.alignment = .centerY
            group.spacing = 8
            return group
        }

        let nameGroup = fieldGroup(label: "名称", labelWidth: 80, field: nameField)
        nameGroup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let selectorGroup = fieldGroup(label: "System UUID", labelWidth: 92, field: selectorField)
        selectorGroup.widthAnchor.constraint(equalToConstant: 358).isActive = true

        let identityRow = NSStackView(views: [nameGroup, selectorGroup])
        identityRow.orientation = .horizontal
        identityRow.alignment = .centerY
        identityRow.spacing = 12
        identityRow.widthAnchor.constraint(equalToConstant: 590).isActive = true

        let macInputGroup = fieldGroup(label: "Mac 输入源", labelWidth: 80, field: macInputField)
        macInputGroup.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let inputSpacer = NSView()
        let windowsAndDDCGroup = NSStackView(views: [
            compactLabel("Windows 输入源", width: 92),
            inputField,
            inputSpacer,
            compactLabel("读取 DDC", width: 60),
            readCheckbox
        ])
        windowsAndDDCGroup.orientation = .horizontal
        windowsAndDDCGroup.alignment = .centerY
        windowsAndDDCGroup.spacing = 8
        windowsAndDDCGroup.widthAnchor.constraint(equalToConstant: 358).isActive = true

        let inputRow = NSStackView(views: [macInputGroup, windowsAndDDCGroup])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 12
        inputRow.widthAnchor.constraint(equalToConstant: 590).isActive = true

        let hint = NSTextField(labelWithString: "关闭 DDC 回读后使用最后一次成功写入的缓存值，并以 ≈ 标识。")
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .tertiaryLabelColor

        let form = NSStackView(views: [identityRow, inputRow, hint])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        return form
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
        if sender === linkedCheckbox {
            AppPreferences.linkedDisplays = sender.state == .on
            onImmediateChange?()
            return
        }
        if sender === usbArrivalSwitchCheckbox {
            AppPreferences.usbSwitchDisplaysOnArrival = sender.state == .on
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

    @objc private func openGitHub() {
        guard let url = URL(string: "https://github.com/maizihk/DisplaySwitch") else { return }
        NSWorkspace.shared.open(url)
    }

    private func reloadLaunchAtLoginState() {
        guard #available(macOS 13.0, *) else { return }
        let status = SMAppService.mainApp.status
        launchAtLoginCheckbox.state = (status == .enabled || status == .requiresApproval) ? .on : .off
    }

    private func reloadValues() {
        learnUSBButton.isEnabled = true
        linkedCheckbox.state = AppPreferences.linkedDisplays ? .on : .off
        usbAutomationCheckbox.state = AppPreferences.usbAutomationEnabled ? .on : .off
        usbArrivalSwitchCheckbox.state = AppPreferences.usbSwitchDisplaysOnArrival ? .on : .off
        peerCoordinationCheckbox.state = AppPreferences.peerCoordinationEnabled ? .on : .off
        updatePeerConnectionStatus(
            AppPreferences.peerCoordinationEnabled ? "等待 Windows 心跳…" : "协同未启用",
            connected: false
        )
        peerHostField.stringValue = AppPreferences.peerHost
        peerPortField.integerValue = AppPreferences.peerPort
        pairingCodeField.stringValue = AppPreferences.pairingCode
        pendingUSBDevice = AppPreferences.usbTriggerDevice
        updateUSBDeviceLabel()

        let configurations = AppPreferences.displayConfigurations
        rebuildDisplayForms(configurations)
        for configuration in configurations {
            let index = configuration.index
            nameFields[index]?.stringValue = configuration.name
            selectorFields[index]?.stringValue = configuration.selector
            macInputFields[index]?.stringValue = configuration.macInput.map(String.init) ?? ""
            inputFields[index]?.stringValue = configuration.windowsInput.map(String.init) ?? ""
            readCheckboxes[index]?.state = configuration.readEnabled ? .on : .off
        }

        if #available(macOS 13.0, *) {
            reloadLaunchAtLoginState()
            launchAtLoginCheckbox.isEnabled = true
        } else {
            launchAtLoginCheckbox.state = .off
            launchAtLoginCheckbox.isEnabled = false
            launchAtLoginCheckbox.toolTip = "需要 macOS 13 或更高版本"
        }
    }

    @objc private func save() {
        var configurations: [DisplayConfiguration] = []

        for index in nameFields.keys.sorted() {
            let name = nameFields[index]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let selector = selectorFields[index]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let macInputText = macInputFields[index]?.stringValue ?? ""
            let inputText = inputFields[index]?.stringValue ?? ""

            guard
                !name.isEmpty,
                !selector.isEmpty,
                let macInput = Int(macInputText),
                let input = Int(inputText),
                (0...65535).contains(macInput),
                (0...65535).contains(input)
            else {
                showValidationError("尚未检测到显示器 \(index)，或输入源编号不在 0–65535 范围内。")
                return
            }

            configurations.append(DisplayConfiguration(
                index: index,
                name: name,
                selector: selector,
                macInput: macInput,
                windowsInput: input,
                readEnabled: readCheckboxes[index]?.state == .on
            ))
        }

        if usbAutomationCheckbox.state == .on, pendingUSBDevice == nil {
            showValidationError("请先点击“学习 USB 设备”，选择用于触发切换的设备。")
            return
        }


        let peerHost = peerHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairingCode = pairingCodeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let peerPort = peerPortField.integerValue
        if peerCoordinationCheckbox.state == .on,
           (peerHost.isEmpty || pairingCode.count < 8 || !(1...65535).contains(peerPort)) {
            showValidationError("启用双端协同时，请填写 Windows IP、1–65535 端口以及至少 8 位配对码。")
            return
        }
        if peerCoordinationCheckbox.state == .on,
           (usbAutomationCheckbox.state != .on || pendingUSBDevice == nil) {
            showValidationError("双端协同依赖 USB Hub 的实际归属，请先启用 USB 自动切换并选择触发设备。")
            return
        }

        AppPreferences.displayConfigurations = configurations
        AppPreferences.linkedDisplays = linkedCheckbox.state == .on
        AppPreferences.usbAutomationEnabled = usbAutomationCheckbox.state == .on
        AppPreferences.usbSwitchDisplaysOnArrival = usbArrivalSwitchCheckbox.state == .on
        AppPreferences.usbTriggerDevice = pendingUSBDevice
        AppPreferences.peerCoordinationEnabled = peerCoordinationCheckbox.state == .on
        AppPreferences.peerHost = peerHost
        AppPreferences.peerPort = peerPort
        AppPreferences.pairingCode = pairingCode
        onSave?()

        window?.close()
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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法保存设置"
        alert.informativeText = message
        alert.beginSheetModal(for: window!)
    }

    @objc private func learnUSBDevice() {
        usbDeviceLabel.stringValue = "等待 USB 变化，请按一次切换器…"
        learnUSBButton.isEnabled = false
        onLearnUSB?()
    }

    func presentDetectedUSBDevices(_ devices: [USBDevice]) {
        learnUSBButton.isEnabled = true
        guard !devices.isEmpty else {
            updateUSBDeviceLabel()
            return
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
            if response == .alertFirstButtonReturn, popup.indexOfSelectedItem >= 0 {
                self.pendingUSBDevice = devices[popup.indexOfSelectedItem]
                self.usbAutomationCheckbox.state = .on
            }
            self.updateUSBDeviceLabel()
        }
    }

    private func updateUSBDeviceLabel() {
        usbDeviceLabel.stringValue = pendingUSBDevice?.displayName ?? "未选择触发设备"
    }

    @objc private func cancel() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        onCancelUSBLearning?()
    }
}
