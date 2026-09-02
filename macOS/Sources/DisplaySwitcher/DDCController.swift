import Foundation

final class DDCController {
    private let service: DDCControlService

    init() {
        let native = NativeDDCBackend(
            knownDisplays: [],
            detailedDiagnosticRecordingEnabled: {
                DetailedDiagnosticRecordingPreference.shared.isEnabled
            }
        )
        service = DDCControlService(
            router: DDCBackendRouter(backend: native),
            cache: UserDefaultsDDCValueCache()
        )
    }

    /// Pure capability hint used by settings validation. It does not enumerate displays or issue DDC traffic.
    static var hasLocalBackendWithoutHardwareAccess: Bool {
#if arch(arm64)
        return true
#else
        return false
#endif
    }

    static var backendSummaryWithoutHardwareAccess: String {
#if arch(arm64)
        return "Apple Silicon 原生 DDC"
#else
        return "Intel Mac 不支持 Apple Silicon 原生 DDC"
#endif
    }

    var availability: DDCBackendAvailability { service.availability }
    var capabilities: DDCBackendCapabilities { service.capabilities }

    func setOperationsAllowed(_ allowed: Bool) {
        service.setOperationsAllowed(allowed)
    }

    func cancelAll() {
        service.cancelAll()
    }

    func detectDisplays(existingConfigurations: [DisplayConfiguration]) throws -> [DetectedDisplay] {
        let known = Self.knownDisplays(from: existingConfigurations)
        service.updateKnownDisplays(known)
        let detected = try service.enumerateDisplays()
        let presentationNames = DisplayPresentationNameResolver.names(
            for: detected, knownDisplays: known
        )
        let rank = Dictionary(uniqueKeysWithValues: known.enumerated().map {
            ($0.element.stableID.lowercased(), $0.offset)
        })
        let ordered = detected.enumerated().sorted { lhs, rhs in
            let lhsRank = rank[lhs.element.stableID.lowercased()] ?? (known.count + lhs.offset)
            let rhsRank = rank[rhs.element.stableID.lowercased()] ?? (known.count + rhs.offset)
            return lhsRank < rhsRank
        }.map(\.element)
        return ordered.enumerated().map { offset, display in
            DetectedDisplay(
                index: offset + 1,
                name: presentationNames[display.stableID.lowercased()] ?? display.name,
                systemUUID: display.selector.uppercased()
            )
        }
    }

    func updateConfigurations(_ configurations: [DisplayConfiguration]) {
        service.updateKnownDisplays(Self.knownDisplays(from: configurations))
    }

    func read(targets: [DDCDisplayTarget]) -> DDCReadBatchResult {
        service.read(targets)
    }

    func write(command: DDCCommand, value: Int, targets: [DDCDisplayTarget]) -> [String: Error] {
        service.write(command: command, value: value, targets: targets)
    }

    func write(stableID: String, selector: String, command: DDCCommand, value: Int) throws {
        let target = DDCDisplayTarget(stableID: stableID, selector: selector,
                                      enabledCommands: [command])
        if let error = service.write(command: command, value: value, targets: [target])[stableID] {
            throw error
        }
    }

    func cachedValue(stableID: String, command: DDCCommand) -> Int? {
        service.cachedValue(stableID: stableID, command: command)
    }

    func diagnostic(selector: String) -> NativeDDCDiagnosticSnapshot? {
        service.diagnostic(selector: selector)
    }

    func clearDiagnostics() {
        service.clearDiagnostics()
    }

    private static func knownDisplays(from configurations: [DisplayConfiguration]) -> [DDCKnownDisplay] {
        configurations.map {
            DDCKnownDisplay(stableID: $0.id ?? $0.selector, name: $0.name, selector: $0.selector)
        }
    }
}

enum DDCError: LocalizedError {
    case detectionFailed
    case invalidValue(Int)
    case inputNotConfigured(displayName: String)
    case nativeWriteFailed(command: DDCCommand, value: Int)

    var errorDescription: String? {
        switch self {
        case .detectionFailed:
            return "Apple Silicon 原生 DDC 没有返回可用的外接显示器。"
        case let .invalidValue(value):
            return "DDC 数值超出有效范围：\(value)"
        case let .inputNotConfigured(displayName):
            return "\(displayName) 尚未配置输入源，未执行切屏。"
        case let .nativeWriteFailed(command, value):
            return "原生 DDC 写入失败：VCP 0x\(String(format: "%02X", command.rawValue)) = \(value)。"
        }
    }
}
