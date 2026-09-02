import AppKit
import Foundation

extension NSColor {
    func cgColor(using appearance: NSAppearance) -> CGColor {
        var result = NSColor.clear.cgColor
        appearance.performAsCurrentDrawingAppearance {
            result = cgColor
        }
        return result
    }
}

enum SettingsSurfaceStyle {
    static let cardCornerRadius: CGFloat = 12
    static let cardBorderWidth: CGFloat = 1
    static let pagePaintsBackground = false
    static let scrollPaintsBackground = false

    static func pageBackgroundColor(using appearance: NSAppearance) -> CGColor {
        NSColor.underPageBackgroundColor.cgColor(using: appearance)
    }
}

final class SettingsCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor(using: effectiveAppearance)
        layer?.borderColor = NSColor.separatorColor.cgColor(using: effectiveAppearance)
        layer?.borderWidth = SettingsSurfaceStyle.cardBorderWidth
        layer?.cornerRadius = SettingsSurfaceStyle.cardCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

class SettingsPageBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
}

final class SettingsPageScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = SettingsSurfaceStyle.scrollPaintsBackground
        borderType = .noBorder
        updateSemanticBackground()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSemanticBackground()
    }

    private func updateSemanticBackground() {
        backgroundColor = .clear
        contentView.drawsBackground = false
    }
}

enum SettingsActionButtonStyle {
    static let controlSize: NSControl.ControlSize = .regular
    static let bezelStyle: NSButton.BezelStyle = .rounded
    static let minimumHeight: CGFloat = 28

    static func apply(to button: NSButton) {
        button.controlSize = controlSize
        button.bezelStyle = bezelStyle
        button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        if !button.constraints.contains(where: { $0.identifier == "SettingsActionButton.minimumHeight" }) {
            let height = button.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight)
            height.identifier = "SettingsActionButton.minimumHeight"
            height.isActive = true
        }
    }
}

enum CollaborationConnectionState: Equatable {
    case disabled
    case incomplete
    case neverChecked
    case checking
    case noResponse
    case available
    case connected
    case disconnected

    var text: String {
        switch self {
        case .disabled: return "未启用"
        case .incomplete: return "配置不完整"
        case .neverChecked: return "尚未检测"
        case .checking: return "正在检测"
        case .noResponse: return "无响应"
        case .available: return "v2 可用"
        case .connected: return "已连接"
        case .disconnected: return "连接已断开"
        }
    }

    var connected: Bool { self == .available || self == .connected }
}

final class CollaborationStatusStore {
    private struct RuntimeState {
        var checking = false
        var checked = false
        var responded = false
        var lastAuthenticatedAtMs: Int64?
    }

    private var states: [String: RuntimeState] = [:]

    func state(
        for profile: CollaborationProfile,
        displays: [DisplayConfigurationV4Display],
        nowMs: Int64
    ) -> CollaborationConnectionState {
        guard profile.coordinationEnabled else { return .disabled }
        let known = Set(displays.map { $0.id.lowercased() })
        guard DisplayConfigurationStore.inspectProfile(
            profile, displays: displays, ddcAvailableDisplayIDs: known
        ).issues.isEmpty else { return .incomplete }
        let runtime = states[profile.id] ?? RuntimeState()
        if runtime.checking { return .checking }
        if let last = runtime.lastAuthenticatedAtMs {
            return nowMs - last <= 6_000 ? .connected : .disconnected
        }
        if runtime.responded { return .available }
        if runtime.checked { return .noResponse }
        return .neverChecked
    }

    func beginCheck(profileID: String) {
        var value = states[profileID] ?? RuntimeState()
        value.checking = true
        value.checked = true
        states[profileID] = value
    }

    func finishCheck(profileID: String, responded: Bool) {
        var value = states[profileID] ?? RuntimeState()
        value.checking = false
        value.checked = true
        value.responded = responded
        states[profileID] = value
    }

    func recordAuthenticatedMessage(profileID: String, nowMs: Int64) {
        var value = states[profileID] ?? RuntimeState()
        value.checking = false
        value.responded = true
        value.lastAuthenticatedAtMs = nowMs
        states[profileID] = value
    }

