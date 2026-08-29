// Native Apple Silicon DDC/CI transport.
// Discovery and I2C packet handling are derived from AppleSiliconDDC:
// https://github.com/waydabber/AppleSiliconDDC
// Copyright (c) 2021 Istvan T., used under the MIT License.
// MonitorControl uses a different read offset (0 instead of 0x51). DS-009 keeps
// both strategies explicit and bounded, and only falls back after a strict
// Type-C/DP read failure.

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
    private var readPreferenceCache = NativeDDCReadPreferenceCache()
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
                primaryDataAddress: preferredReadDataAddress(
                    selector: selector, path: display.transportPath
                ),
                token: token,
                parameters: transportParameters
            ) {
            case .success(let reading, let dataAddress, let attempts, let discardedEchoes):
                try token.throwIfCancelled()
                resolved = reading
                if display.transportPath == .typeCDPAlt,
                   dataAddress != transportParameters.typeCDPReadDataAddress {
                    rememberReadDataAddress(dataAddress, selector: selector)
                }
                recordDiagnostic(selector: selector, path: display.transportPath, serviceMatched: true,
                                 category: reading.estimated ? .readChecksumEstimated : .readSucceeded,
                                 chipAddress: display.chipAddress,
                                 readDataAddress: dataAddress,
                                 readAttemptCount: attempts,
                                 discardedRequestEchoCount: discardedEchoes)
            case .failure(
                let issue, let dataAddress, let attempts, let discardedEchoes, _,
                let compatibilityRejection, let compatibilityEvidence
            ):
                try token.throwIfCancelled()
                recordDiagnostic(
                    selector: selector, path: display.transportPath, serviceMatched: true,
                    category: diagnosticCategory(for: issue), replyIssue: issue,
                    chipAddress: display.chipAddress, readDataAddress: dataAddress,
                    readAttemptCount: attempts,
                    discardedRequestEchoCount: discardedEchoes,
                    checksumCompatibilityRejection: compatibilityRejection,
                    checksumCompatibilityEvidence: compatibilityEvidence
                )
                throw DDCBackendError.invalidReply(command: command, issue: issue)
            }
        }, recover: {
            try token.throwIfCancelled()
            incrementRebuild(selector: selector)
            invalidate(selector: selector)
            _ = rediscoverDisplay(selector: selector)
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
            let candidate = NativeDDCWriteServicePolicy.requiresFreshResolution(for: command)
                ? rediscoverDisplay(selector: selector)
                : display(for: selector)
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
                                 category: .writeTransportFailed,
                                 chipAddress: display.chipAddress)
                throw DDCBackendError.writeFailed(stableID: stableID, command: command)
            }
            try token.throwIfCancelled()
            recordDiagnostic(selector: selector, path: display.transportPath, serviceMatched: true,
                             category: .writeSucceeded, chipAddress: display.chipAddress)
        }, recover: {
            try token.throwIfCancelled()
            incrementRebuild(selector: selector)
            invalidate(selector: selector)
            _ = rediscoverDisplay(selector: selector)
        })
    }

    func cancelAll() {
        cacheLock.lock()
        displaysByUUID.removeAll()
        readPreferenceCache.removeAll()
        cacheLock.unlock()
    }

    func diagnostic(selector: String) -> NativeDDCDiagnosticSnapshot? {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return diagnosticsBySelector[selector.uppercased()]
    }

    private func recordDiagnostic(selector: String, path: NativeDDCTransportPath,
                                  serviceMatched: Bool, category: NativeDDCOperationCategory,
                                  replyIssue: NativeDDCReplyIssue? = nil,
                                  chipAddress: UInt32? = nil,
                                  readDataAddress: UInt8? = nil,
                                  readAttemptCount: Int? = nil,
                                  discardedRequestEchoCount: Int? = nil,
                                  checksumCompatibilityRejection: NativeDDCChecksumCompatibilityRejection? = nil,
                                  checksumCompatibilityEvidence: NativeDDCChecksumCompatibilityEvidence? = nil) {
        let key = selector.uppercased()
        diagnosticsLock.lock()
        let rebuildCount = diagnosticsBySelector[key]?.rebuildCount ?? 0
        diagnosticsBySelector[key] = NativeDDCDiagnosticSnapshot(
            transportPath: path, serviceMatched: serviceMatched,
            operationCategory: category, rebuildCount: rebuildCount,
            replyIssue: replyIssue, chipAddress: chipAddress,
            readDataAddress: readDataAddress,
            readAttemptCount: readAttemptCount,
            discardedRequestEchoCount: discardedRequestEchoCount,
            checksumCompatibilityRejection: checksumCompatibilityRejection,
            checksumCompatibilityEvidence: checksumCompatibilityEvidence
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
            operationCategory: current.operationCategory, rebuildCount: current.rebuildCount + 1,
            replyIssue: current.replyIssue, chipAddress: current.chipAddress,
            readDataAddress: current.readDataAddress,
            readAttemptCount: current.readAttemptCount,
            discardedRequestEchoCount: current.discardedRequestEchoCount,
            checksumCompatibilityRejection: current.checksumCompatibilityRejection,
            checksumCompatibilityEvidence: current.checksumCompatibilityEvidence
        )
        diagnosticsLock.unlock()
    }

    private func diagnosticCategory(for issue: NativeDDCReplyIssue) -> NativeDDCOperationCategory {
        switch issue {
        case .requestWriteFailed: return .readRequestWriteFailed
        case .responseTimeout: return .readResponseTimeout
        case .responseReadFailed: return .readResponseFailed
        case .requestEcho: return .readReplyRejected
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
        readPreferenceCache.invalidate(selector: selector)
        cacheLock.unlock()
    }

    private func preferredReadDataAddress(selector: String, path: NativeDDCTransportPath) -> UInt8 {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return readPreferenceCache.preferredAddress(
            selector: selector,
            default: transportParameters.readDataAddress(for: path)
        )
    }

    private func rememberReadDataAddress(_ address: UInt8, selector: String) {
        cacheLock.lock()
        readPreferenceCache.remember(address: address, selector: selector)
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

    /// Re-enumerates the current service for one stable selector without replacing
    /// healthy service references belonging to other displays.
    private func rediscoverDisplay(selector: String) -> NativeDDCDisplay? {
        cacheLock.lock()
        let knownDisplays = self.knownDisplays
        cacheLock.unlock()
        let selected = Self.discoverDisplays(knownDisplays: knownDisplays).first {
            $0.systemUUID.caseInsensitiveCompare(selector) == .orderedSame
        }
        cacheLock.lock()
        displaysByUUID = NativeDDCSelectedServiceMap.replacingSelected(
            selector: selector, with: selected, in: displaysByUUID
        )
        readPreferenceCache.invalidate(selector: selector)
        cacheLock.unlock()
        if let selected {
            recordDiagnostic(
                selector: selected.systemUUID,
                path: selected.transportPath,
                serviceMatched: selected.service != nil,
                category: selected.service == nil ? .serviceUnmatched : .idle
            )
        }
        return selected
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
            serviceLocation: Int,
            endpointToken: String?
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
                let path = registryPath(entry)
                currentFramebuffer = (
                    ioDisplayLocation: path,
                    productName: productName(for: entry) ?? "",
                    serialNumber: productSerialNumber(for: entry),
                    edidUUID: property(entry: entry, key: "EDID UUID") as? String ?? "",
                    serviceLocation: serviceLocation,
                    endpointToken: NativeDisplayEndpointToken.extract(from: [path, entryName])
                )
                continue
            }
            guard
                entryName == "DCPAVServiceProxy",
                let currentFramebuffer,
                property(entry: entry, key: "Location") as? String == "External",
                let unmanagedService = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)
            else { continue }
            let addressing = transportAddressing(
                for: entry, adjacentEndpointToken: currentFramebuffer.endpointToken
            )
            transports.append(NativeRegistryTransport(
                metadata: NativeTransportCandidate(
                    serviceLocation: currentFramebuffer.serviceLocation,
                    ioDisplayLocation: currentFramebuffer.ioDisplayLocation,
                    productName: currentFramebuffer.productName,
                    serialNumber: currentFramebuffer.serialNumber,
                    edidUUID: currentFramebuffer.edidUUID,
                    transportPath: addressing.transportPath
                ),
                service: unmanagedService.takeRetainedValue() as IOAVService,
                chipAddress: addressing.chipAddress
            ))
        }
        return transports
    }

    private static func transportAddressing(for proxy: io_registry_entry_t,
                                            adjacentEndpointToken: String?)
        -> NativeDDCTransportAddressing {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return NativeDDCTransportAddressing(
                transportPath: .unknownExternal, chipAddress: 0x37
            )
        }
        defer { IOObjectRelease(parent) }
        let provider = property(entry: parent, key: "EPICProviderClass") as? String
        let descriptions = ["Transport", "TransportType", "ConnectionType"].compactMap { key in
            (property(entry: proxy, key: key) ?? property(entry: parent, key: key)) as? String
        }
        var parentNameBuffer = [CChar](repeating: 0, count: 128)
        let parentName = IORegistryEntryGetName(parent, &parentNameBuffer) == KERN_SUCCESS
            ? String(cString: parentNameBuffer) : ""
        let endpointToken = NativeDisplayEndpointToken.extract(from: [
            registryPath(proxy),
            registryPath(parent),
            parentName,
            adjacentEndpointToken ?? ""
        ])
        return NativeDDCTransportAddressing.resolve(
            endpointToken: endpointToken,
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
        primaryDataAddress: UInt8,
        token: DDCCancellationToken,
        parameters: NativeDDCTransportParameters
    ) -> NativeDDCReadStrategyOutcome {
        let alternateDataAddress: UInt8? = transportPath == .typeCDPAlt
            && primaryDataAddress == parameters.typeCDPReadDataAddress ? 0 : nil
        let strictOutcome = NativeDDCReadStrategyRunner.run(
            primaryDataAddress: primaryDataAddress,
            alternateDataAddress: alternateDataAddress
        ) { readDataAddress in
            let transaction = getVCPTransaction(
                service: service,
                chipAddress: chipAddress,
                command: command,
                readDataAddress: readDataAddress,
                pollDelaysMicroseconds: parameters.readPollDelaysMicroseconds(for: transportPath),
                token: token,
                parameters: parameters
            )
            switch transaction {
            case .reply(let response, let polls, let discardedEchoes):
                return NativeDDCReadExchangeOutcome(
                    result: NativeDDCReplyValidator.reading(from: response, command: command),
                    polls: polls,
                    discardedRequestEchoes: discardedEchoes
                )
            case .failure(let issue, let polls, let discardedEchoes):
                return NativeDDCReadExchangeOutcome(
                    result: .failure(issue), polls: polls,
                    discardedRequestEchoes: discardedEchoes
                )
            case .cancelled(let polls, let discardedEchoes):
                return NativeDDCReadExchangeOutcome(
                    result: .failure(.responseTimeout), polls: polls,
                    discardedRequestEchoes: discardedEchoes
                )
            }
        }
        guard case .failure(
            .badChecksum,
            let dataAddress,
            let strictAttempts,
            let strictDiscardedEchoes,
            onlyObservedIssueWasBadChecksum: true,
            checksumCompatibilityRejection: nil,
            checksumCompatibilityEvidence: nil
        ) = strictOutcome else {
            return strictOutcome
        }
        var compatibilityPolls = 0
        var compatibilityDiscardedEchoes = 0
        let compatibility = NativeDDCChecksumCompatibilityRunner.run(command: command) { response in
            switch getVCPTransaction(
                service: service,
                chipAddress: chipAddress,
                command: command,
                readDataAddress: dataAddress,
                pollDelaysMicroseconds: parameters.readPollDelaysMicroseconds(for: transportPath),
                token: token,
                parameters: parameters
            ) {
            case .reply(let reply, let polls, let discardedEchoes):
                compatibilityPolls += polls
                compatibilityDiscardedEchoes += discardedEchoes
                response = reply
                return .success(())
            case .failure(let issue, let polls, let discardedEchoes):
                compatibilityPolls += polls
                compatibilityDiscardedEchoes += discardedEchoes
                return .failure(issue)
            case .cancelled(let polls, let discardedEchoes):
                compatibilityPolls += polls
                compatibilityDiscardedEchoes += discardedEchoes
                return .failure(.responseTimeout)
            }
        }
        switch compatibility {
        case .accepted(let reading):
            return .success(
                reading, dataAddress: dataAddress,
                attempts: strictAttempts + compatibilityPolls,
                discardedRequestEchoes: strictDiscardedEchoes + compatibilityDiscardedEchoes
            )
        case .rejected(let rejection, let evidence):
            return .failure(
                .badChecksum, dataAddress: dataAddress,
                attempts: strictAttempts + compatibilityPolls,
                discardedRequestEchoes: strictDiscardedEchoes + compatibilityDiscardedEchoes,
                onlyObservedIssueWasBadChecksum: true,
                checksumCompatibilityRejection: rejection,
                checksumCompatibilityEvidence: evidence
            )
        }
    }

    private static func write(
        service: IOAVService,
        chipAddress: UInt32,
        command: UInt8,
        value: UInt16,
        parameters: NativeDDCTransportParameters
    ) -> Bool {
        var request: [UInt8] = [command, UInt8(value >> 8), UInt8(value & 0xff)]
        switch communicateWrite(
            service: service,
            chipAddress: chipAddress,
            request: &request,
            attempts: parameters.writeAttempts,
            parameters: parameters
        ) {
        case .success: return true
        case .failure: return false
        }
    }

    private static func getVCPTransaction(
        service: IOAVService,
        chipAddress: UInt32,
        command: DDCCommand,
        readDataAddress: UInt8,
        pollDelaysMicroseconds: [UInt32],
        token: DDCCancellationToken,
        parameters: NativeDDCTransportParameters
    ) -> NativeDDCGetVCPTransactionOutcome {
        var packet = NativeDDCRequestPacket.getVCP(chipAddress: chipAddress, command: command)
        return NativeDDCGetVCPTransactionRunner.run(
            requestPacket: packet,
            pollCount: pollDelaysMicroseconds.count,
            shouldContinue: { !token.isCancelled },
            writeRequest: {
                usleep(parameters.writeSleepMicroseconds)
                return IOAVServiceWriteI2C(
                    service,
                    chipAddress,
                    UInt32(parameters.writeDataAddress),
                    &packet,
                    UInt32(packet.count)
                ) == KERN_SUCCESS
            },
            readReply: { pollIndex, response in
                usleep(pollDelaysMicroseconds[pollIndex])
                let result = IOAVServiceReadI2C(
                    service,
                    chipAddress,
                    UInt32(readDataAddress),
                    &response,
                    UInt32(response.count)
                )
                if result == kIOReturnTimeout || result == kIOReturnNotResponding {
                    return .timeout
                }
                return result == KERN_SUCCESS ? .reply : .readFailed
            }
        )
    }

    private static func communicateWrite(
        service: IOAVService,
        chipAddress: UInt32,
        request: inout [UInt8],
        attempts: Int,
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

            if writeSucceeded { return .success(()) }
            usleep(parameters.retrySleepMicroseconds)
        }
        return .failure(.requestWriteFailed)
    }

    private static func checksum<S: Sequence>(initial: UInt8, bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(initial, ^)
    }
}
