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

    init(displayID: Int, enabledControls: Set<DisplayControl>,
         onChange: @escaping (Int, DisplayControl, Int) -> Void) {
        menu.autoenablesItems = false

        for control in DisplayControl.allCases where enabledControls.contains(control) {
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

private final class PendingPeerCapabilityInspection {
    let id: String
    let profile: CollaborationProfile
    let v2EventID: String
    var v1EventID: String?
    let completion: (PeerCapabilityInspectionResult) -> Void

    init(id: String, profile: CollaborationProfile, v2EventID: String,
         completion: @escaping (PeerCapabilityInspectionResult) -> Void) {
        self.id = id
        self.profile = profile
        self.v2EventID = v2EventID
        self.completion = completion
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, HandoffClock, HandoffScheduler, HandoffEventIDSource, HandoffActionSink, V2HandoffActionSink {
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var instanceLockFD: Int32 = -1
    private var ownsPrimaryInstance = false
    private let workerQueue = DispatchQueue(label: "DisplaySwitcher.ddc")
    private let ddcController = DDCController()
    private let usbMonitor = USBMonitor()
    private let peerTransport = PeerTransport()
    private let configurationSafetyGate = ConfigurationSafetyGate()
    private let usbLearningSafetyGate = USBLearningSafetyGate()
    private var pendingUSBSwitch: DispatchWorkItem?
    private var pendingSchedulerItems: [String: DispatchWorkItem] = [:]
    private lazy var handoffStateMachine = HandoffStateMachine(
        localPlatform: .mac,
        sink: self,
        clock: self,
        scheduler: self,
        eventIDSource: self
    )
    private lazy var handoffV2StateMachine = HandoffV2StateMachine(
        localEndpointID: AppPreferences.localConfiguration.localEndpointID,
        sink: self,
        scheduler: self,
        eventIDSource: self
    )
    private var v2RoutingTable = V2EndpointRoutingTable(routesByEndpointID: [:], rejectedProfileIDs: [])
    private var v2ReplayCache = V2NonceReplayCache()
    private var v2ReachableEndpoints = Set<String>()
    private var v2LastSeenAtMs: [String: Int64] = [:]
    private var v2OutgoingMessages: [String: Data] = [:]
    private var v2DatagramReplies: [String: PeerTransport.DataReply] = [:]
    private var pendingPeerInspections: [String: PendingPeerCapabilityInspection] = [:]
    private var inspectionIDByEventID: [String: String] = [:]
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
        controller.onLearnUSB = { [weak self] profileID in
            self?.startUSBLearning(profileID: profileID)
        }
        controller.onCancelUSBLearning = { [weak self] in
            self?.cancelUSBLearning()
        }
        controller.onUSBLearningFinished = { [weak self] in
            self?.finishUSBLearning()
        }
        controller.onInspectPeer = { [weak self] profile, completion in
            self?.beginPeerCapabilityInspection(profile: profile, completion: completion)
        }
        return controller
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
        refreshDDCOperationAccess()
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
        usbMonitor.onInitialPresenceObserved = { [weak self] isPresent in
            self?.recordInitialInputPresence(isPresent)
        }
        peerTransport.onDatagram = { [weak self] data, reply in
            self?.handlePeerDatagram(data, reply: reply)
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

    @objc private func switchToProfile(_ sender: NSMenuItem) {
        guard let profileID = sender.representedObject as? String else { return }
        let document = AppPreferences.localConfiguration
        guard let profile = document.collaborationProfiles.first(where: { $0.id == profileID }) else { return }
        if profile.peerProtocolVersion == 2,
           let endpointID = profile.peerEndpointID.flatMap(V2Crypto.normalizedUUID),
           v2RoutingTable.route(for: endpointID)?.profileID == profile.id {
            handoffV2StateMachine.handleManualSelect(endpointID: endpointID, eventID: nextEventID())
            return
        }
        let mappings = Dictionary(uniqueKeysWithValues: profile.displayInputs.map { ($0.displayID.lowercased(), $0.peerInput) })
        let selected = Dictionary(uniqueKeysWithValues: configurations.map { index, configuration in
            var value = configuration
            if let id = configuration.id { value.windowsInput = mappings[id.lowercased()] } else { value.windowsInput = nil }
            return (index, value)
        })
        switchInputs(toMac: false, overrideConfigurations: selected, activeMenuItem: sender)
    }

    private func switchInputs(
        toMac: Bool,
        displayIDs: [Int]? = nil,
        completion: ((Bool) -> Void)? = nil,
        overrideConfigurations: [Int: DisplayConfiguration]? = nil,
        activeMenuItem: NSMenuItem? = nil
    ) {
        guard configurationSafetyGate.allows(.ddc), usbLearningSafetyGate.allows(.ddc) else {
            completion?(false)
            return
        }
        let targetDisplayIDs = displayIDs ?? configurations.keys.sorted()
        guard !targetDisplayIDs.isEmpty else {
            completion?(false)
            return
        }
        activeMenuItem?.title = "正在切换…"
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
                    guard self?.configurationSafetyGate.allows(.ddc) == true,
                          self?.usbLearningSafetyGate.allows(.ddc) == true else {
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
                                stableID: configuration.id ?? configuration.selector,
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
                self?.finishSwitch(message: "部分切换失败", activeMenuItem: activeMenuItem)
                self?.showError(title: "显示器切换失败", error: firstError)
                DispatchQueue.main.async { completion?(false) }
            } else {
                self?.finishSwitch(message: "切换完成", activeMenuItem: activeMenuItem)
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
        guard configurationSafetyGate.allows(.ddc), usbLearningSafetyGate.allows(.ddc) else {
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
                    guard self.configurationSafetyGate.allows(.ddc), self.usbLearningSafetyGate.allows(.ddc) else {
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
        guard configurationSafetyGate.allows(.ddc), usbLearningSafetyGate.allows(.ddc) else { return }
        guard !isRefreshing else { return }
        guard force || Date().timeIntervalSince(lastRefresh) > 3 else { return }
        isRefreshing = true
        let currentConfigurations = configurations
        let ddcController = ddcController
        let localDocument = AppPreferences.localConfiguration
        let targets = currentConfigurations.values.map {
            Self.ddcTarget(for: $0, document: localDocument)
        }

        workerQueue.async { [weak self] in
            guard self?.configurationSafetyGate.allows(.ddc) == true,
                  self?.usbLearningSafetyGate.allows(.ddc) == true else {
                DispatchQueue.main.async { self?.isRefreshing = false }
                return
            }
            let resolved = ddcController.read(targets: targets)
            var readings: [Int: [DisplayControl: (current: Int, maximum: Int)]] = [:]
            var estimates: [Int: Set<DisplayControl>] = [:]
            for (displayID, configuration) in currentConfigurations {
                let stableID = configuration.id ?? configuration.selector
                for control in DisplayControl.allCases {
                    guard let value = resolved[stableID]?[control.ddcCommand] else { continue }
                    let maximum = Self.validatedMaximum(value.reading.maximum, current: value.reading.current)
                    readings[displayID, default: [:]][control] = (value.reading.current, maximum)
                    if value.estimated { estimates[displayID, default: []].insert(control) }
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                guard self.configurationSafetyGate.allows(.ddc), self.usbLearningSafetyGate.allows(.ddc) else {
                    self.isRefreshing = false
                    return
                }
                for displayID in currentConfigurations.keys.sorted() {
                    let displayReadings = readings[displayID] ?? [:]
                    let readEnabled = currentConfigurations[displayID]?.readEnabled ?? true

                    if !readEnabled || displayReadings.isEmpty {
                        self.applyFallbackValues(to: displayID, readings: readings)
                        continue
                    }

                    for (control, reading) in displayReadings {
                        self.displayControls[displayID]?.update(
                            control,
                            value: reading.current,
                            maximum: reading.maximum,
                            estimated: estimates[displayID]?.contains(control) == true
                        )
                    }
                }
                self.lastRefresh = Date()
                self.isRefreshing = false
            }
        }
    }

    private func setControl(_ control: DisplayControl, value: Int, fromDisplay displayID: Int) {
        guard configurationSafetyGate.allows(.ddc), usbLearningSafetyGate.allows(.ddc) else { return }
        let targetDisplays = linkedItem.state == .on ? configurations.keys.sorted() : [displayID]
        let currentConfigurations = configurations
        let ddcController = ddcController
        let document = AppPreferences.localConfiguration
        let targets = targetDisplays.compactMap { currentConfigurations[$0] }
            .map { Self.ddcTarget(for: $0, document: document) }
            .filter { $0.enabledCommands.contains(control.ddcCommand) }

        let enabledStableIDs = Set(targets.map(\.stableID))
        for targetID in targetDisplays {
            guard let configuration = currentConfigurations[targetID],
                  enabledStableIDs.contains(configuration.id ?? configuration.selector) else { continue }
            displayControls[targetID]?.update(control, value: value)
        }

        workerQueue.async { [weak self] in
            guard self?.configurationSafetyGate.allows(.ddc) == true,
                  self?.usbLearningSafetyGate.allows(.ddc) == true else { return }
            let failures = ddcController.write(command: control.ddcCommand, value: value, targets: targets)
            if let error = failures.values.first {
                self?.showError(title: "\(control.title)调节部分失败", error: error)
            }
        }
    }

    private static func validatedMaximum(_ reported: Int?, current: Int) -> Int {
        guard let reported, reported >= 10, reported >= current else {
            return max(100, current)
        }
        return reported
    }

    private func cachedValue(displayID: Int, control: DisplayControl) -> Int? {
        guard let configuration = configurations[displayID] else { return nil }
        let stableID = configuration.id ?? configuration.selector
        if let value = ddcController.cachedValue(stableID: stableID, command: control.ddcCommand) {
            return value
        }
        let selectorKey = "LastValue.device.\(configuration.selector).\(control.rawValue)"
        if UserDefaults.standard.object(forKey: selectorKey) != nil {
            return UserDefaults.standard.integer(forKey: selectorKey)
        }
        let legacyKey = "LastValue.display\(displayID).\(control.rawValue)"
        guard UserDefaults.standard.object(forKey: legacyKey) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: legacyKey)
    }

    private static func ddcTarget(
        for configuration: DisplayConfiguration,
        document: DisplayConfigurationStoreV3Document
    ) -> DDCDisplayTarget {
        let stableID = configuration.id ?? configuration.selector
        let stored = document.displays.first { $0.id.caseInsensitiveCompare(stableID) == .orderedSame }
        var enabled: Set<DDCCommand> = []
        if stored?.brightnessEnabled ?? true { enabled.insert(.luminance) }
        if stored?.contrastEnabled ?? true { enabled.insert(.contrast) }
        if stored?.volumeEnabled ?? true { enabled.insert(.volume) }
        return DDCDisplayTarget(stableID: stableID, selector: configuration.selector,
                                readEnabled: configuration.readEnabled, enabledCommands: enabled)
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

    private func finishSwitch(message: String, activeMenuItem: NSMenuItem? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            activeMenuItem?.title = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let menu = self.statusItem.menu { self.rebuildProfileSwitchItems(in: menu) }
            }
        }
    }

    private func configureUSBMonitor() {
        usbMonitor.stop()
        guard configurationSafetyGate.allows(.usb), usbLearningSafetyGate.allows(.usb) else { return }
        let document = AppPreferences.localConfiguration
        let routingTable = V2EndpointRoutingTable.build(from: document)
        let v2Profiles = routingTable.routesByEndpointID.values.compactMap { route in
            document.collaborationProfiles.first { $0.id == route.profileID }
        }
        let v2USBReferences = Set(v2Profiles.flatMap { profile in
            profile.triggerDevices.compactMap { trigger in
                trigger.kind.caseInsensitiveCompare("usb") == .orderedSame ? trigger.localReference : nil
            }
        })
        if AppPreferences.usbAutomationEnabled, v2USBReferences.count == 1,
           let value = v2USBReferences.first, let reference = USBDeviceReference(localReference: value) {
            usbMonitor.start(triggerReference: reference)
            return
        }
        guard !DisplayConfigurationStore.legacyV1RuntimeSelection(in: document).blocksAutomaticSideEffects else { return }
        let trigger = AppPreferences.usbAutomationEnabled ? AppPreferences.usbTriggerDevice : nil
        usbMonitor.start(triggerDevice: trigger)
    }

    private func configurePeerTransport() {
        peerTransport.stop()
        for (_, item) in pendingSchedulerItems {
            item.cancel()
        }
        pendingSchedulerItems.removeAll()

        let interruptedInspections = Array(pendingPeerInspections.keys)
        for inspectionID in interruptedInspections {
            completePeerCapabilityInspection(inspectionID, result: .noResponse)
        }

        let networkAllowed = configurationSafetyGate.allows(.network)
        let usbAllowed = configurationSafetyGate.allows(.usb)
        let document = AppPreferences.localConfiguration
        let selection = DisplayConfigurationStore.legacyV1RuntimeSelection(in: document)
        let profile = selection.profile
        let coordinationEnabled = networkAllowed && usbLearningSafetyGate.allows(.network) && profile != nil
        let pairingCode = profile?.pairingCode ?? ""
        handoffStateMachine.configure(
            coordinationEnabled: coordinationEnabled,
            usbAutomationEnabled: coordinationEnabled && usbAllowed && AppPreferences.usbAutomationEnabled,
            usbPresent: false,
            peerReachable: false,
            peerLastSeenAtMs: nil,
            incomingEventID: nil,
            outgoingEventID: nil,
            newestIncomingRequestTimestamp: nil,
            seenMessages: [],
            pairingCode: pairingCode
        )
        handoffStateMachine.setPairingCode(pairingCode)
        handoffStateMachine.setUsbAutomationEnabled(
            coordinationEnabled && usbAllowed && AppPreferences.usbAutomationEnabled
        )
        handoffStateMachine.setCoordinationEnabled(coordinationEnabled)
        v2RoutingTable = V2EndpointRoutingTable.build(from: document)
        let configuredEndpointIDs = Set(v2RoutingTable.routesByEndpointID.keys)
        v2ReachableEndpoints.formIntersection(configuredEndpointIDs)
        v2LastSeenAtMs = v2LastSeenAtMs.filter { configuredEndpointIDs.contains($0.key) }
        v2ReplayCache.reset()
        v2OutgoingMessages.removeAll(keepingCapacity: true)
        v2DatagramReplies.removeAll(keepingCapacity: true)
        let v2Enabled = networkAllowed && usbLearningSafetyGate.allows(.network)
            && !v2RoutingTable.routesByEndpointID.isEmpty
        handoffV2StateMachine.configure(
            localEndpointID: document.localEndpointID,
            coordinationEnabled: v2Enabled,
            sourceInputPresent: false,
            targetInputPresent: false,
            enabledTargets: v2RoutingTable.routesByEndpointID.values.map {
                V2HandoffTarget(
                    endpointID: $0.endpointID,
                    capability: .v2,
                    reachable: v2ReachableEndpoints.contains($0.endpointID)
                )
            }
        )
        refreshPeerConnectionStatus()
        if coordinationEnabled || v2Enabled {
            peerTransport.start(port: v2Enabled ? document.listenPort : (profile?.peerPort ?? document.listenPort))
        }
        if v2Enabled { scheduleV2StatusProbes() }
    }

    private func startUSBLearning(profileID: String) {
        guard configurationSafetyGate.allows(.usb) else { return }
        usbLearningSafetyGate.begin()
        refreshDDCOperationAccess()
        pendingUSBSwitch?.cancel()
        pendingUSBSwitch = nil
        configurePeerTransport()
        usbMonitor.stop()
        usbMonitor.start(triggerDevice: nil)
        usbMonitor.beginLearning { [weak self] devices in
            guard let self else { return }
            _ = self.settingsWindowController.presentDetectedUSBDevices(devices, learningProfileID: profileID)
        }
    }

    private func cancelUSBLearning() {
        usbMonitor.cancelLearning()
        finishUSBLearning()
    }

    private func finishUSBLearning() {
        guard usbLearningSafetyGate.end() else { return }
        refreshDDCOperationAccess()
        configureUSBMonitor()
        configurePeerTransport()
    }

    private func handleUSBPresenceChange(_ isPresent: Bool) {
        guard configurationSafetyGate.allows(.usb), usbLearningSafetyGate.allows(.usb) else { return }
        let document = AppPreferences.localConfiguration
        if !v2RoutingTable.routesByEndpointID.isEmpty, AppPreferences.usbAutomationEnabled {
            handoffV2StateMachine.handleLocalInputPresenceChanged(isPresent)
            return
        }
        let selection = DisplayConfigurationStore.legacyV1RuntimeSelection(in: document)
        guard !selection.blocksAutomaticSideEffects else { return }
        if selection.allowsAutomaticCoordination {
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

    private func recordInitialInputPresence(_ isPresent: Bool) {
        guard configurationSafetyGate.allows(.usb), usbLearningSafetyGate.allows(.usb) else { return }
        if !v2RoutingTable.routesByEndpointID.isEmpty, AppPreferences.usbAutomationEnabled {
            handoffV2StateMachine.recordInitialLocalInputPresence(isPresent)
        } else {
            handoffStateMachine.recordInitialUSBPresence(isPresent)
        }
    }

    private func beginPeerCapabilityInspection(
        profile: CollaborationProfile,
        completion: @escaping (PeerCapabilityInspectionResult) -> Void
    ) {
        guard configurationSafetyGate.allows(.network), usbLearningSafetyGate.allows(.network),
              (try? V2Crypto.normalizedPairingCodeData(profile.pairingCode)) != nil else {
            completion(.authenticationFailed)
            return
        }
        let inspectionID = UUID().uuidString.lowercased()
        let eventID = nextEventID().lowercased()
        let pending = PendingPeerCapabilityInspection(
            id: inspectionID,
            profile: profile,
            v2EventID: eventID,
            completion: completion
        )
        pendingPeerInspections[inspectionID] = pending
        inspectionIDByEventID[eventID] = inspectionID
        peerTransport.start(port: AppPreferences.localConfiguration.listenPort)
        guard let data = makeV2StatusProbe(eventID: eventID, profile: profile) else {
            completePeerCapabilityInspection(inspectionID, result: .authenticationFailed)
            return
        }
        peerTransport.send(data, host: profile.peerHost, port: profile.peerPort)
        schedule("v2-inspection-\(inspectionID)", after: 1_000) { [weak self] in
            self?.beginV1InspectionFallback(inspectionID)
        }
    }

    private func makeV2StatusProbe(eventID: String, profile: CollaborationProfile) -> Data? {
        let localEndpointID = AppPreferences.localConfiguration.localEndpointID
        guard let nonce = try? V2Crypto.makeNonce(),
              let key = try? V2Crypto.deriveKey(
                pairingCode: profile.pairingCode,
                sourceEndpointID: localEndpointID
              ) else { return nil }
        var message = V2Message(
            type: .statusProbe,
            eventID: eventID,
            sourceEndpointID: localEndpointID,
            targetEndpointID: nil,
            sourcePlatform: .macos,
            timestamp: Int64(Date().timeIntervalSince1970),
            nonce: nonce
        )
        message.authTag = V2Crypto.authenticationTag(for: message, key: key)
        return try? JSONEncoder().encode(message)
    }

    private func beginV1InspectionFallback(_ inspectionID: String) {
        guard let pending = pendingPeerInspections[inspectionID] else { return }
        let eventID = nextEventID().lowercased()
        pending.v1EventID = eventID
        inspectionIDByEventID[eventID] = inspectionID
        let message = makePeerMessage(
            type: .statusProbe,
            eventID: eventID,
            pairingCode: pending.profile.pairingCode
        )
        peerTransport.send(message, host: pending.profile.peerHost, port: pending.profile.peerPort)
        schedule("v1-inspection-\(inspectionID)", after: 1_000) { [weak self] in
            self?.completePeerCapabilityInspection(inspectionID, result: .noResponse)
        }
    }

    private func completePeerCapabilityInspection(
        _ inspectionID: String,
        result: PeerCapabilityInspectionResult
    ) {
        guard let pending = pendingPeerInspections.removeValue(forKey: inspectionID) else { return }
        cancel("v2-inspection-\(inspectionID)")
        cancel("v1-inspection-\(inspectionID)")
        inspectionIDByEventID.removeValue(forKey: pending.v2EventID)
        if let v1EventID = pending.v1EventID { inspectionIDByEventID.removeValue(forKey: v1EventID) }
        pending.completion(result)
    }

    private func handlePendingV2Inspection(_ data: Data) -> Bool {
        guard let eventID = V2MessageEnvelope.eventID(in: data),
              let inspectionID = inspectionIDByEventID[eventID],
              let pending = pendingPeerInspections[inspectionID],
              eventID == pending.v2EventID,
              let sourceEndpointID = V2MessageEnvelope.sourceEndpointID(in: data),
              let key = try? V2Crypto.deriveKey(
                pairingCode: pending.profile.pairingCode,
                sourceEndpointID: sourceEndpointID
              ) else { return false }
        let validation = V2MessageValidator.validate(
            data: data,
            context: V2MessageValidationContext(
                now: Int64(Date().timeIntervalSince1970),
                localEndpointID: AppPreferences.localConfiguration.localEndpointID,
                knownSourceEndpointID: sourceEndpointID,
                authenticationKey: key
            )
        )
        if validation.reason == .authenticationFailed {
            completePeerCapabilityInspection(inspectionID, result: .authenticationFailed)
            return true
        }
        guard validation.accepted, validation.message?.type == .statusResponse else { return true }
        completePeerCapabilityInspection(inspectionID, result: .v2(endpointID: sourceEndpointID))
        return true
    }

    private func handlePendingV1Inspection(_ message: PeerMessage) -> Bool {
        let eventID = message.eventID.lowercased()
        guard let inspectionID = inspectionIDByEventID[eventID],
              let pending = pendingPeerInspections[inspectionID],
              pending.v1EventID == eventID else { return false }
        let valid = PeerMessageValidation.accepts(
            message,
            pairingCode: pending.profile.pairingCode,
            expectedSource: "windows",
            expectedTarget: "mac"
        )
        if valid, message.type == .statusResponse {
            completePeerCapabilityInspection(inspectionID, result: .v1Only)
        }
        return true
    }

    private func handlePeerDatagram(_ data: Data, reply: @escaping PeerTransport.DataReply) {
        guard configurationSafetyGate.allows(.network), usbLearningSafetyGate.allows(.network) else { return }
        switch PeerProtocolVersionDispatcher.version(in: data) {
        case .v1:
            guard let message = try? JSONDecoder().decode(PeerMessage.self, from: data) else { return }
            if handlePendingV1Inspection(message) { return }
            handoffV2StateMachine.handleV1Message()
            handoffStateMachine.handleIncomingMessage(message)
        case .v2:
            if handlePendingV2Inspection(data) { return }
            handleV2Datagram(data, reply: reply)
        case .unsupported, nil:
            return
        }
    }

    private func handleV2Datagram(_ data: Data, reply: @escaping PeerTransport.DataReply) {
        let document = AppPreferences.localConfiguration
        guard let sourceEndpointID = V2MessageEnvelope.sourceEndpointID(in: data),
              let route = v2RoutingTable.route(for: sourceEndpointID),
              let key = try? V2Crypto.deriveKey(
                pairingCode: route.pairingCode,
                sourceEndpointID: sourceEndpointID
              ) else { return }
        let validation = V2MessageValidator.validate(
            data: data,
            context: V2MessageValidationContext(
                now: Int64(Date().timeIntervalSince1970),
                localEndpointID: document.localEndpointID,
                knownSourceEndpointID: sourceEndpointID,
                authenticationKey: key
            )
        )
        guard validation.accepted, let message = validation.message else { return }

        switch v2ReplayCache.classify(message, nowMs: currentTimeMs()) {
        case .nonceReuse:
            return
        case .duplicate:
            guard message.type == .statusProbe else { return }
        case .new:
            break
        }
        updateV2PeerReachable(true, endpointID: sourceEndpointID)

        if message.type == .statusProbe {
            v2DatagramReplies[v2ReplyKey(eventID: message.eventID, endpointID: sourceEndpointID)] = reply
        }
        switch message.type {
        case .statusProbe:
            handoffV2StateMachine.handleStatusProbe(
                endpointID: sourceEndpointID,
                eventID: message.eventID,
                authenticated: true
            )
        case .statusResponse:
            handoffV2StateMachine.handleStatusResponse(endpointID: sourceEndpointID, authenticated: true)
        case .inputPresent:
            handoffV2StateMachine.handlePeerInputPresent(
                endpointID: sourceEndpointID,
                eventID: message.eventID,
                authenticated: true
            )
        case .handoverRequest:
            guard let intent = message.intent else { return }
            handoffV2StateMachine.handleHandoverRequest(
                endpointID: sourceEndpointID,
                eventID: message.eventID,
                authenticated: true,
                intent: intent
            )
        case .targetReady:
            guard let wakeSucceeded = message.wakeSucceeded else { return }
            handoffV2StateMachine.handleTargetReady(
                endpointID: sourceEndpointID,
                eventID: message.eventID,
                authenticated: true,
                wakeSucceeded: wakeSucceeded
            )
        case .committed:
            guard let switchSucceeded = message.switchSucceeded else { return }
            handoffV2StateMachine.handleCommitted(
                endpointID: sourceEndpointID,
                eventID: message.eventID,
                authenticated: true,
                switchSucceeded: switchSucceeded
            )
        case .cancelled:
            handoffV2StateMachine.handleCancelled(
                endpointID: sourceEndpointID,
                eventID: message.eventID,
                authenticated: true
            )
        }
    }

    private func v2ReplyKey(eventID: String, endpointID: String) -> String {
        "\(eventID.lowercased()):\(endpointID.lowercased())"
    }

    private func scheduleV2StatusProbes() {
        schedule("v2-status-probes", after: 2_000) { [weak self] in
            guard let self, self.configurationSafetyGate.allows(.network),
                  self.usbLearningSafetyGate.allows(.network),
                  !self.v2RoutingTable.routesByEndpointID.isEmpty else { return }
            let now = self.currentTimeMs()
            for endpointID in self.v2RoutingTable.routesByEndpointID.keys.sorted() {
                if let lastSeen = self.v2LastSeenAtMs[endpointID], now - lastSeen > 6_000 {
                    self.v2ReachableEndpoints.remove(endpointID)
                    self.handoffV2StateMachine.setTargetReachable(false, endpointID: endpointID)
                }
                self.sendV2Message(
                    type: .statusProbe,
                    eventID: self.nextEventID(),
                    endpointID: endpointID,
                    intent: nil,
                    wakeSucceeded: nil,
                    switchSucceeded: nil,
                    reason: nil
                )
            }
            self.scheduleV2StatusProbes()
        }
    }

    private func sendPeerMessage(
        type: PeerMessageType,
        eventID: String,
        wakeSucceeded: Bool? = nil
    ) {
        guard configurationSafetyGate.allows(.network), usbLearningSafetyGate.allows(.network),
              let profile = DisplayConfigurationStore.legacyV1RuntimeSelection(in: AppPreferences.localConfiguration).profile else { return }
        let message = makePeerMessage(type: type, eventID: eventID, pairingCode: profile.pairingCode,
                                      wakeSucceeded: wakeSucceeded)
        peerTransport.send(message, host: profile.peerHost, port: profile.peerPort)
    }

    private func makePeerMessage(
        type: PeerMessageType,
        eventID: String,
        pairingCode: String,
        wakeSucceeded: Bool? = nil
    ) -> PeerMessage {
        PeerMessage(
            type: type,
            eventID: eventID,
            source: "mac",
            target: "windows",
            pairingCode: pairingCode,
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
        guard configurationSafetyGate.allows(.wake), usbLearningSafetyGate.allows(.wake) else { return false }
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity(
            "DisplaySwitcher handover" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
        return result == kIOReturnSuccess
    }

    private func switchInactiveDisplaysToMac() {
        guard configurationSafetyGate.allows(.ddc), usbLearningSafetyGate.allows(.ddc) else { return }
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
                : legacyV1StatusText(connected: connected),
            connected: !configurationBlocked && connected
        )
    }

    private func reloadSettings() {
        ddcController.cancelAll()
        let result = AppPreferences.loadDisplayConfigurations()
        configurationSafetyGate.apply(result)
        refreshDDCOperationAccess()
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
        let document = AppPreferences.localConfiguration
        for configuration in configurations.values.sorted(by: { $0.index < $1.index }) {
            let displayID = configuration.index
            let target = Self.ddcTarget(for: configuration, document: document)
            let enabledControls = Set(DisplayControl.allCases.filter { target.enabledCommands.contains($0.ddcCommand) })
            let controls = DisplayControls(displayID: displayID, enabledControls: enabledControls) { [weak self] id, control, value in
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
        let entries = ManualSwitchMenuEntry.entries(in: AppPreferences.localConfiguration)
        for (offset, entry) in entries.enumerated() {
            let item = NSMenuItem(title: entry.title, action: #selector(switchToProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.profileID
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
        ddcController.cancelAll()
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
        guard configurationSafetyGate.allows(.network), usbLearningSafetyGate.allows(.network) else { return }
        sendPeerMessage(type: type, eventID: eventID, wakeSucceeded: wakeSucceeded)
    }

    func sendBurst(type: PeerMessageType, count: Int, eventID: String, wakeSucceeded: Bool?) {
        guard configurationSafetyGate.allows(.network), usbLearningSafetyGate.allows(.network) else { return }
        for attempt in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(attempt) * 0.12)) { [weak self] in
                self?.sendPeerMessage(type: type, eventID: eventID, wakeSucceeded: wakeSucceeded)
            }
        }
    }

    func requestWake(eventID: String) {
        guard configurationSafetyGate.allows(.wake), usbLearningSafetyGate.allows(.wake),
              DisplayConfigurationStore.legacyV1RuntimeSelection(in: AppPreferences.localConfiguration).allowsAutomaticCoordination else { return }
        let wakeSucceeded = wakeMacDisplay()
        handoffStateMachine.handleWakeCompleted(eventID: eventID, success: wakeSucceeded)
    }

    func requestSwitch(eventID: String) {
        guard configurationSafetyGate.allows(.ddc), usbLearningSafetyGate.allows(.ddc),
              DisplayConfigurationStore.legacyV1RuntimeSelection(in: AppPreferences.localConfiguration).allowsAutomaticCoordination else { return }
        switchInputs(toMac: false) { [weak self] success in
            self?.handoffStateMachine.handleSwitchCompleted(eventID: eventID, success: success)
        }
    }

    func updatePeerReachable(_ reachable: Bool) {
        refreshPeerConnectionStatus()
    }

    func sendV2Message(
        type: V2MessageType,
        eventID: String,
        endpointID: String,
        intent: V2HandoverIntent?,
        wakeSucceeded: Bool?,
        switchSucceeded: Bool?,
        reason: V2CancellationReason?
    ) {
        guard configurationSafetyGate.allows(.network), usbLearningSafetyGate.allows(.network),
              let route = v2RoutingTable.route(for: endpointID) else { return }
        let cacheKey = [
            type.rawValue, eventID.lowercased(), endpointID.lowercased(), intent?.rawValue ?? "",
            wakeSucceeded.map(String.init) ?? "", switchSucceeded.map(String.init) ?? "", reason?.rawValue ?? ""
        ].joined(separator: "|")
        let data: Data
        if let cached = v2OutgoingMessages[cacheKey] {
            data = cached
        } else {
            let document = AppPreferences.localConfiguration
            guard let nonce = try? V2Crypto.makeNonce(),
                  let key = try? V2Crypto.deriveKey(
                    pairingCode: route.pairingCode,
                    sourceEndpointID: document.localEndpointID
                  ) else { return }
            var message = V2Message(
                type: type,
                eventID: eventID,
                sourceEndpointID: document.localEndpointID,
                targetEndpointID: endpointID,
                sourcePlatform: .macos,
                timestamp: Int64(Date().timeIntervalSince1970),
                nonce: nonce,
                intent: intent,
                wakeSucceeded: wakeSucceeded,
                switchSucceeded: switchSucceeded,
                reason: reason
            )
            message.authTag = V2Crypto.authenticationTag(for: message, key: key)
            guard let encoded = try? JSONEncoder().encode(message) else { return }
            data = encoded
            if v2OutgoingMessages.count >= 512 { v2OutgoingMessages.removeAll(keepingCapacity: true) }
            v2OutgoingMessages[cacheKey] = data
        }
        let replyKey = v2ReplyKey(eventID: eventID, endpointID: endpointID)
        if type == .statusResponse, let reply = v2DatagramReplies.removeValue(forKey: replyKey) {
            reply(data)
        } else {
            peerTransport.send(data, host: route.host, port: route.port)
        }
    }

    func requestV2Wake(eventID: String) {
        guard configurationSafetyGate.allows(.wake), usbLearningSafetyGate.allows(.wake) else { return }
        handoffV2StateMachine.handleWakeCompleted(eventID: eventID, success: wakeMacDisplay())
    }

    func requestV2Switch(eventID: String, endpointID: String) {
        guard configurationSafetyGate.allows(.ddc), usbLearningSafetyGate.allows(.ddc),
              let route = v2RoutingTable.route(for: endpointID) else { return }
        let document = AppPreferences.localConfiguration
        guard let profile = document.collaborationProfiles.first(where: { $0.id == route.profileID }) else { return }
        let mappings = Dictionary(uniqueKeysWithValues: profile.displayInputs.map {
            ($0.displayID.lowercased(), $0.peerInput)
        })
        let selected = Dictionary(uniqueKeysWithValues: configurations.map { index, configuration in
            var value = configuration
            value.windowsInput = configuration.id.flatMap { mappings[$0.lowercased()] }
            return (index, value)
        })
        switchInputs(
            toMac: false,
            completion: { [weak self] success in
                self?.handoffV2StateMachine.handleSwitchCompleted(eventID: eventID, success: success)
            },
            overrideConfigurations: selected
        )
    }

    func promptV2ManualSelection() {
        guard settingsWindowHasBeenShown else { return }
        settingsWindowController.updatePeerConnectionStatus(
            "未检测到已认证目标，请从菜单手动选择配置",
            connected: false
        )
    }

    func updateV2PeerReachable(_ reachable: Bool, endpointID: String) {
        let normalized = endpointID.lowercased()
        if reachable {
            v2ReachableEndpoints.insert(normalized)
            v2LastSeenAtMs[normalized] = currentTimeMs()
        } else {
            v2ReachableEndpoints.remove(normalized)
            v2LastSeenAtMs.removeValue(forKey: normalized)
        }
        handoffV2StateMachine.setTargetReachable(reachable, endpointID: normalized)
        refreshPeerConnectionStatus()
    }

    private func refreshPeerConnectionStatus() {
        guard settingsWindowHasBeenShown else {
            return
        }
        let snapshot = handoffStateMachine.snapshot()
        let v2Snapshot = handoffV2StateMachine.snapshot()
        let configurationBlocked = configurationSafetyGate.state != .ready
        settingsWindowController.updatePeerConnectionStatus(
            configurationBlocked
                ? "配置安全模式：网络交接已停用"
                : collaborationStatusText(v1Connected: snapshot.peerReachable, v2Snapshot: v2Snapshot),
            connected: !configurationBlocked && (snapshot.peerReachable || !v2ReachableEndpoints.isEmpty)
        )
    }

    private func collaborationStatusText(v1Connected: Bool, v2Snapshot: V2HandoffSnapshot) -> String {
        if !v2RoutingTable.routesByEndpointID.isEmpty {
            let reachable = v2ReachableEndpoints.count
            if reachable > 0 { return "协议 v2：已连接 \(reachable) 个协同配置" }
            return v2Snapshot.coordinationEnabled ? "协议 v2：等待已配置目标…" : "协议 v2：自动协同已暂停"
        }
        return legacyV1StatusText(connected: v1Connected)
    }

    private func legacyV1StatusText(connected: Bool) -> String {
        switch DisplayConfigurationStore.legacyV1RuntimeSelection(in: AppPreferences.localConfiguration) {
        case .compatible(let profile):
            return connected ? "已连接到 \(profile.name)" : "等待 \(profile.name) 心跳…"
        case .requiresProtocolV2:
            return "多个协同配置等待协议 v2，自动协同已暂停"
        case .requiresCompleteConfiguration:
            return "协同配置不完整，自动协同已暂停"
        case .disabled:
            return "协同未启用"
        }
    }

    private func enterConfigurationSafetyState(_ error: DisplayConfigurationStoreError) {
        configurationSafetyGate.requireUserReview(error)
        refreshDDCOperationAccess()
        pendingUSBSwitch?.cancel()
        pendingUSBSwitch = nil
        usbMonitor.stop()
        peerTransport.stop()
        for (_, item) in pendingSchedulerItems {
            item.cancel()
        }
        pendingSchedulerItems.removeAll()
        let interruptedInspections = Array(pendingPeerInspections.keys)
        for inspectionID in interruptedInspections {
            completePeerCapabilityInspection(inspectionID, result: .noResponse)
        }
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
        handoffV2StateMachine.configure(
            localEndpointID: AppPreferences.localConfiguration.localEndpointID,
            coordinationEnabled: false,
            sourceInputPresent: false,
            targetInputPresent: false,
            enabledTargets: []
        )
        v2ReplayCache.reset()
        v2OutgoingMessages.removeAll(keepingCapacity: true)
        v2DatagramReplies.removeAll(keepingCapacity: true)
        updateConfigurationSafetyUI()
        refreshPeerConnectionStatus()
    }

    private func refreshDDCOperationAccess() {
        ddcController.setOperationsAllowed(
            configurationSafetyGate.allows(.ddc) && usbLearningSafetyGate.allows(.ddc)
        )
    }

    private func updateConfigurationSafetyUI() {
        let enabled = configurationSafetyGate.state == .ready
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