    func removeMissingProfiles(_ profileIDs: Set<String>) {
        states = states.filter { profileIDs.contains($0.key) }
    }
}

enum V2OnlyDatagramGate {
    static func accepts(_ data: Data) -> Bool {
        PeerProtocolVersionDispatcher.version(in: data) == .v2
    }
}

enum DisplaySettingsSemantics {
    static func enabledCommands(for display: DisplayConfigurationV4Display) -> Set<DDCCommand> {
        var result = Set<DDCCommand>()
        if display.brightnessEnabled { result.insert(.luminance) }
        if display.contrastEnabled { result.insert(.contrast) }
        if display.volumeEnabled { result.insert(.volume) }
        return result
    }

    static func trayCommands(for display: DisplayConfigurationV4Display) -> Set<DDCCommand> {
        var result = Set<DDCCommand>()
        if display.brightnessEnabled && display.brightnessShowInTray { result.insert(.luminance) }
        if display.contrastEnabled && display.contrastShowInTray { result.insert(.contrast) }
        if display.volumeEnabled && display.volumeShowInTray { result.insert(.volume) }
        return result
    }
}

struct TrayDisplayMenuProjection {
    struct Entry: Equatable {
        let displayID: Int
        let title: String
        let commands: Set<DDCCommand>
    }

    static func entries(
        configurations: [DisplayConfiguration],
        displays: [DisplayConfigurationV4Display]
    ) -> [Entry] {
        configurations.sorted(by: { $0.index < $1.index }).compactMap { configuration in
            let stableID = configuration.id ?? configuration.selector
            guard let display = displays.first(where: {
                $0.id.caseInsensitiveCompare(stableID) == .orderedSame
            }) else { return nil }
            let commands = DisplaySettingsSemantics.trayCommands(for: display)
            guard !commands.isEmpty else { return nil }
            return Entry(displayID: configuration.index, title: configuration.name, commands: commands)
        }
    }
}

enum TrayStaticMenuAction: CaseIterable, Equatable {
    case settings
    case quit
}

enum TrayMenuSeparatorProjection {
    static func showsDynamicContentSeparator(
        profileCount: Int,
        displayGroupCount: Int
    ) -> Bool {
        profileCount > 0 || displayGroupCount > 0
    }
}

enum DisplayControlTargetProjection {
    static func displayIDs(
        selectedDisplayID: Int,
        availableDisplayIDs: [Int],
        linkAllDisplays: Bool
    ) -> [Int] {
        linkAllDisplays ? availableDisplayIDs.sorted() : [selectedDisplayID]
    }
}

struct DisplayCachedValuePresentation: Equatable {
    struct Entry: Hashable {
        let stableID: String
        let command: DDCCommand
        let value: Int

        var label: String { "≈\(value)" }
    }

    static func entries(
        displays: [DisplayConfigurationV4Display],
        cachedValue: (String, DDCCommand) -> Int?
    ) -> [Entry] {
        displays.flatMap { display in
            DisplaySettingsSemantics.enabledCommands(for: display).compactMap { command in
                guard let value = cachedValue(display.id, command) else { return nil }
                return Entry(stableID: display.id.lowercased(), command: command, value: value)
            }
        }
    }
}

enum DisplayStatusLayout {
    static let wraps = false
    static let maximumNumberOfLines = 1
}

enum SettingsModuleContentItem: Equatable {
    case separator
    case linkAllDisplays
    case displayReadStatus
    case displayControls
}

enum DisplayControlModuleContent {
    static let items: [SettingsModuleContentItem] = [.linkAllDisplays]
}

enum DisplayReadModuleContent {
    static let items: [SettingsModuleContentItem] = [.displayReadStatus, .separator, .displayControls]
}

enum SettingsPageLayoutAction: String, Equatable {
    case toggleUSBAutomation
    case learnUSBDevice
    case selectUSBWakeProfile
    case toggleUSBWake
    case requestLocalNetworkPermission
    case inspectCollaboration
    case selectCollaborationProfile
    case addCollaborationProfile
    case toggleCollaborationProfile
    case deleteCollaborationProfile
    case editValue
}

