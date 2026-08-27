import Foundation

enum DDCCommand: UInt8 {
    case luminance = 0x10
    case contrast = 0x12
    case input = 0x60
    case volume = 0x62

    var m1ddcName: String {
        switch self {
        case .luminance: return "luminance"
        case .contrast: return "contrast"
        case .input: return "input"
        case .volume: return "volume"
        }
    }
}

struct DDCReading {
    let current: Int
    let maximum: Int
}

final class DDCController {
    private let native: NativeDDCBackend

    init() {
        // Configuration loading is owned by AppDelegate so a failed migration can
        // enter safe mode before this backend is allowed to enumerate or control hardware.
        native = NativeDDCBackend(knownDisplays: [])
    }

    /// Pure capability hint used by settings validation. It does not enumerate displays or issue DDC traffic.
    static var hasLocalBackendWithoutHardwareAccess: Bool {
#if arch(arm64)
        return true
#else
        return hasM1DDC
#endif
    }

    func detectDisplays(existingConfigurations: [DisplayConfiguration]) throws -> [DetectedDisplay] {
        let knownDisplays = Self.knownDisplays(from: existingConfigurations)
        native.updateKnownDisplays(knownDisplays)
        let nativeDisplays = native.discover()
        if !nativeDisplays.isEmpty || !Self.hasM1DDC {
            guard !nativeDisplays.isEmpty else { throw DDCError.detectionFailed }
            let rank = Dictionary(uniqueKeysWithValues: knownDisplays.enumerated().map {
                ($0.element.systemUUID.uppercased(), $0.offset)
            })
            let ordered = nativeDisplays.enumerated().sorted { lhs, rhs in
                let lhsRank = rank[lhs.element.systemUUID.uppercased()] ?? (knownDisplays.count + lhs.offset)
                let rhsRank = rank[rhs.element.systemUUID.uppercased()] ?? (knownDisplays.count + rhs.offset)
                return lhsRank < rhsRank
            }.map(\.element)
            return ordered.enumerated().map { offset, display in
                DetectedDisplay(
                    index: offset + 1,
                    name: display.name,
                    systemUUID: display.systemUUID
                )
            }
        }

        let output = try Self.runM1DDC(arguments: ["display", "list", "detailed"])
        let detected = DetectedDisplay.parseList(output)
        guard !detected.isEmpty else { throw DDCError.detectionFailed }
        return detected
    }

    func updateConfigurations(_ configurations: [DisplayConfiguration]) {
        native.updateKnownDisplays(Self.knownDisplays(from: configurations))
    }

    func read(selector: String, command: DDCCommand) -> DDCReading? {
        if native.hasDisplay(selector: selector) {
            guard let value = native.read(selector: selector, command: command.rawValue) else {
                return nil
            }
            return DDCReading(current: value.current, maximum: value.maximum)
        }

        for attempt in 0..<2 {
            if Self.hasM1DDC,
               let current = Self.readM1DDC(selector: selector, operation: "get", command: command),
               let maximum = Self.readM1DDC(selector: selector, operation: "max", command: command)
            {
                return DDCReading(current: current, maximum: maximum)
            }

            if attempt == 0 { Thread.sleep(forTimeInterval: 0.08) }
        }
        return nil
    }

    func write(selector: String, command: DDCCommand, value: Int) throws {
        guard let nativeValue = UInt16(exactly: value) else {
            throw DDCError.invalidValue(value)
        }

        switch native.write(selector: selector, command: command.rawValue, value: nativeValue) {
        case .success:
            return
        case .unavailable, .failed:
            break
        }

        guard Self.hasM1DDC else {
            throw DDCError.nativeWriteFailed(command: command, value: value)
        }
        _ = try Self.runM1DDC(arguments: [
            "display", selector, "set", command.m1ddcName, "\(value)"
        ])
    }

    private static var m1ddcPath: String? {
        ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var hasM1DDC: Bool { m1ddcPath != nil }

    private static func knownDisplays(
        from configurations: [DisplayConfiguration]
    ) -> [NativeDDCKnownDisplay] {
        configurations.map {
            NativeDDCKnownDisplay(name: $0.name, systemUUID: $0.selector)
        }
    }

    private static func readM1DDC(
        selector: String,
        operation: String,
        command: DDCCommand
    ) -> Int? {
        guard
            let output = try? runM1DDC(arguments: [
                "display", selector, operation, command.m1ddcName
            ]),
            let value = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)),
            value >= 0
        else {
            return nil
        }
        return value
    }

    private static func runM1DDC(arguments: [String]) throws -> String {
        guard let path = m1ddcPath else { throw DDCError.m1ddcUnavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
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
}

enum DDCError: LocalizedError {
    case commandFailed(arguments: [String], status: Int32, detail: String?)
    case detectionFailed
    case invalidValue(Int)
    case inputNotConfigured(displayName: String)
    case m1ddcUnavailable
    case nativeWriteFailed(command: DDCCommand, value: Int)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(arguments, status, detail):
            let command = (["m1ddc"] + arguments).joined(separator: " ")
            let suffix = detail.map { "\n\n\($0)" } ?? ""
            return "命令执行失败（退出码 \(status)）：\n\(command)\(suffix)"
        case .detectionFailed:
            return "原生 DDC 和 m1ddc 都没有返回可用的外接显示器。"
        case let .invalidValue(value):
            return "DDC 数值超出有效范围：\(value)"
        case let .inputNotConfigured(displayName):
            return "\(displayName) 尚未配置 Mac/Windows 输入源，未执行切屏。"
        case .m1ddcUnavailable:
            return "原生 DDC 不可用，且未安装 m1ddc 回退后端。"
        case let .nativeWriteFailed(command, value):
            return "原生 DDC 写入失败：VCP 0x\(String(format: "%02X", command.rawValue)) = \(value)。"
        }
    }
}
