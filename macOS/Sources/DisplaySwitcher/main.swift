import AppKit
import Darwin
import Foundation
import IOKit.pwr_mgt

private enum DisplayControl: String, CaseIterable {
    case luminance
    case contrast
    case volume

    var title: String {
        switch self {
        case .luminance: return "亮度"
        case .contrast: return "对比度"
        case .volume: return "音量"
        }
    }

    var symbolName: String {
        switch self {
        case .luminance: return "sun.max"
        case .contrast: return "circle.lefthalf.filled"
        case .volume: return "speaker.wave.2"
        }
    }

    var ddcCommand: DDCCommand {
        switch self {
        case .luminance: return .luminance
        case .contrast: return .contrast
        case .volume: return .volume
        }
    }
}

private final class SliderRowView: NSView {
    var onChange: ((Int) -> Void)?

    private let valueLabel = NSTextField(labelWithString: "—")
    private lazy var slider: NSSlider = {
        let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: self, action: #selector(valueChanged))
        slider.isContinuous = false
        return slider
    }()

    init(control: DisplayControl) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 48))

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: control.symbolName, accessibilityDescription: control.title)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: control.title)
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        slider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(slider)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            titleLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 34),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 2)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(value: Int, maximum: Int? = nil, estimated: Bool = false) {
        if let maximum {
            slider.maxValue = Double(max(maximum, 1))
        }
        slider.integerValue = min(max(value, 0), Int(slider.maxValue))
        valueLabel.stringValue = estimated ? "≈\(slider.integerValue)" : "\(slider.integerValue)"
    }

    @objc private func valueChanged() {
        valueLabel.stringValue = "\(slider.integerValue)"
        onChange?(slider.integerValue)
    }
}

private final class DisplayControls {
    let menu = NSMenu()
    private(set) var rows: [DisplayControl: SliderRowView] = [:]

    init(displayID: Int, onChange: @escaping (Int, DisplayControl, Int) -> Void) {
        menu.autoenablesItems = false

        for control in DisplayControl.allCases {
            let row = SliderRowView(control: control)
            row.onChange = { value in
                onChange(displayID, control, value)
            }

            let item = NSMenuItem()
            item.isEnabled = true
            item.view = row
            menu.addItem(item)
            rows[control] = row
        }
    }

    func update(_ control: DisplayControl, value: Int, maximum: Int? = nil, estimated: Bool = false) {
        rows[control]?.update(value: value, maximum: maximum, estimated: estimated)
    }
}

private final class LockedFirstError: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func record(_ value: Error?) {
        guard let value else { return }
        lock.lock()
        if error == nil { error = value }
        lock.unlock()
    }

    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