enum SettingsFormRowLayout: Equatable {
    case leadingLabelFixedControlColumn

    static let contentWidth: Double = 590
    static let labelColumnWidth: Double = 90
    static let controlColumnSpacing: Double = 10
    static var controlColumnWidth: Double {
        contentWidth - labelColumnWidth - controlColumnSpacing
    }

    var alignsLabelWithCardContentLeading: Bool { true }
    var keepsControlColumnStable: Bool { true }
}

func labeledVerticalControlRow(title: String, control: NSView) -> NSStackView {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 12)
    label.textColor = .secondaryLabelColor
    label.alignment = .left
    label.widthAnchor.constraint(
        equalToConstant: CGFloat(SettingsFormRowLayout.labelColumnWidth)
    ).isActive = true

    control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    control.widthAnchor.constraint(
        equalToConstant: CGFloat(SettingsFormRowLayout.controlColumnWidth)
    ).isActive = true

    let row = NSStackView(views: [label, control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = CGFloat(SettingsFormRowLayout.controlColumnSpacing)
    row.distribution = .fill
    row.widthAnchor.constraint(
        equalToConstant: CGFloat(SettingsFormRowLayout.contentWidth)
    ).isActive = true
    return row
}

struct SettingsTrailingAccessoryRowLayout: Equatable {
    static let contentWidth = SettingsFormRowLayout.contentWidth
    static let labelColumnWidth = SettingsFormRowLayout.labelColumnWidth
    static let columnSpacing = SettingsFormRowLayout.controlColumnSpacing
    static let controlColumnWidth = SettingsFormRowLayout.controlColumnWidth
    static let controlAccessorySpacing: Double = 10

    var usesSingleControlColumn: Bool { true }
    var leadingControlExpandsInsideColumn: Bool { true }
    var trailingAccessoryIsPinnedInsideColumn: Bool { true }
    var fixesLeadingControlWidth: Bool { false }
}

func labeledTrailingAccessoryControlRow(
    title: String,
    control: NSView,
    accessory: NSView
) -> NSStackView {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 12)
    label.textColor = .secondaryLabelColor
    label.alignment = .left
    label.widthAnchor.constraint(
        equalToConstant: CGFloat(SettingsTrailingAccessoryRowLayout.labelColumnWidth)
    ).isActive = true

    control.setContentHuggingPriority(.defaultLow, for: .horizontal)
    control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    accessory.setContentHuggingPriority(.required, for: .horizontal)
    accessory.setContentCompressionResistancePriority(.required, for: .horizontal)

    let controlColumn = NSStackView(views: [control, accessory])
    controlColumn.orientation = .horizontal
    controlColumn.alignment = .centerY
    controlColumn.spacing = CGFloat(SettingsTrailingAccessoryRowLayout.controlAccessorySpacing)
    controlColumn.distribution = .fill
    controlColumn.widthAnchor.constraint(
        equalToConstant: CGFloat(SettingsTrailingAccessoryRowLayout.controlColumnWidth)
    ).isActive = true

    let row = NSStackView(views: [label, controlColumn])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = CGFloat(SettingsTrailingAccessoryRowLayout.columnSpacing)
    row.distribution = .fill
    row.widthAnchor.constraint(
        equalToConstant: CGFloat(SettingsTrailingAccessoryRowLayout.contentWidth)
    ).isActive = true
    return row
}

struct SettingsMappingListLayout: Equatable {
    let displayCount: Int

    static let title = "对端输入源"
    static let labelColumnWidth = SettingsFormRowLayout.labelColumnWidth
    static let listColumnWidth = SettingsFormRowLayout.controlColumnWidth

    var usesTwoColumnRow: Bool { true }
    var centersTitleAgainstListContainer: Bool { true }
    var usesManualVerticalOffset: Bool { false }
    var showsEmptyState: Bool { displayCount == 0 }

    static func collaboration(displayCount: Int) -> SettingsMappingListLayout {
        SettingsMappingListLayout(displayCount: displayCount)
    }

