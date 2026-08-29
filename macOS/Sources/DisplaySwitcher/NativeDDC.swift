// Native Apple Silicon DDC/CI transport.
// Discovery and I2C packet handling are derived from AppleSiliconDDC:
// https://github.com/waydabber/AppleSiliconDDC
// Copyright (c) 2021 Istvan T., used under the MIT License.
// MonitorControl uses a different read offset (0 instead of 0x51); DS-009 keeps
// the offset explicit and testable rather than probing both values on hardware.

import CoreGraphics
import Foundation
import IOKit

struct NativeDDCDisplay {
    let name: String
    let systemUUID: String
    let serviceLocation: Int
    let service: IOAVService?
    let chipAddress: UInt32
    let transportPath: NativeDDCTransportPath
    let isOnline: Bool
}

private struct NativeRegistryTransport {
    let metadata: NativeTransportCandidate
    let service: IOAVService
    let chipAddress: UInt32
}

final class NativeDDCBackend: DDCBackend {
    let identifier = "apple-silicon-native"
    let capabilities = DDCBackendCapabilities(canEnumerate: true, canReadVCP: true, canWriteVCP: true)
    private var knownDisplays: [DDCKnownDisplay]
    private let cacheLock = NSLock()
    private let transportLocksLock = NSLock()
    private let diagnosticsLock = NSLock()
    private var transportLocks: [String: NSLock] = [:]
    private var displaysByUUID: [String: NativeDDCDisplay] = [:]
    private var diagnosticsBySelector: [String: NativeDDCDiagnosticSnapshot] = [:]
    private let transportParameters: NativeDDCTransportParameters

    init(knownDisplays: [DDCKnownDisplay] = [],
         transportParameters: NativeDDCTransportParameters = .appleSiliconDDCCompatible) {
        self.knownDisplays = knownDisplays
        self.transportParameters = transportParameters
    }

    var availability: DDCBackendAvailability {
#if arch(arm64)
        return .available
#else
        return .unavailable("Apple Silicon 原生 DDC 在 Intel Mac 上不可用")
#endif
    }

    func updateKnownDisplays(_ values: [DDCKnownDisplay]) {
        cacheLock.lock()
        knownDisplays = values
        cacheLock.unlock()
    }

    private func discover() -> [NativeDDCDisplay] {
        #if arch(arm64)
        cacheLock.lock()
        let knownDisplays = self.knownDisplays
        cacheLock.unlock()
        let displays = Self.discoverDisplays(knownDisplays: knownDisplays)
        cacheLock.lock()
        displaysByUUID = Dictionary(uniqueKeysWithValues: displays.map { ($0.systemUUID.uppercased(), $0) })
        cacheLock.unlock()
        for display in displays {
            recordDiagnostic(
                selector: display.systemUUID,
                path: display.transportPath,
                serviceMatched: display.service != nil,
                category: display.service == nil ? .serviceUnmatched : .idle
            )
        }
        return displays
        #else
        return []
        #endif
    }

    func enumerateDisplays(token: DDCCancellationToken) throws -> [DDCBackendDisplay] {
        try token.throwIfCancelled()
        guard availability == .available else { throw DDCBackendError.unavailable(backend: identifier) }
        let displays = discover()
        try token.throwIfCancelled()
        cacheLock.lock()
        let known = knownDisplays
        cacheLock.unlock()
        return displays.map { display in
            let stableID = known.first { knownDisplay in
                knownDisplay.selector.caseInsensitiveCompare(display.systemUUID) == .orderedSame
            }?.stableID ?? display.systemUUID
            return DDCBackendDisplay(stableID: stableID, name: display.name, selector: display.systemUUID)
        }
    }

