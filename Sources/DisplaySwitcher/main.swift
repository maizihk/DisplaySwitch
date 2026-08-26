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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var instanceLockFD: Int32 = -1
    private var ownsPrimaryInstance = false
    private let workerQueue = DispatchQueue(label: "DisplaySwitcher.m1ddc")
    private let usbMonitor = USBMonitor()
    private let peerTransport = PeerTransport()
    private var pendingUSBSwitch: DispatchWorkItem?
    private var pendingPeerTimeout: DispatchWorkItem?
    private var pendingOutgoingEventID: String?
    private var pendingIncomingEventID: String?
    private var lastIncomingRequestTimestamp: TimeInterval = 0
    private var displayControls: [Int: DisplayControls] = [:]
    private var displayMenuItems: [Int: NSMenuItem] = [:]
    private var configurations: [Int: DisplayConfiguration] = [:]
    private var isRefreshing = false
    private var lastRefresh = Date.distantPast

    private lazy var settingsWindowController: SettingsWindowController = {
        let controller = SettingsWindowController()
        controller.onSave = { [weak self] in
            self?.reloadSettings()
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
        let item = NSMenuItem(title: "联动两台显示器", action: #selector(toggleLinkedControls), keyEquivalent: "")
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
        for index in 1...2 {
            configurations[index] = DisplayConfiguration.load(index: index)
        }

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "显示器控制")
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(switchToMacItem)
        menu.addItem(switchItem)
        menu.addItem(.separator())

        for displayID in 1...2 {
            let controls = DisplayControls(displayID: displayID) { [weak self] id, control, value in
                self?.setControl(control, value: value, fromDisplay: id)
            }
            displayControls[displayID] = controls

            let displayName = configurations[displayID]?.name ?? "显示器 \(displayID)"
            let displayItem = NSMenuItem(title: displayName, action: nil, keyEquivalent: "")
            displayItem.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
            displayItem.submenu = controls.menu
            displayMenuItems[displayID] = displayItem
            menu.addItem(displayItem)
        }

        restoreCachedValues()

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

        usbMonitor.onPresenceChanged = { [weak self] isPresent in
            self?.handleUSBPresenceChange(isPresent)
        }
        peerTransport.onMessage = { [weak self] message in
            self?.handlePeerMessage(message)
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

    @objc private func switchToMac() {
        switchInputs(toMac: true)
    }

    private func switchInputs(
        toMac: Bool,
        displayIDs: [Int] = [1, 2],
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !displayIDs.isEmpty else { return }
        let activeItem = toMac ? switchToMacItem : switchItem
        activeItem.title = "正在切换…"
        switchToMacItem.isEnabled = false
        switchItem.isEnabled = false
        let currentConfigurations = configurations

        workerQueue.async { [weak self] in
            var firstError: Error?
            for displayID in displayIDs {
                guard let configuration = currentConfigurations[displayID] else { continue }
                var succeeded = false
                var displayError: Error?
                for attempt in 0..<2 {
                    let arguments = [
                        "display", configuration.selector,
                        "set", "input", "\(toMac ? configuration.macInput : configuration.windowsInput)"
                    ]
                    do {
                        _ = try Self.runM1DDC(arguments: arguments)
                        succeeded = true
                        break
                    } catch {
                        displayError = error
                        if attempt == 0 { Thread.sleep(forTimeInterval: 0.3) }
                    }
                }
                if !succeeded, firstError == nil { firstError = displayError }
            }

            if let firstError {
                self?.finishSwitch(message: "部分切换失败", toMac: toMac)
                self?.showError(title: "显示器切换失败", error: firstError)
                DispatchQueue.main.async { completion?(false) }
            } else {
                self?.finishSwitch(message: toMac ? "已切换到 Mac" : "已切换到 Windows", toMac: toMac)
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
        detectItem.isEnabled = false
        detectItem.title = "正在检测…"

        workerQueue.async { [weak self] in
            do {
                let output = try Self.runM1DDC(arguments: ["display", "list", "detailed"])
                let detectedDisplays = DetectedDisplay.parseList(output).filter { (1...2).contains($0.index) }

                guard !detectedDisplays.isEmpty else {
                    throw DDCError.detectionFailed
                }

                DispatchQueue.main.async {
                    guard let self else { return }
                    for detected in detectedDisplays {
                        let configuration = DisplayConfiguration.load(
                            index: detected.index,
                            detectedName: detected.name,
                            detectedSelector: detected.systemUUID
                        )
                        configuration.save()
                        self.configurations[detected.index] = configuration
                        self.displayMenuItems[detected.index]?.title = configuration.name
                    }
                    self.finishDetection()
                    self.refreshValues(force: true)
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
        guard !isRefreshing else { return }
        guard force || Date().timeIntervalSince(lastRefresh) > 3 else { return }
        isRefreshing = true
        let currentConfigurations = configurations

        workerQueue.async { [weak self] in
            var readings: [Int: [DisplayControl: (current: Int, maximum: Int)]] = [:]

            for displayID in 1...2 {
                guard
                    let configuration = currentConfigurations[displayID],
                    configuration.readEnabled
                else {
                    continue
                }

                for control in DisplayControl.allCases {
                    let prefix = ["display", configuration.selector]
                    guard let current = Self.readValue(
                        arguments: prefix + ["get", control.rawValue]
                    ) else {
                        continue
                    }

                    let reportedMaximum = Self.readValue(
                        arguments: prefix + ["max", control.rawValue]
                    )
                    let maximum = Self.validatedMaximum(reportedMaximum, current: current)
                    readings[displayID, default: [:]][control] = (current, maximum)
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                for displayID in 1...2 {
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
        let targetDisplays = linkedItem.state == .on ? [1, 2] : [displayID]
        let currentConfigurations = configurations

        for targetID in targetDisplays {
            displayControls[targetID]?.update(control, value: value)
        }

        workerQueue.async { [weak self] in
            do {
                for targetID in targetDisplays {
                    guard let configuration = currentConfigurations[targetID] else { continue }
                    _ = try Self.runM1DDC(arguments: [
                        "display", configuration.selector, "set", control.rawValue, "\(value)"
                    ])
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

    private static func runM1DDC(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/m1ddc")
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw DDCError.commandFailed(
                arguments: arguments,
                status: process.terminationStatus,
                detail: text.isEmpty ? nil : text
            )
        }
        return text
    }

    private static func readValue(arguments: [String]) -> Int? {
        for attempt in 0..<2 {
            if
                let output = try? runM1DDC(arguments: arguments),
                let value = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)),
                value >= 0
            {
                return value
            }

            if attempt == 0 {
                Thread.sleep(forTimeInterval: 0.08)
            }
        }
        return nil
    }

    private static func validatedMaximum(_ reported: Int?, current: Int) -> Int {
        guard let reported, reported >= 10, reported >= current else {
            return max(100, current)
        }
        return reported
    }

    private func cacheKey(displayID: Int, control: DisplayControl) -> String {
        "LastValue.display\(displayID).\(control.rawValue)"
    }

    private func saveCachedValue(_ value: Int, displayID: Int, control: DisplayControl) {
        UserDefaults.standard.set(value, forKey: cacheKey(displayID: displayID, control: control))
    }

    private func cachedValue(displayID: Int, control: DisplayControl) -> Int? {
        let key = cacheKey(displayID: displayID, control: control)
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: key)
    }

    private func restoreCachedValues() {
        for displayID in 1...2 {
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
            } else if
                linkedItem.state == .on,
                displayID == 2,
                let displayOneReading = readings[1]?[control]
            {
                displayControls[displayID]?.update(
                    control,
                    value: displayOneReading.current,
                    maximum: displayOneReading.maximum,
                    estimated: true
                )
            }
        }
    }

    private func finishSwitch(message: String, toMac: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let activeItem = toMac ? self.switchToMacItem : self.switchItem
            activeItem.title = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.switchToMacItem.title = "切换到 Mac"
                self.switchItem.title = "切换到 Windows"
                self.switchToMacItem.isEnabled = true
                self.switchItem.isEnabled = true
            }
        }
    }

    private func configureUSBMonitor() {
        let trigger = AppPreferences.usbAutomationEnabled ? AppPreferences.usbTriggerDevice : nil
        usbMonitor.start(triggerDevice: trigger)
    }

    private func configurePeerTransport() {
        peerTransport.stop()
        if AppPreferences.peerCoordinationEnabled {
            peerTransport.start(port: AppPreferences.peerPort)
        }
    }

    private func startUSBLearning() {
        usbMonitor.beginLearning { [weak self] devices in
            self?.settingsWindowController.presentDetectedUSBDevices(devices)
        }
    }

    private func handleUSBPresenceChange(_ isPresent: Bool) {
        guard AppPreferences.usbAutomationEnabled else { return }
        pendingUSBSwitch?.cancel()

        if isPresent {
            cancelOutgoingHandover()
            if AppPreferences.peerCoordinationEnabled {
                let wakeSucceeded = wakeMacDisplay()
                sendPeerMessage(type: .usbPresent, eventID: UUID().uuidString, wakeSucceeded: wakeSucceeded)
                if let pendingIncomingEventID {
                    sendPeerMessage(type: .usbReady, eventID: pendingIncomingEventID, wakeSucceeded: wakeSucceeded)
                }
            } else if AppPreferences.usbSwitchDisplaysOnArrival {
                let workItem = DispatchWorkItem { [weak self] in self?.switchInactiveDisplaysToMac() }
                pendingUSBSwitch = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
            }
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.usbMonitor.triggerPresence { [weak self] stillPresent in
                guard let self, !stillPresent else { return }
                if AppPreferences.peerCoordinationEnabled {
                    self.beginOutgoingHandover()
                } else {
                    self.switchInputs(toMac: false)
                }
            }
        }
        pendingUSBSwitch = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    private func beginOutgoingHandover() {
        cancelOutgoingHandover()
        let eventID = UUID().uuidString
        pendingOutgoingEventID = eventID

        for attempt in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(attempt) * 0.45)) { [weak self] in
                guard self?.pendingOutgoingEventID == eventID else { return }
                self?.sendPeerMessage(type: .handoverRequest, eventID: eventID)
            }
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard self?.pendingOutgoingEventID == eventID else { return }
            self?.completeOutgoingHandover(eventID: eventID)
        }
        pendingPeerTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: timeout)
    }

    private func completeOutgoingHandover(eventID: String) {
        guard pendingOutgoingEventID == eventID else { return }
        pendingOutgoingEventID = nil
        pendingPeerTimeout?.cancel()
        pendingPeerTimeout = nil

        switchInputs(toMac: false) { [weak self] succeeded in
            self?.sendPeerMessage(type: .committed, eventID: eventID, wakeSucceeded: succeeded)
        }
    }

    private func cancelOutgoingHandover() {
        pendingOutgoingEventID = nil
        pendingPeerTimeout?.cancel()
        pendingPeerTimeout = nil
    }

    private func handlePeerMessage(_ message: PeerMessage) {
        guard
            AppPreferences.peerCoordinationEnabled,
            message.version == 1,
            message.pairingCode == AppPreferences.pairingCode,
            message.source == "windows",
            message.target == "mac",
            abs(Date().timeIntervalSince1970 - message.timestamp) <= 10
        else {
            return
        }

        switch message.type {
        case .handoverRequest:
            guard message.timestamp >= lastIncomingRequestTimestamp else { return }
            lastIncomingRequestTimestamp = message.timestamp
            pendingIncomingEventID = message.eventID
            let wakeSucceeded = wakeMacDisplay()
            usbMonitor.triggerPresence { [weak self] isPresent in
                guard isPresent else { return }
                self?.sendPeerMessage(type: .usbReady, eventID: message.eventID, wakeSucceeded: wakeSucceeded)
            }
        case .usbPresent:
            if let eventID = pendingOutgoingEventID {
                completeOutgoingHandover(eventID: eventID)
            }
        case .usbReady:
            if pendingOutgoingEventID == message.eventID {
                completeOutgoingHandover(eventID: message.eventID)
            }
        case .committed:
            if pendingIncomingEventID == message.eventID {
                pendingIncomingEventID = nil
            }
        }
    }

    private func sendPeerMessage(
        type: PeerMessageType,
        eventID: String,
        wakeSucceeded: Bool? = nil
    ) {
        let message = PeerMessage(
            type: type,
            eventID: eventID,
            source: "mac",
            target: "windows",
            pairingCode: AppPreferences.pairingCode,
            wakeSucceeded: wakeSucceeded
        )
        peerTransport.send(message, host: AppPreferences.peerHost, port: AppPreferences.peerPort)
    }

    private func wakeMacDisplay() -> Bool {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity(
            "DisplaySwitcher handover" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
        return result == kIOReturnSuccess
    }

    private func switchInactiveDisplaysToMac() {
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
        settingsWindowController.show()
    }

    private func reloadSettings() {
        for index in 1...2 {
            let configuration = DisplayConfiguration.load(index: index)
            configurations[index] = configuration
            displayMenuItems[index]?.title = configuration.name
        }
        linkedItem.state = AppPreferences.linkedDisplays ? .on : .off
        configureUSBMonitor()
        configurePeerTransport()
        lastRefresh = .distantPast
        restoreCachedValues()
        refreshValues(force: true)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseSingleInstanceLock()
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

private enum DDCError: LocalizedError {
    case commandFailed(arguments: [String], status: Int32, detail: String?)
    case detectionFailed

    var errorDescription: String? {
        switch self {
        case let .commandFailed(arguments, status, detail):
            let command = (["m1ddc"] + arguments).joined(separator: " ")
            let suffix = detail.map { "\n\n\($0)" } ?? ""
            return "命令执行失败（退出码 \(status)）：\n\(command)\(suffix)"
        case .detectionFailed:
            return "m1ddc 没有返回可解析的外接显示器信息。"
        }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