    static func usb(displayCount: Int) -> SettingsMappingListLayout {
        SettingsMappingListLayout(displayCount: displayCount)
    }
}

enum SettingsSaveStatusColorRole: Equatable {
    case systemGreen
    case systemRed
}

enum SettingsSaveStatusHorizontalAlignment: Equatable {
    case leading
}

struct SettingsSaveStatusPresentation: Equatable {
    enum Placement: Equatable {
        case nonScrollingWindowFooter
    }

    let text: String
    let symbolName: String
    let textColor: SettingsSaveStatusColorRole
    let iconColor: SettingsSaveStatusColorRole
    let accessibilityLabel: String
    let accessibilityValue: String

    static let rowID = "settings-save-status"
    static let rowTitle = "即时保存状态"
    static let placement = Placement.nonScrollingWindowFooter
    static let isNonScrollingWindowFooter = true
    static let isInsideScrollDocument = false
    static let isAnchoredToWindowBottom = true
    static let isInDetailsCard = false
    static let horizontalAlignment = SettingsSaveStatusHorizontalAlignment.leading
    static let successVisibilityDuration: TimeInterval = 2

    static var saved: SettingsSaveStatusPresentation {
        saved(scope: .collaboration)
    }

    static func saved(scope: SettingsSaveFeedbackScope) -> SettingsSaveStatusPresentation {
        SettingsSaveStatusPresentation(
            text: "已保存",
            symbolName: "checkmark.circle.fill",
            textColor: .systemGreen,
            iconColor: .systemGreen,
            accessibilityLabel: scope.accessibilityLabel,
            accessibilityValue: "已保存"
        )
    }

    static var failedRestored: SettingsSaveStatusPresentation {
        failedRestored(scope: .collaboration)
    }

    static func failedRestored(scope: SettingsSaveFeedbackScope) -> SettingsSaveStatusPresentation {
        SettingsSaveStatusPresentation(
            text: "保存失败，已恢复",
            symbolName: "exclamationmark.circle.fill",
            textColor: .systemRed,
            iconColor: .systemRed,
            accessibilityLabel: scope.accessibilityLabel,
            accessibilityValue: "保存失败，已恢复"
        )
    }
}

enum SettingsSaveFeedbackState: Equatable {
    case hidden
    case visible(SettingsSaveStatusPresentation)
}

enum SettingsSaveFeedbackScope: Equatable, Hashable, CaseIterable {
    case none
    case usb
    case collaboration

    static var allCases: [SettingsSaveFeedbackScope] { [.usb, .collaboration] }

    var accessibilityLabel: String {
        switch self {
        case .none: return "配置保存状态"
        case .usb: return "USB 配置保存状态"
        case .collaboration: return "协同配置保存状态"
        }
    }
}

enum SettingsPersistenceResult: Equatable {
    case succeeded
    case failed
}

enum SettingsPersistenceFeedbackPolicy {
    static func hasActualChange<Value: Equatable>(from original: Value, to updated: Value) -> Bool {
        original != updated
    }
}

protocol SettingsSaveFeedbackScheduledTask: AnyObject {
    func cancel()
}

protocol SettingsSaveFeedbackScheduling {
    @discardableResult
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping () -> Void
    ) -> SettingsSaveFeedbackScheduledTask
}

private final class DispatchSettingsSaveFeedbackTask: SettingsSaveFeedbackScheduledTask {
    let workItem: DispatchWorkItem

    init(action: @escaping () -> Void) {
        workItem = DispatchWorkItem(block: action)
    }

    func cancel() {
        workItem.cancel()
    }
}

struct DispatchSettingsSaveFeedbackScheduler: SettingsSaveFeedbackScheduling {
    let queue: DispatchQueue

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping () -> Void
    ) -> SettingsSaveFeedbackScheduledTask {
        let task = DispatchSettingsSaveFeedbackTask(action: action)
        queue.asyncAfter(deadline: .now() + delay, execute: task.workItem)
        return task
    }
}