    func read(stableID: String, selector: String, command: DDCCommand,
              token: DDCCancellationToken) throws -> DDCReading {
        let transportLock = lock(for: selector)
        transportLock.lock()
        defer { transportLock.unlock() }
        try token.throwIfCancelled()
        var resolved: DDCReading?
        try DDCSingleRetry.perform(operation: {
            try token.throwIfCancelled()
            guard let display = display(for: selector) else {
                recordDiagnostic(selector: selector, path: .unmatched, serviceMatched: false,
                                 category: .serviceUnmatched)
                throw DDCBackendError.displayUnavailable(stableID: stableID)
            }
            guard display.isOnline, let service = display.service else {
                recordDiagnostic(selector: selector, path: display.transportPath, serviceMatched: false,
                                 category: .serviceUnmatched)
                throw DDCBackendError.displayUnavailable(stableID: stableID)
            }
            switch Self.read(
                service: service,
                chipAddress: display.chipAddress,
                command: command,
                transportPath: display.transportPath,
                parameters: transportParameters
            ) {
            case .success(let reading):
                try token.throwIfCancelled()
                resolved = reading
                recordDiagnostic(selector: selector, path: display.transportPath, serviceMatched: true,
                                 category: .readSucceeded)
            case .failure(let issue):
                recordDiagnostic(
                    selector: selector, path: display.transportPath, serviceMatched: true,
                    category: diagnosticCategory(for: issue)
                )
                throw DDCBackendError.invalidReply(command: command, issue: issue)
            }
        }, recover: {
            try token.throwIfCancelled()
            incrementRebuild(selector: selector)
            invalidate(selector: selector)
            _ = discover()
        })
        guard let resolved else { throw DDCBackendError.readFailed(stableID: stableID, command: command) }
        return resolved
    }

    func write(stableID: String, selector: String, command: DDCCommand, value: Int,
               token: DDCCancellationToken) throws {
        let transportLock = lock(for: selector)
        transportLock.lock()
        defer { transportLock.unlock() }
        try token.throwIfCancelled()
        guard let nativeValue = UInt16(exactly: value) else { throw DDCError.invalidValue(value) }
        try DDCSingleRetry.perform(operation: {
            try token.throwIfCancelled()
            let candidate = display(for: selector)
            guard let display = candidate, let service = display.service else {
                let path = candidate?.transportPath ?? .unmatched
                recordDiagnostic(selector: selector, path: path, serviceMatched: false,
                                 category: .serviceUnmatched)
                throw DDCBackendError.displayUnavailable(stableID: stableID)
            }
            guard Self.write(
                service: service, chipAddress: display.chipAddress,
                command: command.rawValue, value: nativeValue,
                parameters: transportParameters
            ) else {
                recordDiagnostic(selector: selector, path: display.transportPath, serviceMatched: true,
                                 category: .writeTransportFailed)
                throw DDCBackendError.writeFailed(stableID: stableID, command: command)
            }
            try token.throwIfCancelled()
            recordDiagnostic(selector: selector, path: display.transportPath, serviceMatched: true,
                             category: .writeSucceeded)
        }, recover: {
            try token.throwIfCancelled()
            incrementRebuild(selector: selector)
            invalidate(selector: selector)
            _ = discover()
        })
    }

    func cancelAll() {
        cacheLock.lock()
        displaysByUUID.removeAll()
        cacheLock.unlock()
    }

    func diagnostic(selector: String) -> NativeDDCDiagnosticSnapshot? {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return diagnosticsBySelector[selector.uppercased()]
    }

    private func recordDiagnostic(selector: String, path: NativeDDCTransportPath,
                                  serviceMatched: Bool, category: NativeDDCOperationCategory) {
        let key = selector.uppercased()
        diagnosticsLock.lock()
        let rebuildCount = diagnosticsBySelector[key]?.rebuildCount ?? 0
        diagnosticsBySelector[key] = NativeDDCDiagnosticSnapshot(
            transportPath: path, serviceMatched: serviceMatched,
            operationCategory: category, rebuildCount: rebuildCount
        )
        diagnosticsLock.unlock()
    }

    private func incrementRebuild(selector: String) {
        let key = selector.uppercased()
        diagnosticsLock.lock()
        let current = diagnosticsBySelector[key] ?? NativeDDCDiagnosticSnapshot(
            transportPath: .unmatched, serviceMatched: false,
            operationCategory: .serviceUnmatched, rebuildCount: 0
        )
        diagnosticsBySelector[key] = NativeDDCDiagnosticSnapshot(
            transportPath: current.transportPath, serviceMatched: current.serviceMatched,
            operationCategory: current.operationCategory, rebuildCount: current.rebuildCount + 1
        )
        diagnosticsLock.unlock()
    }

