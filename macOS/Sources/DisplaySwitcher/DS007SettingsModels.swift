import Foundation

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
    static func trayCommands(for display: DisplayConfigurationV4Display) -> Set<DDCCommand> {
        var result = Set<DDCCommand>()
        if display.brightnessEnabled && display.brightnessShowInTray { result.insert(.luminance) }
        if display.contrastEnabled && display.contrastShowInTray { result.insert(.contrast) }
        if display.volumeEnabled && display.volumeShowInTray { result.insert(.volume) }
        return result
    }
}