final class SettingsSaveFeedbackController {
    private let scheduler: SettingsSaveFeedbackScheduling
    private let onStateChange: (SettingsSaveFeedbackScope, SettingsSaveFeedbackState) -> Void
    private var scheduledHides: [SettingsSaveFeedbackScope: SettingsSaveFeedbackScheduledTask] = [:]
    private var generations: [SettingsSaveFeedbackScope: UInt] = [:]
    private var states: [SettingsSaveFeedbackScope: SettingsSaveFeedbackState] = [:]

    init(
        scheduler: SettingsSaveFeedbackScheduling,
        onStateChange: @escaping (SettingsSaveFeedbackScope, SettingsSaveFeedbackState) -> Void = { _, _ in }
    ) {
        self.scheduler = scheduler
        self.onStateChange = onStateChange
    }

    deinit {
        scheduledHides.values.forEach { $0.cancel() }
    }

    func reset() {
        SettingsSaveFeedbackScope.allCases.forEach { reset(scope: $0) }
    }

    func state(for scope: SettingsSaveFeedbackScope) -> SettingsSaveFeedbackState {
        states[scope] ?? .hidden
    }

    var state: SettingsSaveFeedbackState {
        state(for: .collaboration)
    }

    func dismissTransientSuccess() {
        dismissTransientSuccess(scope: .collaboration)
    }

    func dismissTransientSuccess(scope: SettingsSaveFeedbackScope) {
        guard state(for: scope) == .visible(.saved(scope: scope)) else { return }
        reset(scope: scope)
    }

    func recordPersistenceResult(
        _ result: SettingsPersistenceResult,
        scope: SettingsSaveFeedbackScope
    ) {
        guard scope != .none else { return }
        switch result {
        case .succeeded: recordSaveSucceeded(scope: scope)
        case .failed: recordSaveFailed(scope: scope)
        }
    }

    private func reset(scope: SettingsSaveFeedbackScope) {
        generations[scope, default: 0] &+= 1
        scheduledHides.removeValue(forKey: scope)?.cancel()
        transition(scope: scope, to: .hidden)
    }

    private func recordSaveSucceeded(scope: SettingsSaveFeedbackScope) {
        generations[scope, default: 0] &+= 1
        let currentGeneration = generations[scope, default: 0]
        scheduledHides.removeValue(forKey: scope)?.cancel()
        transition(scope: scope, to: .visible(.saved(scope: scope)))
        scheduledHides[scope] = scheduler.schedule(
            after: SettingsSaveStatusPresentation.successVisibilityDuration
        ) { [weak self] in
            guard let self, self.generations[scope] == currentGeneration else { return }
            self.scheduledHides.removeValue(forKey: scope)
            self.transition(scope: scope, to: .hidden)
        }
    }

    private func recordSaveFailed(scope: SettingsSaveFeedbackScope) {
        generations[scope, default: 0] &+= 1
        scheduledHides.removeValue(forKey: scope)?.cancel()
        transition(scope: scope, to: .visible(.failedRestored(scope: scope)))
    }

    private func transition(scope: SettingsSaveFeedbackScope, to newState: SettingsSaveFeedbackState) {
        states[scope] = newState
        onStateChange(scope, newState)
    }
}

enum SettingsHorizontalRowAlignment: Equatable {
    case splitByFlexibleGap
    case expandingLeadingControl

    var pinsTrailingControlToCardEdge: Bool { true }
    var usesFlexibleGap: Bool { self == .splitByFlexibleGap }
    var expandsLeadingControl: Bool { self == .expandingLeadingControl }
}

struct SettingsPageLayoutProjection: Equatable {
    static let tabLabels = ["常规", "USB 切换", "协同", "显示器", "诊断", "关于"]

    enum GroupID: String, Equatable {
        case usbAutomation
        case usbCollaboration
        case collaborationStatus
        case collaborationConfiguration

        var title: String {
            switch self {
            case .usbAutomation: return "自动切换"
            case .usbCollaboration: return "联动协同"
            case .collaborationStatus: return "协同状态"
            case .collaborationConfiguration: return "配置"
            }
        }
    }