    private func diagnosticCategory(for issue: NativeDDCReplyIssue) -> NativeDDCOperationCategory {
        switch issue {
        case .requestWriteFailed: return .readRequestWriteFailed
        case .responseTimeout: return .readResponseTimeout
        case .responseReadFailed: return .readResponseFailed
        default: return .readReplyRejected
        }
    }

    private func lock(for selector: String) -> NSLock {
        let key = selector.uppercased()
        transportLocksLock.lock()
        defer { transportLocksLock.unlock() }
        if let existing = transportLocks[key] { return existing }
        let created = NSLock()
        transportLocks[key] = created
        return created
    }

    private func invalidate(selector: String) {
        cacheLock.lock()
        displaysByUUID.removeValue(forKey: selector.uppercased())
        cacheLock.unlock()
    }

    private func display(for selector: String) -> NativeDDCDisplay? {
        let key = selector.uppercased()
        cacheLock.lock()
        var display = displaysByUUID[key]
        cacheLock.unlock()

        if display == nil {
            _ = discover()
            cacheLock.lock()
            display = displaysByUUID[key]
            cacheLock.unlock()
        }
        return display
    }

    private static func discoverDisplays(
        knownDisplays: [DDCKnownDisplay]
    ) -> [NativeDDCDisplay] {
        let identities = onlineExternalDisplayIDs().compactMap(displayInfo(for:))
        let transports = registryTransports()
        let matches = NativeDisplayMatcher.matches(
            identities: identities.map {
                NativeDisplayIdentity(
                    stableID: $0.systemUUID,
                    ioDisplayLocation: $0.ioLocation,
                    productName: $0.productName,
                    serialNumber: $0.serialNumber,
                    edidSearchKeys: $0.edidSearchKeys
                )
            },
            candidates: transports.map(\.metadata)
        )
        let transportByLocation = Dictionary(uniqueKeysWithValues: transports.map {
            ($0.metadata.serviceLocation, $0)
        })
        let knownBySelector = Dictionary(uniqueKeysWithValues: knownDisplays.map {
            ($0.selector.uppercased(), $0)
        })
        return identities.map { identity in
            let transport = matches[identity.systemUUID].flatMap { transportByLocation[$0] }
            let savedName = knownBySelector[identity.systemUUID.uppercased()]?.name ?? ""
            let name = !identity.productName.isEmpty ? identity.productName
                : (!savedName.isEmpty ? savedName : "外接显示器")
            return NativeDDCDisplay(
                name: name,
                systemUUID: identity.systemUUID,
                serviceLocation: transport?.metadata.serviceLocation ?? 0,
                service: transport?.service,
                chipAddress: transport?.chipAddress ?? 0x37,
                transportPath: transport?.metadata.transportPath ?? .unmatched,
                isOnline: true
            )
        }
    }

