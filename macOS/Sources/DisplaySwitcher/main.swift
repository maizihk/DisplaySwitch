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

private final class PendingPeerCapabilityInspection {
    let id: String
    let profile: CollaborationProfile
    let v2EventID: String
    let completion: (PeerCapabilityInspectionResult) -> Void

    init(id: String, profile: CollaborationProfile, v2EventID: String,
         completion: @escaping (PeerCapabilityInspectionResult) -> Void) {
        self.id = id
        self.profile = profile
        self.v2EventID = v2EventID
        self.completion = completion
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, HandoffScheduler, HandoffEventIDSource, V2HandoffActionSink, LocalUSBSwitchActionSink {
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var instanceLockFD: Int32 = -1
    private var ownsPrimaryInstance = false
    private let workerQueue = DispatchQueue(label: "DisplaySwitcher.ddc")
    private let inputSwitchQueue = DispatchQueue(
        label: "DisplaySwitcher.input-source", qos: .userInitiated
    )
    private let ddcController = DDCController()
    private let inputSourceDiagnostics = InputSourceDiagnosticStore.shared
    private lazy var inputSourceSwitchService = InputSourceSwitchService(
        resolver: NativeInputSourceTransportResolver(diagnostics: inputSourceDiagnostics),
        diagnostics: inputSourceDiagnostics
    )
    private lazy var ddcWriteCoordinator = DDCLatestWinsCoordinator(
        executor: DDCControllerWriteExecutor(
            queue: workerQueue,
            operation: { [weak self] request in
                guard let self else { return }
                try self.ddcController.write(
                    stableID: request.key.stableID,
                    selector: request.selector,
                    command: request.key.command,
                    value: request.value
                )
            },
            cancellation: { [weak self] in self?.ddcController.cancelAll() }
        )
    )
    private let usbMonitor = USBMonitor()
    private lazy var localUSBSwitchCoordinator = LocalUSBSwitchCoordinator(
        configuration: localUSBRuntimeConfiguration(),
        sink: self,
        nowMs: { [weak self] in self?.currentTimeMs() ?? 0 }
    )
    private let peerTransport = PeerTransport()
    private let configurationSafetyGate = ConfigurationSafetyGate()
    private let usbLearningSafetyGate = USBLearningSafetyGate()
    private var pendingSchedulerItems: [String: DispatchWorkItem] = [:]
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
    private let collaborationStatusStore = CollaborationStatusStore()
    private var v2OutgoingMessages: [String: Data] = [:]
    private var v2DatagramReplies: [String: PeerTransport.DataReply] = [:]
    private var v2UnboundProbeResponses: [String: Data] = [:]
    private var pendingPeerInspections: [String: PendingPeerCapabilityInspection] = [:]
    private var inspectionIDByEventID: [String: String] = [:]
    private var displayControls: [Int: DisplayControls] = [:]
    private var displayMenuItems: [Int: NSMenuItem] = [:]
    private var profileSwitchItems: [NSMenuItem] = []
    private var configurations: [Int: DisplayConfiguration] = [:]
    private var settingsWindowHasBeenShown = false

    private lazy var settingsWindowController: SettingsWindowController = {
        let controller = SettingsWindowController()
        controller.onSave = { [weak self] in
            self?.reloadSettings()
        }
        controller.onConfigurationSaveFailure = { [weak self] error in
            self?.enterConfigurationSafetyState(error)
        }
        controller.onLearnUSB = { [weak self] in
            self?.startUSBLearning()
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
        controller.collaborationStatus = { [weak self] profile in
            guard let self else { return .neverChecked }
            return self.collaborationStatusStore.state(
                for: profile,
                displays: AppPreferences.localConfiguration.displays,
                nowMs: self.currentTimeMs()
            )
        }
        controller.onReadDDC = { [weak self] stableID in
            self?.readDDCForSettings(stableID: stableID)
        }
        controller.cachedDDCValue = { [weak self] stableID, command in
            self?.ddcController.cachedValue(stableID: stableID, command: command)
        }
        controller.onWriteDDC = { [weak self] stableID, command, value in
            guard let self,
                  let entry = self.configurations.first(where: {
                      ($0.value.id ?? $0.value.selector).caseInsensitiveCompare(stableID) == .orderedSame
                  }),
                  let control = DisplayControl.allCases.first(where: { $0.ddcCommand == command }) else { return }
            self.setControl(control, value: value, fromDisplay: entry.key)
        }
        controller.onRefreshDisplays = { [weak self] in
            self?.detectDisplays(showFailure: true)
        }
        controller.onWindowClosed = { [weak self] in
            self?.ddcWriteCoordinator.cancelAll()
            self?.ddcController.cancelAll()
            self?.refreshDDCOperationAccess()
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
        ddcController.setControlChannel(loadResult.document.controlChannel)
        ddcWriteCoordinator.onCompletion = { [weak self] request, result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let value):
                    guard let index = self.configurations.first(where: {
                        ($0.value.id ?? $0.value.selector).caseInsensitiveCompare(request.key.stableID) == .orderedSame
                    })?.key,
                    let control = DisplayControl.allCases.first(where: { $0.ddcCommand == request.key.command }) else { return }
                    self.displayControls[index]?.update(control, value: value)
                    self.settingsWindowController.updateDDCWriteStatus(
                        stableID: request.key.stableID, command: request.key.command,
                        value: value, error: nil,
                        diagnostic: self.ddcController.diagnostic(selector: request.selector)
                    )
                case .failure(let error):
                    self.settingsWindowController.updateDDCWriteStatus(
                        stableID: request.key.stableID, command: request.key.command,
                        value: nil, error: error,
                        diagnostic: self.ddcController.diagnostic(selector: request.selector)
                    )
                    self.showError(title: "显示器调节失败", error: error)
                }
            }
        }

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "显示器控制")
        }