    struct Row: Equatable {
        enum Kind: Equatable {
            case content
            case separator
        }

        let id: String
        let title: String
        let action: SettingsPageLayoutAction?
        let isVisible: Bool
        let isEnabled: Bool
        let kind: Kind

        init(
            id: String,
            title: String,
            action: SettingsPageLayoutAction?,
            isVisible: Bool,
            isEnabled: Bool,
            kind: Kind = .content
        ) {
            self.id = id
            self.title = title
            self.action = action
            self.isVisible = isVisible
            self.isEnabled = isEnabled
            self.kind = kind
        }

        static func separator(id: String, isVisible: Bool = true) -> Row {
            Row(
                id: id,
                title: "",
                action: nil,
                isVisible: isVisible,
                isEnabled: false,
                kind: .separator
            )
        }
    }

    struct Group: Equatable {
        let id: GroupID
        let rows: [Row]
    }

    let groups: [Group]
    let scrollContentFooterRows: [Row]
    let windowFooterRows: [Row]

    init(
        groups: [Group],
        scrollContentFooterRows: [Row] = [],
        windowFooterRows: [Row] = []
    ) {
        self.groups = groups
        self.scrollContentFooterRows = scrollContentFooterRows
        self.windowFooterRows = windowFooterRows
    }

    static func usb(
        displays: [DisplayConfigurationV4Display],
        learningInProgress: Bool,
        saveFeedbackState: SettingsSaveFeedbackState = .hidden
    ) -> SettingsPageLayoutProjection {
        let mappings = DisplayInputMappingPresentation.rows(displays: displays, context: .usb)
        let mappingRows = mappings.map {
            Row(
                id: "usb-mapping-\($0.displayID)", title: $0.title,
                action: .editValue, isVisible: true, isEnabled: true
            )
        }
        let isSaveFeedbackVisible: Bool
        switch saveFeedbackState {
        case .hidden: isSaveFeedbackVisible = false
        case .visible: isSaveFeedbackVisible = true
        }
        return SettingsPageLayoutProjection(groups: [
            Group(id: .usbAutomation, rows: [
                Row(id: "usb-automatic-switch", title: "自动切换", action: .toggleUSBAutomation,
                    isVisible: true, isEnabled: true),
                .separator(id: "usb-automation-controls-separator"),
                Row(id: "usb-trigger-device", title: "触发设备", action: .learnUSBDevice,
                    isVisible: true, isEnabled: !learningInProgress),
                Row(id: "usb-connection-status", title: "当前状态", action: nil,
                    isVisible: true, isEnabled: true),
                .separator(id: "usb-peer-inputs-separator")
            ] + (mappingRows.isEmpty ? [
                Row(id: "usb-mapping-empty", title: "尚未检测到显示器", action: nil,
                    isVisible: true, isEnabled: false)
            ] : mappingRows)),
            Group(id: .usbCollaboration, rows: [
                Row(id: "usb-collaboration-target", title: "联动目标",
                    action: .selectUSBWakeProfile, isVisible: true, isEnabled: true),
                Row(id: "usb-collaboration-toggle", title: "联动协同",
                    action: .toggleUSBWake, isVisible: true, isEnabled: true)
            ])
        ], windowFooterRows: [
            Row(id: SettingsSaveStatusPresentation.rowID,
                title: SettingsSaveStatusPresentation.rowTitle, action: nil,
                isVisible: isSaveFeedbackVisible, isEnabled: false)
        ])
    }