private struct ConfigurationSafetyBlockedError: LocalizedError {
    var errorDescription: String? {
        "显示器配置需要用户检查，本次硬件操作已取消。"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, HandoffClock, HandoffScheduler, HandoffEventIDSource, HandoffActionSink {
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var instanceLockFD: Int32 = -1
    private var ownsPrimaryInstance = false
    private let workerQueue = DispatchQueue(label: "DisplaySwitcher.ddc")
    private let ddcController = DDCController()
    private let usbMonitor = USBMonitor()
    private let peerTransport = PeerTransport()
    private let configurationSafetyGate = ConfigurationSafetyGate()
    private var pendingUSBSwitch: DispatchWorkItem?
    private var pendingSchedulerItems: [String: DispatchWorkItem] = [:]
    private lazy var handoffStateMachine = HandoffStateMachine(
        localPlatform: .mac,
        sink: self,
        clock: self,
        scheduler: self,
        eventIDSource: self
    )
    private var displayControls: [Int: DisplayControls] = [:]
    private var displayMenuItems: [Int: NSMenuItem] = [:]
    private var profileSwitchItems: [NSMenuItem] = []
    private var configurations: [Int: DisplayConfiguration] = [:]
    private var isRefreshing = false
    private var lastRefresh = Date.distantPast
    private var settingsWindowHasBeenShown = false

    private lazy var settingsWindowController: SettingsWindowController = {
        let controller = SettingsWindowController()
        controller.onSave = { [weak self] in
            self?.reloadSettings()
        }
        controller.onConfigurationSaveFailure = { [weak self] error in
            self?.enterConfigurationSafetyState(error)
        }
        controller.onImmediateChange = { [weak self] in
            self?.linkedItem.state = AppPreferences.linkedDisplays ? .on : .off
        }
        controller.onLearnUSB = { [weak self] in
            self?.startUSBLearning()
        }
        controller.onCancelUSBLearning = { [weak self] in
            self?.usbMonitor.cancelLearning()
        }
        return controller
    }()

    private lazy var switchItem: NSMenuItem = {
        let item = NSMenuItem(title: "切换到 Windows", action: #selector(switchToWindows), keyEquivalent: "")
        item.target = self
        return item
    }()

    private lazy var switchToMacItem: NSMenuItem = {
        let item = NSMenuItem(title: "切换到 Mac", action: #selector(switchToMac), keyEquivalent: "")
        item.target = self
        return item
    }()

    private lazy var linkedItem: NSMenuItem = {
        let item = NSMenuItem(title: "联动所有显示器", action: #selector(toggleLinkedControls), keyEquivalent: "")
        item.target = self
        item.state = AppPreferences.linkedDisplays ? .on : .off
        return item
    }()

    private lazy var detectItem: NSMenuItem = {
        let item = NSMenuItem(title: "重新检测显示器", action: #selector(detectDisplaysManually), keyEquivalent: "")
        item.target = self
        return item
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstanceLock(), !hasAnotherRunningInstance() else {
            releaseSingleInstanceLock()
            NSApplication.shared.terminate(nil)
            return
        }
        ownsPrimaryInstance = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ownsPrimaryInstance else { return }
        let loadResult = AppPreferences.loadDisplayConfigurations()
        configurationSafetyGate.apply(loadResult)
        configurations = Dictionary(uniqueKeysWithValues: loadResult.configurations.map {
            ($0.index, $0)
        })
        ddcController.updateConfigurations(loadResult.configurations)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "显示器控制")
        }

        let menu = NSMenu()
        menu.delegate = self
        rebuildProfileSwitchItems(in: menu)
        menu.addItem(.separator())

        menu.addItem(linkedItem)
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "刷新当前数值", action: #selector(refreshValuesManually), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(detectItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        rebuildDisplayMenuItems()
        updateConfigurationSafetyUI()
        restoreCachedValues()

        usbMonitor.onPresenceChanged = { [weak self] isPresent in
            self?.handleUSBPresenceChange(isPresent)
        }
        peerTransport.onMessage = { [weak self] message, _ in
            self?.handoffStateMachine.handleIncomingMessage(message)
        }
        peerTransport.onError = { message in
            NSLog("DisplaySwitcher: %@", message)
        }
        configureUSBMonitor()
        configurePeerTransport()
        detectDisplays(showFailure: false)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshValues(force: false)
    }

    @objc private func switchToWindows() {
        switchInputs(toMac: false)
    }

    @objc private func switchToProfile(_ sender: NSMenuItem) {
        guard let profileID = sender.representedObject as? String else { return }
        let document = AppPreferences.localConfiguration
        guard let profile = document.collaborationProfiles.first(where: { $0.id == profileID }) else { return }
        let mappings = Dictionary(uniqueKeysWithValues: profile.displayInputs.map { ($0.displayID.lowercased(), $0.peerInput) })
        let selected = Dictionary(uniqueKeysWithValues: configurations.map { index, configuration in
            var value = configuration
            if let id = configuration.id { value.windowsInput = mappings[id.lowercased()] } else { value.windowsInput = nil }
            return (index, value)
        })
        switchInputs(toMac: false, overrideConfigurations: selected, activeMenuItem: sender)
    }

    @objc private func switchToMac() {
        switchInputs(toMac: true)
    }

    private func switchInputs(
        toMac: Bool,
        displayIDs: [Int]? = nil,
        completion: ((Bool) -> Void)? = nil,
        overrideConfigurations: [Int: DisplayConfiguration]? = nil,
        activeMenuItem: NSMenuItem? = nil
    ) {
        guard configurationSafetyGate.allows(.ddc) else {
            completion?(false)
            return
        }
        let targetDisplayIDs = displayIDs ?? configurations.keys.sorted()
        guard !targetDisplayIDs.isEmpty else {
            completion?(false)
            return
        }
        let activeItem = activeMenuItem ?? (toMac ? switchToMacItem : switchItem)
        activeItem.title = "正在切换…"
        switchToMacItem.isEnabled = false
        switchItem.isEnabled = false
        profileSwitchItems.forEach { $0.isEnabled = false }
        let currentConfigurations = overrideConfigurations ?? configurations
        let ddcController = ddcController

        workerQueue.async { [weak self] in
            let firstError = LockedFirstError()
            let group = DispatchGroup()
            for displayID in targetDisplayIDs {
                guard let configuration = currentConfigurations[displayID] else { continue }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    defer { group.leave() }
                    guard self?.configurationSafetyGate.allows(.ddc) == true else {
                        firstError.record(ConfigurationSafetyBlockedError())
                        return
                    }
                    var succeeded = false
                    var displayError: Error?
                    for attempt in 0..<2 {
                        do {
                            guard let input = toMac
                                ? configuration.macInput
                                : configuration.windowsInput else {
                                throw DDCError.inputNotConfigured(displayName: configuration.name)
                            }
                            try ddcController.write(
                                selector: configuration.selector,
                                command: .input,
                                value: input
                            )
                            succeeded = true
                            break
                        } catch {
                            displayError = error
                            if attempt == 0 { Thread.sleep(forTimeInterval: 0.15) }
                        }
                    }
                    if !succeeded {
                        firstError.record(displayError)
                    }
                }
            }
            group.wait()

            if let firstError = firstError.value {
                self?.finishSwitch(message: "部分切换失败", toMac: toMac, activeMenuItem: activeMenuItem)
                self?.showError(title: "显示器切换失败", error: firstError)
                DispatchQueue.main.async { completion?(false) }
            } else {
                self?.finishSwitch(message: toMac ? "已切换到本机" : "切换完成", toMac: toMac, activeMenuItem: activeMenuItem)
                DispatchQueue.main.async { completion?(true) }
            }
        }
    }

    @objc private func toggleLinkedControls() {
        linkedItem.state = linkedItem.state == .on ? .off : .on
        AppPreferences.linkedDisplays = linkedItem.state == .on
    }

    @objc private func refreshValuesManually() {
        refreshValues(force: true)
    }

    @objc private func detectDisplaysManually() {
        detectDisplays(showFailure: true)
    }

    private func detectDisplays(showFailure: Bool) {
        guard configurationSafetyGate.allows(.ddc) else {
            if showFailure, case .requiresUserReview(let error) = configurationSafetyGate.state {
                showError(title: "配置安全模式已启用", error: error)
            }
            return
        }
        detectItem.isEnabled = false
        detectItem.title = "正在检测…"
        let ddcController = ddcController
        let existing = configurations.values.sorted { $0.index < $1.index }

        workerQueue.async { [weak self] in
            do {
                let detectedDisplays = try ddcController.detectDisplays(
                    existingConfigurations: existing
                )

                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.configurationSafetyGate.allows(.ddc) else {
                        self.finishDetection()
                        return
                    }
                    do {
                        let merged = try DisplayConfigurationStore.merge(
                            detected: detectedDisplays,
                            existing: existing
                        )
                        self.configurations = Dictionary(uniqueKeysWithValues: merged.map {
                            ($0.index, $0)
                        })
                        ddcController.updateConfigurations(merged)
                        self.rebuildDisplayMenuItems()
                        self.restoreCachedValues()
                        self.finishDetection()
                        self.refreshValues(force: true)
                    } catch let error as DisplayConfigurationStoreError {
                        self.finishDetection()
                        self.enterConfigurationSafetyState(error)
                        if showFailure {
                            self.showError(title: "显示器配置保存失败", error: error)
                        }
                    } catch {
                        self.finishDetection()
                        self.enterConfigurationSafetyState(.writeFailed)
                        if showFailure {
                            self.showError(title: "显示器配置保存失败", error: error)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.finishDetection()
                    self?.refreshValues(force: true)
                    if showFailure {
                        self?.showError(title: "显示器检测失败", error: error)
                    }
                }
            }
        }
    }

    private func finishDetection() {
        detectItem.title = "重新检测显示器"
        detectItem.isEnabled = true
    }

    private func refreshValues(force: Bool) {
        guard configurationSafetyGate.allows(.ddc) else { return }
        guard !isRefreshing else { return }
        guard force || Date().timeIntervalSince(lastRefresh) > 3 else { return }
        isRefreshing = true
        let currentConfigurations = configurations
        let ddcController = ddcController

        workerQueue.async { [weak self] in
            guard self?.configurationSafetyGate.allows(.ddc) == true else {
                DispatchQueue.main.async { self?.isRefreshing = false }
                return
            }
            var readings: [Int: [DisplayControl: (current: Int, maximum: Int)]] = [:]

            for displayID in currentConfigurations.keys.sorted() {
                guard
                    let configuration = currentConfigurations[displayID],
                    configuration.readEnabled
                else {
                    continue
                }

                for control in DisplayControl.allCases {
                    guard self?.configurationSafetyGate.allows(.ddc) == true else { break }
                    guard let reading = ddcController.read(
                        selector: configuration.selector,
                        command: control.ddcCommand
                    ) else {
                        continue
                    }

                    let maximum = Self.validatedMaximum(reading.maximum, current: reading.current)
                    readings[displayID, default: [:]][control] = (reading.current, maximum)
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                for displayID in currentConfigurations.keys.sorted() {
                    let displayReadings = readings[displayID] ?? [:]
                    let readEnabled = currentConfigurations[displayID]?.readEnabled ?? true
                    let hasInvalidAllZeroReply = displayReadings.count == DisplayControl.allCases.count
                        && displayReadings.values.allSatisfy { $0.current == 0 }

                    if !readEnabled || hasInvalidAllZeroReply {
                        self.applyFallbackValues(to: displayID, readings: readings)
                        continue
                    }

                    for (control, reading) in displayReadings {
                        self.displayControls[displayID]?.update(
                            control,
                            value: reading.current,
                            maximum: reading.maximum
                        )
                        self.saveCachedValue(reading.current, displayID: displayID, control: control)
                    }
                }
                self.lastRefresh = Date()
                self.isRefreshing = false
            }
        }
    }

    private func setControl(_ control: DisplayControl, value: Int, fromDisplay displayID: Int) {
        guard configurationSafetyGate.allows(.ddc) else { return }
        let targetDisplays = linkedItem.state == .on ? configurations.keys.sorted() : [displayID]
        let currentConfigurations = configurations
        let ddcController = ddcController

        for targetID in targetDisplays {
            displayControls[targetID]?.update(control, value: value)
        }

        workerQueue.async { [weak self] in
            do {
                for targetID in targetDisplays {
                    guard self?.configurationSafetyGate.allows(.ddc) == true else {
                        throw ConfigurationSafetyBlockedError()
                    }
                    guard let configuration = currentConfigurations[targetID] else { continue }
                    try ddcController.write(
                        selector: configuration.selector,
                        command: control.ddcCommand,
                        value: value
                    )
                }
                DispatchQueue.main.async {
                    for targetID in targetDisplays {
                        self?.saveCachedValue(value, displayID: targetID, control: control)
                    }
                }
            } catch {
                self?.showError(title: "\(control.title)调节失败", error: error)
            }
        }
    }

    private static func validatedMaximum(_ reported: Int?, current: Int) -> Int {
        guard let reported, reported >= 10, reported >= current else {
            return max(100, current)
        }
        return reported
    }

    private func cacheKey(displayID: Int, control: DisplayControl) -> String {
        let selector = configurations[displayID]?.selector ?? "display\(displayID)"
        return "LastValue.device.\(selector).\(control.rawValue)"
    }

    private func saveCachedValue(_ value: Int, displayID: Int, control: DisplayControl) {
        UserDefaults.standard.set(value, forKey: cacheKey(displayID: displayID, control: control))
    }

    private func cachedValue(displayID: Int, control: DisplayControl) -> Int? {
        let key = cacheKey(displayID: displayID, control: control)
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.integer(forKey: key)
        }
        let legacyKey = "LastValue.display\(displayID).\(control.rawValue)"
        guard UserDefaults.standard.object(forKey: legacyKey) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: legacyKey)
    }

    private func restoreCachedValues() {
        for displayID in configurations.keys.sorted() {
            for control in DisplayControl.allCases {
                if let value = cachedValue(displayID: displayID, control: control) {
                    displayControls[displayID]?.update(control, value: value, estimated: true)
                }
            }
        }
    }

    private func applyFallbackValues(
        to displayID: Int,
        readings: [Int: [DisplayControl: (current: Int, maximum: Int)]]
    ) {
        for control in DisplayControl.allCases {
            if let cached = cachedValue(displayID: displayID, control: control) {
                displayControls[displayID]?.update(control, value: cached, estimated: true)
            } else if linkedItem.state == .on,
                      let linkedReading = readings
                        .filter({ $0.key != displayID })
                        .sorted(by: { $0.key < $1.key })
                        .compactMap({ $0.value[control] })
                        .first {
                displayControls[displayID]?.update(
                    control,
                    value: linkedReading.current,
                    maximum: linkedReading.maximum,
                    estimated: true
                )
            }
        }
    }

    private func finishSwitch(message: String, toMac: Bool, activeMenuItem: NSMenuItem? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let activeItem = activeMenuItem ?? (toMac ? self.switchToMacItem : self.switchItem)
            activeItem.title = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.switchToMacItem.title = "切换到 Mac"
                self.switchItem.title = "切换到 Windows"
                self.switchToMacItem.isEnabled = true
                self.switchItem.isEnabled = true
                if let menu = self.statusItem.menu { self.rebuildProfileSwitchItems(in: menu) }
            }
        }
    }

    private func configureUSBMonitor() {
        usbMonitor.stop()
        guard configurationSafetyGate.allows(.usb) else { return }
        let trigger = AppPreferences.usbAutomationEnabled ? AppPreferences.usbTriggerDevice : nil
        usbMonitor.start(triggerDevice: trigger)
    }

    private func configurePeerTransport() {
        peerTransport.stop()
        for (_, item) in pendingSchedulerItems {
            item.cancel()
        }
        pendingSchedulerItems.removeAll()

        let networkAllowed = configurationSafetyGate.allows(.network)
        let usbAllowed = configurationSafetyGate.allows(.usb)
        handoffStateMachine.configure(
            coordinationEnabled: networkAllowed && AppPreferences.peerCoordinationEnabled,
            usbAutomationEnabled: usbAllowed && AppPreferences.usbAutomationEnabled,
            usbPresent: false,
            peerReachable: false,
            peerLastSeenAtMs: nil,
            incomingEventID: nil,
            outgoingEventID: nil,
            newestIncomingRequestTimestamp: nil,
            seenMessages: [],
            pairingCode: AppPreferences.pairingCode
        )
        handoffStateMachine.setPairingCode(AppPreferences.pairingCode)
        handoffStateMachine.setUsbAutomationEnabled(
            usbAllowed && AppPreferences.usbAutomationEnabled
        )
        handoffStateMachine.setCoordinationEnabled(
            networkAllowed && AppPreferences.peerCoordinationEnabled
        )
        refreshPeerConnectionStatus()
        if networkAllowed && AppPreferences.peerCoordinationEnabled {
            peerTransport.start(port: AppPreferences.peerPort)
        }
    }

    private func startUSBLearning() {
        guard configurationSafetyGate.allows(.usb) else { return }
        usbMonitor.beginLearning { [weak self] devices in
            self?.settingsWindowController.presentDetectedUSBDevices(devices)
        }
    }

    private func handleUSBPresenceChange(_ isPresent: Bool) {
        guard configurationSafetyGate.allows(.usb) else { return }
        if AppPreferences.peerCoordinationEnabled {
            handoffStateMachine.handleUSBPresenceChanged(isPresent)
            return
        }

        guard AppPreferences.usbAutomationEnabled else { return }
        pendingUSBSwitch?.cancel()

        if isPresent {
            if !AppPreferences.usbSwitchDisplaysOnArrival {
                return
            }
            let workItem = DispatchWorkItem { [weak self] in
                self?.switchInactiveDisplaysToMac()
            }
            pendingUSBSwitch = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.usbMonitor.triggerPresence { [weak self] stillPresent in
                guard let self, !stillPresent else { return }
                self.switchInputs(toMac: false)
            }
        }
        pendingUSBSwitch = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func sendPeerMessage(
        type: PeerMessageType,
        eventID: String,
        wakeSucceeded: Bool? = nil
    ) {
        guard configurationSafetyGate.allows(.network) else { return }
        let message = makePeerMessage(type: type, eventID: eventID, wakeSucceeded: wakeSucceeded)
        peerTransport.send(message, host: AppPreferences.peerHost, port: AppPreferences.peerPort)
    }

    private func makePeerMessage(
        type: PeerMessageType,
        eventID: String,
        wakeSucceeded: Bool? = nil
    ) -> PeerMessage {
        PeerMessage(
            type: type,
            eventID: eventID,
            source: "mac",
            target: "windows",
            pairingCode: AppPreferences.pairingCode,
            wakeSucceeded: wakeSucceeded
        )
    }

    private func sendPeerMessageRepeated(
        type: PeerMessageType,
        eventID: String,
        wakeSucceeded: Bool? = nil
    ) {
        for attempt in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(attempt) * 0.12)) { [weak self] in
                self?.sendPeerMessage(type: type, eventID: eventID, wakeSucceeded: wakeSucceeded)
            }
        }
    }

    private func wakeMacDisplay() -> Bool {
        guard configurationSafetyGate.allows(.wake) else { return false }
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity(
            "DisplaySwitcher handover" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
        return result == kIOReturnSuccess
    }

    private func switchInactiveDisplaysToMac() {
        guard configurationSafetyGate.allows(.ddc) else { return }
        let activeUUIDs = Set(NSScreen.screens.compactMap { screen -> String? in
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))?.takeRetainedValue()
            else {
                return nil
            }
            return (CFUUIDCreateString(nil, uuid) as String).uppercased()
        })

        let inactiveDisplayIDs = configurations.keys.sorted().filter { displayID in
            guard let selector = configurations[displayID]?.selector.uppercased(), selector.contains("-") else {
                return false
            }
            return !activeUUIDs.contains(selector)
        }

        switchInputs(toMac: true, displayIDs: inactiveDisplayIDs)
    }

    private func showError(title: String, error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func showSettings() {
        settingsWindowHasBeenShown = true
        settingsWindowController.show()
        if case .requiresUserReview(let error) = configurationSafetyGate.state {
            settingsWindowController.presentConfigurationSafetyWarning(error)
        }
        let connected = handoffStateMachine.snapshot().peerReachable
        let configurationBlocked = configurationSafetyGate.state != .ready
        settingsWindowController.updatePeerConnectionStatus(
            configurationBlocked
                ? "配置安全模式：网络交接已停用"
                : (AppPreferences.peerCoordinationEnabled
                    ? (connected ? "已连接到 Windows" : "等待 Windows 心跳…")
                    : "协同未启用"),
            connected: !configurationBlocked && connected
        )
    }

    private func reloadSettings() {
        let result = AppPreferences.loadDisplayConfigurations()
        configurationSafetyGate.apply(result)
        let values = result.configurations
        configurations = Dictionary(uniqueKeysWithValues: values.map { ($0.index, $0) })
        ddcController.updateConfigurations(values)
        rebuildDisplayMenuItems()
        if let menu = statusItem.menu { rebuildProfileSwitchItems(in: menu) }
        linkedItem.state = AppPreferences.linkedDisplays ? .on : .off
        configureUSBMonitor()
        configurePeerTransport()
        updateConfigurationSafetyUI()
        lastRefresh = .distantPast
        restoreCachedValues()
        refreshValues(force: true)
    }

    private func rebuildDisplayMenuItems() {
        guard let menu = statusItem.menu else { return }

        for item in displayMenuItems.values {
            menu.removeItem(item)
        }
        displayMenuItems.removeAll()
        displayControls.removeAll()

        guard var insertionIndex = menu.items.firstIndex(of: linkedItem) else { return }
        for configuration in configurations.values.sorted(by: { $0.index < $1.index }) {
            let displayID = configuration.index
            let controls = DisplayControls(displayID: displayID) { [weak self] id, control, value in
                self?.setControl(control, value: value, fromDisplay: id)
            }
            let displayItem = NSMenuItem(title: configuration.name, action: nil, keyEquivalent: "")
            displayItem.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
            displayItem.submenu = controls.menu
            displayControls[displayID] = controls
            displayMenuItems[displayID] = displayItem
            menu.insertItem(displayItem, at: insertionIndex)
            insertionIndex += 1
        }
        linkedItem.isEnabled = configurations.count > 1
    }

    private func rebuildProfileSwitchItems(in menu: NSMenu) {
        for item in profileSwitchItems { menu.removeItem(item) }
        profileSwitchItems.removeAll()
        let profiles = AppPreferences.localConfiguration.collaborationProfiles.filter(\.coordinationEnabled)
        for (offset, profile) in profiles.enumerated() {
            let item = NSMenuItem(title: "切换到 \(profile.name)", action: #selector(switchToProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            item.image = NSImage(systemSymbolName: "arrow.right.to.line", accessibilityDescription: nil)
            item.isEnabled = configurationSafetyGate.state == .ready
            menu.insertItem(item, at: offset)
            profileSwitchItems.append(item)
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseSingleInstanceLock()
    }

    func currentTimeMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    func schedule(_ key: String, after delayMs: Int64, _ action: @escaping () -> Void) {
        pendingSchedulerItems[key]?.cancel()
        let workItem = DispatchWorkItem(block: action)
        pendingSchedulerItems[key] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delayMs) / 1000, execute: workItem)
    }

    func cancel(_ key: String) {
        pendingSchedulerItems[key]?.cancel()
        pendingSchedulerItems.removeValue(forKey: key)
    }

    func nextEventID() -> String {
        UUID().uuidString
    }

    func sendMessage(type: PeerMessageType, eventID: String, wakeSucceeded: Bool?) {
        guard configurationSafetyGate.allows(.network) else { return }
        sendPeerMessage(type: type, eventID: eventID, wakeSucceeded: wakeSucceeded)
    }

    func sendBurst(type: PeerMessageType, count: Int, eventID: String, wakeSucceeded: Bool?) {
        guard configurationSafetyGate.allows(.network) else { return }
        for attempt in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(attempt) * 0.12)) { [weak self] in
                self?.sendPeerMessage(type: type, eventID: eventID, wakeSucceeded: wakeSucceeded)
            }
        }
    }

    func requestWake(eventID: String) {
        guard configurationSafetyGate.allows(.wake) else { return }
        let wakeSucceeded = wakeMacDisplay()
        handoffStateMachine.handleWakeCompleted(eventID: eventID, success: wakeSucceeded)
    }

    func requestSwitch(eventID: String) {
        guard configurationSafetyGate.allows(.ddc) else { return }
        switchInputs(toMac: false) { [weak self] success in
            self?.handoffStateMachine.handleSwitchCompleted(eventID: eventID, success: success)
        }
    }

    func updatePeerReachable(_ reachable: Bool) {
        refreshPeerConnectionStatus()
    }

    private func refreshPeerConnectionStatus() {
        guard settingsWindowHasBeenShown else {
            return
        }
        let snapshot = handoffStateMachine.snapshot()
        let configurationBlocked = configurationSafetyGate.state != .ready
        settingsWindowController.updatePeerConnectionStatus(
            configurationBlocked
                ? "配置安全模式：网络交接已停用"
                : (AppPreferences.peerCoordinationEnabled
                    ? (snapshot.peerReachable ? "已连接到 Windows" : "等待 Windows 心跳…")
                    : "协同未启用"),
            connected: !configurationBlocked && snapshot.peerReachable
        )
    }

    private func enterConfigurationSafetyState(_ error: DisplayConfigurationStoreError) {
        configurationSafetyGate.requireUserReview(error)
        pendingUSBSwitch?.cancel()
        pendingUSBSwitch = nil
        usbMonitor.stop()
        peerTransport.stop()
        for (_, item) in pendingSchedulerItems {
            item.cancel()
        }
        pendingSchedulerItems.removeAll()
        handoffStateMachine.configure(
            coordinationEnabled: false,
            usbAutomationEnabled: false,
            usbPresent: false,
            peerReachable: false,
            peerLastSeenAtMs: nil,
            incomingEventID: nil,
            outgoingEventID: nil,
            newestIncomingRequestTimestamp: nil,
            seenMessages: [],
            pairingCode: AppPreferences.pairingCode
        )
        updateConfigurationSafetyUI()
        refreshPeerConnectionStatus()
    }

    private func updateConfigurationSafetyUI() {
        let enabled = configurationSafetyGate.state == .ready
        switchToMacItem.isEnabled = enabled
        switchItem.isEnabled = enabled
        profileSwitchItems.forEach { $0.isEnabled = enabled }
        detectItem.isEnabled = enabled
    }

    private func acquireSingleInstanceLock() -> Bool {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("local.maizi.DisplaySwitcher.instance.lock")
        let fileDescriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { return false }
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fileDescriptor)
            return false
        }
        instanceLockFD = fileDescriptor
        return true
    }

    private func hasAnotherRunningInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != currentPID && !$0.isTerminated }
    }

    private func releaseSingleInstanceLock() {
        guard instanceLockFD >= 0 else { return }
        flock(instanceLockFD, LOCK_UN)
        Darwin.close(instanceLockFD)
        instanceLockFD = -1
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