        let menu = NSMenu()
        menu.delegate = self
        rebuildProfileSwitchItems(in: menu)
        menu.addItem(.separator())

        menu.addItem(linkedItem)
        menu.addItem(.separator())

        menu.addItem(detectItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let copyInputDiagnosticItem = NSMenuItem(
            title: "复制输入切换诊断",
            action: #selector(copyInputSwitchDiagnostics),
            keyEquivalent: ""
        )
        copyInputDiagnosticItem.target = self
        menu.addItem(copyInputDiagnosticItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        rebuildDisplayMenuItems()
        updateConfigurationSafetyUI()
        presentDDCValues(for: .startup)

        usbMonitor.onPresenceChanged = { [weak self] isPresent in
            self?.handleUSBPresenceChange(isPresent)
        }
        usbMonitor.onInitialPresenceObserved = { [weak self] isPresent in
            _ = self?.localUSBSwitchCoordinator.observeUSB(present: isPresent)
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
        presentDDCValues(for: .trayOpen)
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
        showError(
            title: "协同配置尚未连接",
            error: NSError(
                domain: "DisplaySwitcher.Collaboration",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "请先在设置中检测并确认该配置的对端。"]
            )
        )
    }

    private func switchToTargetInputs(
        completion: ((Bool) -> Void)? = nil,
        configurations targetConfigurations: [Int: DisplayConfiguration]
    ) {
        guard configurationSafetyGate.allows(.ddc), usbLearningSafetyGate.allows(.ddc) else {
            completion?(false)
            return
        }
        let targetDisplayIDs = targetConfigurations.keys.sorted()
        guard !targetDisplayIDs.isEmpty else {
            completion?(false)
            return
        }
        profileSwitchItems.forEach { $0.isEnabled = false }
        let targets = targetDisplayIDs.compactMap { displayID -> InputSourceSwitchTarget? in
            guard let configuration = targetConfigurations[displayID] else { return nil }
            return InputSourceSwitchTarget(
                stableID: configuration.id ?? configuration.selector,
                selector: configuration.selector,
                targetInput: configuration.targetInput,
                alternateInput: configuration.localInput
            )
        }
        let inputSourceSwitchService = inputSourceSwitchService

        inputSwitchQueue.async { [weak self] in
            let result = inputSourceSwitchService.switchInputs(
                targets,
                origin: .manualOrCollaboration
            ) { [weak self] in
                self?.configurationSafetyGate.allows(.ddc) == true
                    && self?.usbLearningSafetyGate.allows(.ddc) == true
            }
            if let firstFailure = result.firstFailure {
                self?.finishSwitch(message: "部分切换失败", activeMenuItem: nil)
                self?.showError(title: "显示器输入源切换失败", error: firstFailure)
                DispatchQueue.main.async { completion?(false) }
            } else {
                self?.finishSwitch(message: "切换完成", activeMenuItem: nil)
                DispatchQueue.main.async { completion?(true) }
            }
        }
    }

    @objc private func toggleLinkedControls() {
        let previous = linkedItem.state
        linkedItem.state = linkedItem.state == .on ? .off : .on
        var document = AppPreferences.localConfiguration
        document.linkAllDisplays = linkedItem.state == .on
        do {
            try AppPreferences.saveLocalConfiguration(document)
            reloadSettings()
        } catch {
            linkedItem.state = previous
            showError(title: "设置未保存", error: error)
        }
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
        ddcWriteCoordinator.cancelAll()
        refreshDDCOperationAccess()
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
                        self.presentDDCValues(for: .displayDetection)
                        self.finishDetection()
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

    private func setControl(_ control: DisplayControl, value: Int, fromDisplay displayID: Int) {
        guard configurationSafetyGate.allows(.ddc), usbLearningSafetyGate.allows(.ddc) else { return }
        let targetDisplays = linkedItem.state == .on ? configurations.keys.sorted() : [displayID]
        let currentConfigurations = configurations
        let document = AppPreferences.localConfiguration
        let targets = targetDisplays.compactMap { currentConfigurations[$0] }
            .map { Self.ddcTarget(for: $0, document: document) }
            .filter { $0.enabledCommands.contains(control.ddcCommand) }

        for target in targets {
            ddcWriteCoordinator.submit(DDCWriteRequest(
                key: DDCWriteKey(stableID: target.stableID, command: control.ddcCommand),
                selector: target.selector,
                value: value
            ))
        }
    }

    private func readDDCForSettings(stableID: String) {
        guard DDCValuePresentationPolicy.source(for: .settingsReadButton) == .hardware else { return }
        guard configurationSafetyGate.allows(.ddc), usbLearningSafetyGate.allows(.ddc),
              let configuration = configurations.values.first(where: {
                  ($0.id ?? $0.selector).caseInsensitiveCompare(stableID) == .orderedSame
              }) else { return }
        let target = Self.ddcTarget(for: configuration, document: AppPreferences.localConfiguration)
        workerQueue.async { [weak self] in
            guard let self else { return }
            let batch = self.ddcController.read(targets: [target])
            let result = batch[target.stableID] ?? [:]
            let skipReason = batch.skipped[target.stableID]
            let diagnostic = self.ddcController.diagnostic(selector: target.selector)
            DispatchQueue.main.async {
                guard self.settingsWindowController.isSettingsVisible else { return }
                self.settingsWindowController.updateDDCValues(
                    stableID: target.stableID, values: result, diagnostic: diagnostic,
                    skipReason: skipReason
                )
            }
        }
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
        document: DisplayConfigurationStoreV5Document
    ) -> DDCDisplayTarget {
        let stableID = configuration.id ?? configuration.selector
        let stored = document.displays.first { $0.id.caseInsensitiveCompare(stableID) == .orderedSame }
        let enabled = stored.map(DisplaySettingsSemantics.enabledCommands(for:)) ?? []
        return DDCDisplayTarget(stableID: stableID, selector: configuration.selector,
                                enabledCommands: enabled)
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

    private func presentDDCValues(for entryPoint: DDCValuePresentationEntryPoint) {
        guard DDCValuePresentationPolicy.source(for: entryPoint) == .cache else { return }
        restoreCachedValues()
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

    private func localUSBRuntimeConfiguration(
        document: DisplayConfigurationStoreV5Document = AppPreferences.localConfiguration,
        learning: Bool? = nil
    ) -> LocalUSBSwitchRuntimeConfiguration {
        let mappings = Dictionary(uniqueKeysWithValues: document.usbSwitch.displayInputs.map {
            ($0.displayID.lowercased(), $0.targetInput)
        })
        let availableIDs = Set(configurations.values.compactMap { ($0.id ?? $0.selector).lowercased() })
        let displays = document.displays.map {
            LocalUSBSwitchDisplay(
                displayID: $0.id,
                targetInput: mappings[$0.id.lowercased()],
                available: availableIDs.contains($0.id.lowercased())
            )
        }
        let collaborationValid = document.usbSwitch.collaborationWakeEnabled
            ? DisplayConfigurationStore.isValidCollaborationWakeSelection(document.usbSwitch, document: document)
            : false
        return LocalUSBSwitchRuntimeConfiguration(
            enabled: document.usbSwitch.enabled,
            learning: learning ?? !usbLearningSafetyGate.allows(.usb),
            safeState: configurationSafetyGate.state != .ready,
            collaborationWakeEnabled: document.usbSwitch.collaborationWakeEnabled,
            collaborationProfileValid: collaborationValid,
            displays: displays
        )
    }

    private func configureUSBMonitor() {
        usbMonitor.stop()
        guard configurationSafetyGate.allows(.usb), usbLearningSafetyGate.allows(.usb) else { return }
        let document = AppPreferences.localConfiguration
        localUSBSwitchCoordinator.updateConfiguration(localUSBRuntimeConfiguration(document: document))
        if document.usbSwitch.enabled,
           let value = document.usbSwitch.triggerDevice?.localReference,
           let reference = USBDeviceReference(localReference: value) {
            usbMonitor.start(triggerReference: reference)
        }
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
        let document = AppPreferences.localConfiguration
        v2RoutingTable = V2EndpointRoutingTable.build(from: document)
        collaborationStatusStore.removeMissingProfiles(Set(document.collaborationProfiles.map(\.id)))
        let configuredEndpointIDs = Set(v2RoutingTable.routesByEndpointID.keys)
        v2ReachableEndpoints.formIntersection(configuredEndpointIDs)
        v2LastSeenAtMs = v2LastSeenAtMs.filter { configuredEndpointIDs.contains($0.key) }
        v2ReplayCache.reset()
        v2OutgoingMessages.removeAll(keepingCapacity: true)
        v2DatagramReplies.removeAll(keepingCapacity: true)
        v2UnboundProbeResponses.removeAll(keepingCapacity: true)
        let v2Enabled = networkAllowed && usbLearningSafetyGate.allows(.network)
            && !v2RoutingTable.routesByEndpointID.isEmpty
        let unboundProbeEnabled = networkAllowed && usbLearningSafetyGate.allows(.network)
            && !V2UnboundStatusProbeResolver.eligibleProfiles(in: document).isEmpty
        handoffV2StateMachine.configure(
            localEndpointID: document.localEndpointID,
            coordinationEnabled: v2Enabled,
            enabledTargets: v2RoutingTable.routesByEndpointID.values.map {
                V2HandoffTarget(
                    endpointID: $0.endpointID,
                    capability: .v2,
                    reachable: v2ReachableEndpoints.contains($0.endpointID)
                )
            }
        )
        refreshPeerConnectionStatus()
        if v2Enabled || unboundProbeEnabled {
            peerTransport.start(port: document.listenPort)
        }
        if v2Enabled { scheduleV2StatusProbes() }
    }

    private func startUSBLearning() {
        guard configurationSafetyGate.allows(.usb) else { return }
        usbLearningSafetyGate.begin()
        refreshDDCOperationAccess()
        localUSBSwitchCoordinator.updateConfiguration(localUSBRuntimeConfiguration(learning: true))
        configurePeerTransport()
        usbMonitor.stop()
        usbMonitor.start(triggerDevice: nil)
        usbMonitor.beginLearning { [weak self] devices in
            guard let self else { return }
            _ = self.settingsWindowController.presentDetectedUSBDevices(devices)
        }
    }

    private func cancelUSBLearning() {
        usbMonitor.cancelLearning()
        finishUSBLearning()
    }

    private func finishUSBLearning() {
        guard usbLearningSafetyGate.end() else { return }
        refreshDDCOperationAccess()
        localUSBSwitchCoordinator.updateConfiguration(localUSBRuntimeConfiguration())
        configureUSBMonitor()
        configurePeerTransport()
    }

    private func handleUSBPresenceChange(_ isPresent: Bool) {
        guard configurationSafetyGate.allows(.usb), usbLearningSafetyGate.allows(.usb) else { return }
        _ = localUSBSwitchCoordinator.observeUSB(present: isPresent)
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
        collaborationStatusStore.beginCheck(profileID: profile.id)
        settingsWindowController.refreshSelectedCollaborationStatus()
        inspectionIDByEventID[eventID] = inspectionID
        peerTransport.start(port: AppPreferences.localConfiguration.listenPort)
        guard let data = makeV2StatusProbe(eventID: eventID, profile: profile) else {
            completePeerCapabilityInspection(inspectionID, result: .authenticationFailed)
            return
        }
        peerTransport.send(data, host: profile.peerHost, port: profile.peerPort)
        schedule("v2-inspection-\(inspectionID)", after: 1_000) { [weak self] in
            self?.completePeerCapabilityInspection(inspectionID, result: .noResponse)
        }
    }

    private func makeV2StatusProbe(eventID: String, profile: CollaborationProfile) -> Data? {
        let localEndpointID = AppPreferences.localConfiguration.localEndpointID
        guard let nonce = try? V2Crypto.makeNonce(),
              let message = try? V2PeerCapabilityInspection.statusProbe(
                eventID: eventID,
                localEndpointID: localEndpointID,
                profile: profile,
                timestamp: Int64(Date().timeIntervalSince1970),
                nonce: nonce
              ) else { return nil }
        return try? JSONEncoder().encode(message)
    }

    private func completePeerCapabilityInspection(
        _ inspectionID: String,
        result: PeerCapabilityInspectionResult
    ) {
        guard let pending = pendingPeerInspections.removeValue(forKey: inspectionID) else { return }
        cancel("v2-inspection-\(inspectionID)")
        inspectionIDByEventID.removeValue(forKey: pending.v2EventID)
        if case .v2 = result {
            collaborationStatusStore.finishCheck(profileID: pending.profile.id, responded: true)
        } else {
            collaborationStatusStore.finishCheck(profileID: pending.profile.id, responded: false)
        }
        pending.completion(result)
        settingsWindowController.refreshSelectedCollaborationStatus()
    }

    private func handlePendingV2Inspection(_ data: Data) -> Bool {
        guard let eventID = V2MessageEnvelope.eventID(in: data),
              let inspectionID = inspectionIDByEventID[eventID],
              let pending = pendingPeerInspections[inspectionID],
              eventID == pending.v2EventID else { return false }
        switch V2PeerCapabilityInspection.validateResponse(
            data: data,
            profile: pending.profile,
            eventID: pending.v2EventID,
            localEndpointID: AppPreferences.localConfiguration.localEndpointID,
            now: Int64(Date().timeIntervalSince1970)
        ) {
        case .accepted(let endpointID):
            completePeerCapabilityInspection(inspectionID, result: .v2(endpointID: endpointID))
        case .authenticationFailed:
            completePeerCapabilityInspection(inspectionID, result: .authenticationFailed)
        case .rejected:
            break
        }
        return true
    }

    private func handlePeerDatagram(_ data: Data, reply: @escaping PeerTransport.DataReply) {
        guard configurationSafetyGate.allows(.network), usbLearningSafetyGate.allows(.network) else { return }
        switch PeerProtocolVersionDispatcher.version(in: data) {
        case .v2:
            if handlePendingV2Inspection(data) { return }
            handleV2Datagram(data, reply: reply)
        case .unsupported, nil:
            return
        }
    }

    private func handleV2Datagram(_ data: Data, reply: @escaping PeerTransport.DataReply) {
        let document = AppPreferences.localConfiguration
        guard let sourceEndpointID = V2MessageEnvelope.sourceEndpointID(in: data) else { return }
        guard let route = v2RoutingTable.route(for: sourceEndpointID) else {
            handleUnboundV2StatusProbe(data, document: document, reply: reply)
            return
        }
        guard
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
        collaborationStatusStore.recordAuthenticatedMessage(profileID: route.profileID, nowMs: currentTimeMs())

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
        case .wakeDisplay:
            handoffV2StateMachine.handleWakeDisplay(
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

    private func handleUnboundV2StatusProbe(
        _ data: Data,
        document: DisplayConfigurationStoreV5Document,
        reply: @escaping PeerTransport.DataReply
    ) {
        guard let nonce = try? V2Crypto.makeNonce(),
              let resolution = V2UnboundStatusProbeResolver.resolve(
                data: data,
                document: document,
                routingTable: v2RoutingTable,
                now: Int64(Date().timeIntervalSince1970),
                responseNonce: nonce
              ) else { return }

        let cacheKey = v2ReplyKey(
            eventID: resolution.request.eventID,
            endpointID: resolution.request.sourceEndpointID
        )
        switch v2ReplayCache.classify(resolution.request, nowMs: currentTimeMs()) {
        case .nonceReuse:
            return
        case .duplicate:
            guard let cached = v2UnboundProbeResponses[cacheKey] else { return }
            reply(cached)
        case .new:
            if v2UnboundProbeResponses.count >= 128 {
                v2UnboundProbeResponses.removeAll(keepingCapacity: true)
            }
            v2UnboundProbeResponses[cacheKey] = resolution.responseData
            reply(resolution.responseData)
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
            self.refreshPeerConnectionStatus()
            self.scheduleV2StatusProbes()
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
        let configurationBlocked = configurationSafetyGate.state != .ready
        if configurationBlocked {
            settingsWindowController.updatePeerConnectionStatus(
                "配置安全模式：网络交接已停用", connected: false
            )
        } else {
            refreshPeerConnectionStatus()
        }
    }

    @objc private func copyInputSwitchDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(inputSourceDiagnostics.exportText(), forType: .string)
    }

    private func reloadSettings() {
        ddcWriteCoordinator.cancelAll()
        let result = AppPreferences.loadDisplayConfigurations()
        configurationSafetyGate.apply(result)
        refreshDDCOperationAccess()
        let values = result.configurations
        configurations = Dictionary(uniqueKeysWithValues: values.map { ($0.index, $0) })
        ddcController.updateConfigurations(values)
        ddcController.setControlChannel(result.document.controlChannel)
        rebuildDisplayMenuItems()
        if let menu = statusItem.menu { rebuildProfileSwitchItems(in: menu) }
        linkedItem.state = AppPreferences.linkedDisplays ? .on : .off
        configureUSBMonitor()
        configurePeerTransport()
        updateConfigurationSafetyUI()
        presentDDCValues(for: .configurationReload)
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
            let stored = document.displays.first {
                $0.id.caseInsensitiveCompare(target.stableID) == .orderedSame
            }
            let enabledControls = Set(DisplayControl.allCases.filter { control in
                guard target.enabledCommands.contains(control.ddcCommand), let stored else { return false }
                switch control {
                case .luminance: return stored.brightnessShowInTray
                case .contrast: return stored.contrastShowInTray
                case .volume: return stored.volumeShowInTray
                }
            })
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
        ddcWriteCoordinator.cancelAll()
        peerTransport.stop()
        releaseSingleInstanceLock()
    }

    private func currentTimeMs() -> Int64 {
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

    func requestV2Wake(eventID: String, completionRequired: Bool) {
        guard configurationSafetyGate.allows(.wake), usbLearningSafetyGate.allows(.wake) else { return }
        if completionRequired {
            handoffV2StateMachine.handleWakeCompleted(eventID: eventID, success: wakeMacDisplay())
        } else {
            localUSBSwitchCoordinator.receiveAuthenticatedWakeDisplay()
        }
    }

    func switchUSBDisplay(displayID: String, targetInput: Int, completion: @escaping (Bool) -> Void) {
        guard configurationSafetyGate.allows(.ddc), usbLearningSafetyGate.allows(.ddc),
              let configuration = configurations.values.first(where: {
                  ($0.id ?? $0.selector).caseInsensitiveCompare(displayID) == .orderedSame
              }) else {
            completion(false)
            return
        }
        let target = InputSourceSwitchTarget(
            stableID: configuration.id ?? configuration.selector,
            selector: configuration.selector,
            targetInput: targetInput,
            alternateInput: targetInput == configuration.localInput
                ? configuration.targetInput
                : configuration.localInput
        )
        let inputSourceSwitchService = inputSourceSwitchService
        inputSwitchQueue.async { [weak self] in
            guard let self, self.configurationSafetyGate.allows(.ddc),
                  self.usbLearningSafetyGate.allows(.ddc) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let result = inputSourceSwitchService.switchInputs([target], origin: .usb) { [weak self] in
                self?.configurationSafetyGate.allows(.ddc) == true
                    && self?.usbLearningSafetyGate.allows(.ddc) == true
            }
            DispatchQueue.main.async { completion(result.allSucceeded) }
        }
    }

    func wakeUSBDisplay() {
        guard configurationSafetyGate.allows(.wake), usbLearningSafetyGate.allows(.wake) else { return }
        _ = wakeMacDisplay()
    }

    func sendCollaborationWakeDisplay() -> Bool {
        guard configurationSafetyGate.allows(.network), usbLearningSafetyGate.allows(.network) else { return false }
        let document = AppPreferences.localConfiguration
        guard document.usbSwitch.collaborationWakeEnabled,
              let profileID = document.usbSwitch.collaborationProfileID,
              let profile = document.collaborationProfiles.first(where: {
                  $0.id.caseInsensitiveCompare(profileID) == .orderedSame
              }),
              DisplayConfigurationStore.isValidCollaborationWakeSelection(document.usbSwitch, document: document),
              let endpointID = profile.peerEndpointID.flatMap(V2Crypto.normalizedUUID),
              v2RoutingTable.route(for: endpointID)?.profileID == profile.id else { return false }
        sendV2Message(
            type: .wakeDisplay,
            eventID: nextEventID(),
            endpointID: endpointID,
            intent: nil,
            wakeSucceeded: nil,
            switchSucceeded: nil,
            reason: nil
        )
        return true
    }

    func reportUSBSwitch(displayID: String?, reason: LocalUSBSwitchReportReason) {
        _ = displayID
        let message: String
        switch reason {
        case .missingMapping: message = "部分显示器未配置 USB 目标输入源"
        case .displayUnavailable: message = "部分显示器当前不可用"
        case .ddcFailed: message = "部分显示器切换失败"
        case .wakeNotSent: message = "本机切换已继续，协同唤醒未发送"
        }
        settingsWindowController.updateUSBSwitchStatus(message, isError: true)
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
            value.targetInput = configuration.id.flatMap { mappings[$0.lowercased()] }
            return (index, value)
        })
        switchToTargetInputs(
            completion: { [weak self] success in
                self?.handoffV2StateMachine.handleSwitchCompleted(eventID: eventID, success: success)
            },
            configurations: selected
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
        let configurationBlocked = configurationSafetyGate.state != .ready
        if configurationBlocked {
            settingsWindowController.updatePeerConnectionStatus("配置安全模式：网络交接已停用", connected: false)
        } else {
            settingsWindowController.refreshSelectedCollaborationStatus()
        }
    }

    private func enterConfigurationSafetyState(_ error: DisplayConfigurationStoreError) {
        configurationSafetyGate.requireUserReview(error)
        localUSBSwitchCoordinator.updateConfiguration(localUSBRuntimeConfiguration())
        refreshDDCOperationAccess()
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
        handoffV2StateMachine.configure(
            localEndpointID: AppPreferences.localConfiguration.localEndpointID,
            coordinationEnabled: false,
            enabledTargets: []
        )
        v2ReplayCache.reset()
        v2OutgoingMessages.removeAll(keepingCapacity: true)
        v2DatagramReplies.removeAll(keepingCapacity: true)
        updateConfigurationSafetyUI()
        refreshPeerConnectionStatus()
    }

    private func refreshDDCOperationAccess() {
        let allowed = configurationSafetyGate.allows(.ddc) && usbLearningSafetyGate.allows(.ddc)
        ddcController.setOperationsAllowed(allowed)
        ddcWriteCoordinator.setOperationsAllowed(allowed)
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