    static func collaboration(
        displays: [DisplayConfigurationV4Display],
        hasSelectedProfile: Bool,
        profileCount: Int,
        selectedProfileIndex: Int,
        inspectionInProgress: Bool,
        saveFeedbackState: SettingsSaveFeedbackState = .hidden
    ) -> SettingsPageLayoutProjection {
        let mappings = DisplayInputMappingPresentation.rows(
            displays: displays, context: .collaboration
        )
        let mappingRows = mappings.map {
            Row(
                id: "collaboration-mapping-\($0.displayID)", title: $0.title,
                action: .editValue, isVisible: hasSelectedProfile, isEnabled: hasSelectedProfile
            )
        }
        let details = [
            Row(id: "collaboration-selector", title: "当前配置",
                action: .selectCollaborationProfile, isVisible: true,
                isEnabled: hasSelectedProfile),
            Row(id: "collaboration-add", title: "添加配置",
                action: .addCollaborationProfile, isVisible: true, isEnabled: true),
            .separator(
                id: "collaboration-selection-details-separator",
                isVisible: hasSelectedProfile
            ),
            Row(id: "collaboration-name", title: "配置名称", action: .editValue,
                isVisible: hasSelectedProfile, isEnabled: hasSelectedProfile),
            Row(id: "collaboration-enabled", title: "启用此配置",
                action: .toggleCollaborationProfile,
                isVisible: hasSelectedProfile, isEnabled: hasSelectedProfile),
            Row(id: "collaboration-host", title: "对端地址", action: .editValue,
                isVisible: hasSelectedProfile, isEnabled: hasSelectedProfile),
            Row(id: "collaboration-port", title: "端口", action: .editValue,
                isVisible: hasSelectedProfile, isEnabled: hasSelectedProfile),
            Row(id: "collaboration-pairing-code", title: "配对密码", action: .editValue,
                isVisible: hasSelectedProfile, isEnabled: hasSelectedProfile),
            .separator(
                id: "collaboration-peer-inputs-separator",
                isVisible: hasSelectedProfile
            )
        ] + (mappingRows.isEmpty ? [
            Row(id: "collaboration-mapping-empty", title: "尚未检测到显示器", action: nil,
                isVisible: hasSelectedProfile, isEnabled: false)
        ] : mappingRows) + [
            Row(id: "collaboration-trigger-reference", title: "本机触发设备", action: nil,
                isVisible: hasSelectedProfile, isEnabled: false),
            .separator(
                id: "collaboration-actions-separator",
                isVisible: hasSelectedProfile
            ),
            Row(id: "collaboration-delete", title: "删除配置",
                action: .deleteCollaborationProfile,
                isVisible: hasSelectedProfile, isEnabled: profileCount > 1)
        ]
        let isSaveFeedbackVisible: Bool
        switch saveFeedbackState {
        case .hidden: isSaveFeedbackVisible = false
        case .visible: isSaveFeedbackVisible = true
        }
        return SettingsPageLayoutProjection(groups: [
            Group(id: .collaborationStatus, rows: [
                Row(id: "collaboration-status", title: "协同状态", action: nil,
                    isVisible: true, isEnabled: false),
                Row(id: "collaboration-permission", title: "检查网络权限",
                    action: .requestLocalNetworkPermission, isVisible: true,
                    isEnabled: hasSelectedProfile && !inspectionInProgress),
                Row(id: "collaboration-inspection", title: "检测连接",
                    action: .inspectCollaboration, isVisible: true,
                    isEnabled: hasSelectedProfile && !inspectionInProgress)
            ]),
            Group(id: .collaborationConfiguration, rows: details)
        ], windowFooterRows: [
            Row(id: SettingsSaveStatusPresentation.rowID,
                title: SettingsSaveStatusPresentation.rowTitle, action: nil,
                isVisible: hasSelectedProfile && isSaveFeedbackVisible, isEnabled: false)
        ])
    }
}

enum DisplayInputMappingPresentation {
    enum Context {
        case usb
        case collaboration
    }

    struct Row: Equatable {
        let displayID: String
        let title: String
    }

    static func usbTitle(displayName: String) -> String {
        displayName
    }

    static func collaborationTitle(displayName: String) -> String {
        displayName
    }

    static func rows(
        displays: [DisplayConfigurationV4Display],
        context: Context
    ) -> [Row] {
        var seen = Set<String>()
        return displays.compactMap { display in
            let key = display.id.lowercased()
            guard seen.insert(key).inserted else { return nil }
            let title: String
            switch context {
            case .usb:
                title = usbTitle(displayName: display.name)
            case .collaboration:
                title = collaborationTitle(displayName: display.name)
            }
            return Row(displayID: key, title: title)
        }
    }
}