    private static func onlineExternalDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displayIDs, &count) == .success else { return [] }
        return Array(displayIDs.prefix(Int(count))).filter { CGDisplayIsBuiltin($0) == 0 }
    }

    private static func displayInfo(for displayID: CGDirectDisplayID) -> (
        systemUUID: String,
        ioLocation: String,
        productName: String,
        serialNumber: Int64,
        edidSearchKeys: [NativeEDIDSearchKey]
    )? {
        guard let dictionary = CoreDisplay_DisplayCreateInfoDictionary(displayID)?.takeRetainedValue()
            as? [String: Any] else { return nil }
        guard let uuid = dictionary["kCGDisplayUUID"] as? String,
              let ioLocation = dictionary["IODisplayLocation"] as? String else { return nil }
        let productNames = dictionary["DisplayProductName"] as? [String: String]
        let productName = productNames?["en_US"] ?? productNames?.values.first ?? ""
        let serialNumber = dictionary["DisplaySerialNumber"] as? Int64 ?? 0
        return (uuid.uppercased(), ioLocation, productName, serialNumber, edidSearchKeys(dictionary))
    }

    private static func edidSearchKeys(_ dictionary: [String: Any]) -> [NativeEDIDSearchKey] {
        let vendor = dictionary["DisplayVendorID"] as? Int64 ?? 0
        let product = dictionary["DisplayProductID"] as? Int64 ?? 0
        let week = dictionary["DisplayWeekManufacture"] as? Int64 ?? 0
        let year = dictionary["DisplayYearManufacture"] as? Int64 ?? 1990
        let horizontal = dictionary["DisplayHorizontalImageSize"] as? Int64 ?? 0
        let vertical = dictionary["DisplayVerticalImageSize"] as? Int64 ?? 0
        func hex16(_ value: Int64) -> String {
            String(format: "%04X", UInt16(clamping: value))
        }
        func hex8(_ value: Int64) -> String {
            String(format: "%02X", UInt8(clamping: value))
        }
        let productValue = UInt16(clamping: product)
        return [
            NativeEDIDSearchKey(value: hex16(vendor), offset: 0),
            NativeEDIDSearchKey(
                value: String(format: "%02X%02X", UInt8(productValue & 0xFF), UInt8(productValue >> 8)),
                offset: 4
            ),
            NativeEDIDSearchKey(value: hex8(week) + hex8(year - 1990), offset: 19),
            NativeEDIDSearchKey(value: hex8(horizontal / 10) + hex8(vertical / 10), offset: 30)
        ]
    }

    private static func productName(for adapter: io_registry_entry_t) -> String? {
        guard
            let attributes = property(entry: adapter, key: "DisplayAttributes") as? [String: Any],
            let product = attributes["ProductAttributes"] as? [String: Any]
        else { return nil }
        return product["ProductName"] as? String
    }

    private static func registryTransports() -> [NativeRegistryTransport] {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else { return [] }
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            root,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var transports: [NativeRegistryTransport] = []
        var currentFramebuffer: (
            ioDisplayLocation: String,
            productName: String,
            serialNumber: Int64,
            edidUUID: String,
            serviceLocation: Int
        )?
        var serviceLocation = 0
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(entry) }
            var rawName = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &rawName) == KERN_SUCCESS else { continue }
            let entryName = String(cString: rawName)
            let isFramebuffer = entryName.contains("AppleCLCD2")
                || entryName.contains("IOMobileFramebufferShim")
                || IOObjectConformsTo(entry, "IOMobileFramebuffer") != 0
            if isFramebuffer {
                serviceLocation += 1
                currentFramebuffer = (
                    ioDisplayLocation: registryPath(entry),
                    productName: productName(for: entry) ?? "",
                    serialNumber: productSerialNumber(for: entry),
                    edidUUID: property(entry: entry, key: "EDID UUID") as? String ?? "",
                    serviceLocation: serviceLocation
                )
                continue
            }
            guard
                entryName == "DCPAVServiceProxy",
                let currentFramebuffer,
                property(entry: entry, key: "Location") as? String == "External",
                let unmanagedService = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)
            else { continue }
            let transportPath = transportPath(for: entry)
            let isConverter = transportPath == .builtinHDMIConverter
            transports.append(NativeRegistryTransport(
                metadata: NativeTransportCandidate(
                    serviceLocation: currentFramebuffer.serviceLocation,
                    ioDisplayLocation: currentFramebuffer.ioDisplayLocation,
                    productName: currentFramebuffer.productName,
                    serialNumber: currentFramebuffer.serialNumber,
                    edidUUID: currentFramebuffer.edidUUID,
                    transportPath: transportPath
                ),
                service: unmanagedService.takeRetainedValue() as IOAVService,
                chipAddress: isConverter ? 0xB7 : 0x37
            ))
        }
        return transports
    }

    private static func transportPath(for proxy: io_registry_entry_t) -> NativeDDCTransportPath {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return .unknownExternal
        }
        defer { IOObjectRelease(parent) }
        let provider = property(entry: parent, key: "EPICProviderClass") as? String
        let descriptions = ["Transport", "TransportType", "ConnectionType"].compactMap { key in
            (property(entry: proxy, key: key) ?? property(entry: parent, key: key)) as? String
        }
        return NativeTransportPathClassifier.classify(
            epicProviderClass: provider,
            transportDescription: descriptions.joined(separator: " ")
        )
    }

    private static func registryPath(_ entry: io_registry_entry_t) -> String {
        var path = [CChar](repeating: 0, count: 1_024)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS else { return "" }
        return String(cString: path)
    }

    private static func productSerialNumber(for entry: io_registry_entry_t) -> Int64 {
        guard
            let attributes = property(entry: entry, key: "DisplayAttributes") as? [String: Any],
            let product = attributes["ProductAttributes"] as? [String: Any]
        else { return 0 }
        return product["SerialNumber"] as? Int64 ?? 0
    }

    private static func property(entry: io_registry_entry_t, key: String) -> Any? {
        IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        )?.takeRetainedValue()
    }

    private static func read(
        service: IOAVService,
        chipAddress: UInt32,
        command: DDCCommand,
        transportPath: NativeDDCTransportPath,
        parameters: NativeDDCTransportParameters
    ) -> Result<DDCReading, NativeDDCReplyIssue> {
        var request: [UInt8] = [command.rawValue]
        var lastIssue = NativeDDCReplyIssue.responseReadFailed
        for _ in 0..<parameters.readAttempts(for: transportPath) {
            // A fresh buffer prevents a failed retry from accepting bytes left by an
            // earlier command or a late response.
            var response = [UInt8](repeating: 0, count: 11)
            let exchange = communicate(
                service: service,
                chipAddress: chipAddress,
                request: &request,
                response: &response,
                attempts: 1,
                readDataAddress: parameters.readDataAddress(for: transportPath),
                readSleepMicroseconds: parameters.readSleepMicroseconds(for: transportPath),
                parameters: parameters
            )
            guard case .success = exchange else {
                if case .failure(let issue) = exchange { lastIssue = issue }
                continue
            }
            switch NativeDDCReplyValidator.reading(from: response, command: command) {
            case .success(let reading): return .success(reading)
            case .failure(let issue): lastIssue = issue
            }
        }
        return .failure(lastIssue)
    }

    private static func write(
        service: IOAVService,
        chipAddress: UInt32,
        command: UInt8,
        value: UInt16,
        parameters: NativeDDCTransportParameters
    ) -> Bool {
        var request: [UInt8] = [command, UInt8(value >> 8), UInt8(value & 0xff)]
        var response: [UInt8] = []
        switch communicate(
            service: service,
            chipAddress: chipAddress,
            request: &request,
            response: &response,
            attempts: parameters.writeAttempts,
            readDataAddress: nil,
            readSleepMicroseconds: nil,
            parameters: parameters
        ) {
        case .success: return true
        case .failure: return false
        }
    }

    private static func communicate(
        service: IOAVService,
        chipAddress: UInt32,
        request: inout [UInt8],
        response: inout [UInt8],
        attempts: Int,
        readDataAddress: UInt8?,
        readSleepMicroseconds: UInt32?,
        parameters: NativeDDCTransportParameters
    ) -> Result<Void, NativeDDCReplyIssue> {
        let dataAddress = parameters.writeDataAddress
        var packet = [UInt8(0x80 | (request.count + 1)), UInt8(request.count)] + request + [0]
        packet[packet.count - 1] = checksum(
            initial: request.count == 1 ? UInt8(truncatingIfNeeded: chipAddress << 1) : UInt8(truncatingIfNeeded: chipAddress << 1) ^ dataAddress,
            bytes: packet.dropLast()
        )

        for _ in 0..<attempts {
            let writeSucceeded = NativeDDCWriteCyclePolicy.perform(
                cycles: parameters.writeCycles
            ) {
                usleep(parameters.writeSleepMicroseconds)
                return IOAVServiceWriteI2C(
                    service,
                    chipAddress,
                    UInt32(dataAddress),
                    &packet,
                    UInt32(packet.count)
                ) == KERN_SUCCESS
            }

            if writeSucceeded, !response.isEmpty {
                usleep(readSleepMicroseconds ?? parameters.typeCDPReadSleepMicroseconds)
                let readResult = IOAVServiceReadI2C(
                    service,
                    chipAddress,
                    UInt32(readDataAddress ?? parameters.typeCDPReadDataAddress),
                    &response,
                    UInt32(response.count)
                )
                if readResult == kIOReturnTimeout || readResult == kIOReturnNotResponding {
                    return .failure(.responseTimeout)
                }
                if readResult != KERN_SUCCESS { return .failure(.responseReadFailed) }
            }

            if writeSucceeded { return .success(()) }
            usleep(parameters.retrySleepMicroseconds)
        }
        return .failure(.requestWriteFailed)
    }

    private static func checksum<S: Sequence>(initial: UInt8, bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(initial, ^)
    }
}
