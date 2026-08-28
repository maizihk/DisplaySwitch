import Foundation

struct LocalUSBSwitchDisplay: Equatable {
    let displayID: String
    let targetInput: Int?
    let available: Bool
}

struct LocalUSBSwitchRuntimeConfiguration: Equatable {
    var enabled: Bool
    var learning: Bool
    var safeState: Bool
    var collaborationWakeEnabled: Bool
    var collaborationProfileValid: Bool
    var displays: [LocalUSBSwitchDisplay]
}

enum LocalUSBSwitchReportReason: String, Equatable {
    case missingMapping = "missing_mapping"
    case displayUnavailable = "display_unavailable"
    case ddcFailed = "ddc_failed"
    case wakeNotSent = "wake_not_sent"
}

protocol LocalUSBSwitchActionSink: AnyObject {
    func switchUSBDisplay(displayID: String, targetInput: Int, completion: @escaping (Bool) -> Void)
    func wakeUSBDisplay()
    func sendCollaborationWakeDisplay() -> Bool
    func reportUSBSwitch(displayID: String?, reason: LocalUSBSwitchReportReason)
}

final class LocalUSBSwitchCoordinator {
    static let wakeCoalescingWindowMs: Int64 = 2_000

    private weak var sink: LocalUSBSwitchActionSink?
    private let nowMs: () -> Int64
    private(set) var configuration: LocalUSBSwitchRuntimeConfiguration
    private(set) var baselinePresence: Bool?
    private var lastWakeAtMs: Int64?

    init(configuration: LocalUSBSwitchRuntimeConfiguration,
         baselinePresence: Bool? = nil,
         sink: LocalUSBSwitchActionSink,
         nowMs: @escaping () -> Int64) {
        self.configuration = configuration
        self.baselinePresence = baselinePresence
        self.sink = sink
        self.nowMs = nowMs
    }

    func updateConfiguration(_ configuration: LocalUSBSwitchRuntimeConfiguration) {
        self.configuration = configuration
        baselinePresence = nil
        lastWakeAtMs = nil
    }

    func configurationChanged() {
        baselinePresence = nil
        lastWakeAtMs = nil
    }

    @discardableResult
    func observeUSB(present: Bool) -> Bool {
        guard configuration.enabled, !configuration.learning, !configuration.safeState else { return false }
        guard let previous = baselinePresence else {
            baselinePresence = present
            return true
        }
        guard previous != present else { return false }
        baselinePresence = present
        if present {
            requestCoalescedWake()
        } else {
            scheduleDeparture()
        }
        return false
    }

    func receiveAuthenticatedWakeDisplay() {
        guard !configuration.safeState, !configuration.learning else { return }
        requestCoalescedWake()
    }

    private func scheduleDeparture() {
        guard let sink else { return }
        for display in configuration.displays {
            guard display.available else {
                sink.reportUSBSwitch(displayID: display.displayID, reason: .displayUnavailable)
                continue
            }
            guard let targetInput = display.targetInput else {
                sink.reportUSBSwitch(displayID: display.displayID, reason: .missingMapping)
                continue
            }
            sink.switchUSBDisplay(displayID: display.displayID, targetInput: targetInput) { [weak sink] success in
                if !success {
                    sink?.reportUSBSwitch(displayID: display.displayID, reason: .ddcFailed)
                }
            }
        }
        guard configuration.collaborationWakeEnabled else { return }
        guard configuration.collaborationProfileValid, sink.sendCollaborationWakeDisplay() else {
            sink.reportUSBSwitch(displayID: nil, reason: .wakeNotSent)
            return
        }
    }

    private func requestCoalescedWake() {
        let now = nowMs()
        if let lastWakeAtMs, now - lastWakeAtMs < Self.wakeCoalescingWindowMs { return }
        lastWakeAtMs = now
        sink?.wakeUSBDisplay()
    }
}
