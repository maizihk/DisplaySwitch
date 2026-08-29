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
    private let hardwareArbiter: NativeI2CHardwareArbiter

    init(knownDisplays: [DDCKnownDisplay] = [],
         transportParameters: NativeDDCTransportParameters = .appleSiliconDDCCompatible,
         hardwareArbiter: NativeI2CHardwareArbiter = .shared) {
        self.knownDisplays = knownDisplays
        self.transportParameters = transportParameters
        self.hardwareArbiter = hardwareArbiter
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
            let readOutcome = hardwareArbiter.withControlOperation {
                Self.read(
                    service: service,
                    chipAddress: display.chipAddress,
                    command: command,
                    transportPath: display.transportPath,
                    primaryDataAddress: preferredReadDataAddress(
                        selector: selector, path: display.transportPath
                    ),
                    parameters: transportParameters
                )
            }
            switch readOutcome {
            case .success(let reading, let dataAddress, let attempts):
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
                                 readAttemptCount: attempts)
            case .failure(
                let issue, let dataAddress, let attempts, _,
                let compatibilityRejection, let compatibilityEvidence
            ):
                recordDiagnostic(
                    selector: selector, path: display.transportPath, serviceMatched: true,
                    category: diagnosticCategory(for: issue), replyIssue: issue,
                    chipAddress: display.chipAddress, readDataAddress: dataAddress,
                    readAttemptCount: attempts,
                    checksumCompatibilityRejection: compatibilityRejection,
                    checksumCompatibilityEvidence: compatibilityEvidence
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
            let writeSucceeded = hardwareArbiter.withControlOperation {
                Self.write(
                    service: service, chipAddress: display.chipAddress,
                    command: command.rawValue, value: nativeValue,
                    parameters: transportParameters
                )
            }
            guard writeSucceeded else {
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
            _ = discover()
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

    fileprivate static func discoverDisplays(
        knownDisplays: [DDCKnownDisplay],
        diagnosticSelector: String? = nil,
        diagnosticContext: InputSourceDiagnosticContext? = nil,
        diagnostics: InputSourceDiagnosticRecording? = nil
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
        if let diagnosticSelector, let diagnosticContext, let diagnostics {
            let identity = identities.first {
                $0.systemUUID.caseInsensitiveCompare(diagnosticSelector) == .orderedSame
            }.map {
                NativeDisplayIdentity(
                    stableID: $0.systemUUID,
                    ioDisplayLocation: $0.ioLocation,
                    productName: $0.productName,
                    serialNumber: $0.serialNumber,
                    edidSearchKeys: $0.edidSearchKeys
                )
            }
            let selectedLocation = identity.flatMap { matches[$0.stableID] }
            let evidence = NativeInputCandidateDiagnosticProjection.evidence(
                identity: identity,
                candidates: transports.map(\.metadata),
                selectedServiceLocation: selectedLocation,
                anonymousServiceID: diagnostics.anonymousServiceID(for:)
            )
            diagnostics.record(.candidates(evidence), context: diagnosticContext)
            if let selected = evidence.first(where: \.selected) {
                let reason = "matcher-score-\(selected.score)"
                    + "-location-\(selected.locationMatched)"
                    + "-name-\(selected.productNameMatched)"
                    + "-serial-\(selected.serialMatched)"
                    + "-edid-\(selected.edidMatchCount)"
                diagnostics.record(
                    .serviceSelected(
                        anonymousID: selected.anonymousID,
                        reason: reason,
                        transportType: selected.transportType
                    ),
                    context: diagnosticContext
                )
            } else {
                diagnostics.record(.failed(reason: "service-unmatched"), context: diagnosticContext)
            }
        }
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
        parameters: NativeDDCTransportParameters
    ) -> NativeDDCReadStrategyOutcome {
        let alternateDataAddress: UInt8? = transportPath == .typeCDPAlt
            && primaryDataAddress == parameters.typeCDPReadDataAddress ? 0 : nil
        let strictOutcome = NativeDDCReadStrategyRunner.run(
            primaryDataAddress: primaryDataAddress,
            alternateDataAddress: alternateDataAddress,
            attemptsPerStrategy: parameters.readAttempts(for: transportPath)
        ) { readDataAddress, response in
            var request: [UInt8] = [command.rawValue]
            let exchange = communicate(
                service: service,
                chipAddress: chipAddress,
                request: &request,
                response: &response,
                attempts: 1,
                readDataAddress: readDataAddress,
                readSleepMicroseconds: parameters.readSleepMicroseconds(for: transportPath),
                parameters: parameters
            )
            if case .failure(let issue) = exchange {
                return .failure(issue)
            }
            return NativeDDCReplyValidator.reading(from: response, command: command)
        }
        guard case .failure(
            .badChecksum,
            let dataAddress,
            let strictAttempts,
            onlyObservedIssueWasBadChecksum: true,
            checksumCompatibilityRejection: nil,
            checksumCompatibilityEvidence: nil
        ) = strictOutcome else {
            return strictOutcome
        }
        let compatibility = NativeDDCChecksumCompatibilityRunner.run(command: command) { response in
            var request: [UInt8] = [command.rawValue]
            return communicate(
                service: service,
                chipAddress: chipAddress,
                request: &request,
                response: &response,
                attempts: 1,
                readDataAddress: dataAddress,
                readSleepMicroseconds: parameters.readSleepMicroseconds(for: transportPath),
                parameters: parameters
            )
        }
        switch compatibility {
        case .accepted(let reading):
            return .success(
                reading, dataAddress: dataAddress,
                attempts: strictAttempts + NativeDDCChecksumCompatibilityValidator.requiredReplyCount
            )
        case .rejected(let rejection, let evidence):
            return .failure(
                .badChecksum, dataAddress: dataAddress,
                attempts: strictAttempts + NativeDDCChecksumCompatibilityValidator.requiredReplyCount,
                onlyObservedIssueWasBadChecksum: true,
                checksumCompatibilityRejection: rejection,
                checksumCompatibilityEvidence: evidence
            )
        }
    }

    fileprivate static func write(
        service: IOAVService,
        chipAddress: UInt32,
        command: UInt8,
        value: UInt16,
        parameters: NativeDDCTransportParameters,
        diagnosticContext: InputSourceDiagnosticContext? = nil,
        diagnostics: InputSourceDiagnosticRecording? = nil
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
            parameters: parameters,
            diagnosticContext: diagnosticContext,
            diagnostics: diagnostics
        ) {
        case .success: return true
        case .failure: return false
        }
    }

    fileprivate static func inputFeedback(
        service: IOAVService,
        chipAddress: UInt32,
        transportPath: NativeDDCTransportPath,
        targetValue: UInt16,
        alternateValue: UInt16?,
        parameters: NativeDDCTransportParameters
    ) -> InputSourceDeviceFeedback {
        let primaryAddress = parameters.readDataAddress(for: transportPath)
        switch read(
            service: service,
            chipAddress: chipAddress,
            command: .input,
            transportPath: transportPath,
            primaryDataAddress: primaryAddress,
            parameters: parameters
        ) {
        case let .success(reading, _, _):
            if reading.current == Int(targetValue) {
                return .targetValue(
                    value: reading.current, maximum: reading.maximum, estimated: reading.estimated
                )
            }
            if let alternateValue, reading.current == Int(alternateValue) {
                return .alternateValue(
                    value: reading.current, maximum: reading.maximum, estimated: reading.estimated
                )
            }
            return .otherValue(
                value: reading.current, maximum: reading.maximum, estimated: reading.estimated
            )
        case let .failure(issue, dataAddress, attempts, _, _, _):
            return .unavailable(
                issue: issue.diagnosticCode, attempts: attempts, offset: dataAddress
            )
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
        parameters: NativeDDCTransportParameters,
        diagnosticContext: InputSourceDiagnosticContext? = nil,
        diagnostics: InputSourceDiagnosticRecording? = nil
    ) -> Result<Void, NativeDDCReplyIssue> {
        let dataAddress = parameters.writeDataAddress
        var packet = [UInt8(0x80 | (request.count + 1)), UInt8(request.count)] + request + [0]
        packet[packet.count - 1] = checksum(
            initial: request.count == 1 ? UInt8(truncatingIfNeeded: chipAddress << 1) : UInt8(truncatingIfNeeded: chipAddress << 1) ^ dataAddress,
            bytes: packet.dropLast()
        )

        for attemptIndex in 0..<attempts {
            var cycleIndex = 0
            let writeSucceeded = NativeDDCWriteCyclePolicy.perform(
                cycles: parameters.writeCycles
            ) {
                cycleIndex += 1
                usleep(parameters.writeSleepMicroseconds)
                let startedAt = Date()
                let startedNanos = DispatchTime.now().uptimeNanoseconds
                let result = IOAVServiceWriteI2C(
                    service,
                    chipAddress,
                    UInt32(dataAddress),
                    &packet,
                    UInt32(packet.count)
                )
                let endedNanos = DispatchTime.now().uptimeNanoseconds
                let endedAt = Date()
                if let diagnosticContext, let diagnostics, request.first == DDCCommand.input.rawValue {
                    diagnostics.record(
                        .writeCall(
                            attempt: attemptIndex + 1,
                            cycle: cycleIndex,
                            frameHex: packet.map { String(format: "%02X", $0) }.joined(separator: " "),
                            chip: chipAddress,
                            address: dataAddress,
                            offset: dataAddress,
                            startedAt: startedAt,
                            endedAt: endedAt,
                            returnCode: result,
                            durationMicroseconds: (endedNanos - startedNanos) / 1_000
                        ),
                        context: diagnosticContext
                    )
                }
                return result == KERN_SUCCESS
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

final class NativeInputSourceTransportResolver: InputSourceTransportResolving {
    private let transportParameters: NativeDDCTransportParameters
    private let diagnostics: InputSourceDiagnosticRecording

    init(
        transportParameters: NativeDDCTransportParameters = .appleSiliconDDCCompatible,
        diagnostics: InputSourceDiagnosticRecording = InputSourceDiagnosticStore.shared
    ) {
        self.transportParameters = transportParameters
        self.diagnostics = diagnostics
    }

    func resolve(selector: String, context: InputSourceDiagnosticContext) throws -> InputSourceTransport {
#if arch(arm64)
        guard let display = NativeDDCBackend.discoverDisplays(
            knownDisplays: [],
            diagnosticSelector: selector,
            diagnosticContext: context,
            diagnostics: diagnostics
        ).first(where: {
            $0.systemUUID.caseInsensitiveCompare(selector) == .orderedSame
        }), display.isOnline, let service = display.service else {
            throw InputSourceSwitchFailure.displayUnavailable(stableID: selector)
        }
        return NativeResolvedInputSourceTransport(
            service: service,
            chipAddress: display.chipAddress,
            transportPath: display.transportPath,
            transportParameters: transportParameters,
            diagnostics: diagnostics
        )
#else
        throw InputSourceSwitchFailure.displayUnavailable(stableID: selector)
#endif
    }
}

private final class NativeResolvedInputSourceTransport: InputSourceTransport {
    private let service: IOAVService
    private let chipAddress: UInt32
    private let transportPath: NativeDDCTransportPath
    private let transportParameters: NativeDDCTransportParameters
    private let diagnostics: InputSourceDiagnosticRecording

    init(service: IOAVService, chipAddress: UInt32, transportPath: NativeDDCTransportPath,
         transportParameters: NativeDDCTransportParameters,
         diagnostics: InputSourceDiagnosticRecording) {
        self.service = service
        self.chipAddress = chipAddress
        self.transportPath = transportPath
        self.transportParameters = transportParameters
        self.diagnostics = diagnostics
    }

    func writeInput(_ value: UInt16, context: InputSourceDiagnosticContext) -> Bool {
        let acceptedByTransport = NativeDDCBackend.write(
            service: service,
            chipAddress: chipAddress,
            command: DDCCommand.input.rawValue,
            value: value,
            parameters: transportParameters,
            diagnosticContext: context,
            diagnostics: diagnostics
        )
        let feedback = NativeDDCBackend.inputFeedback(
            service: service,
            chipAddress: chipAddress,
            transportPath: transportPath,
            targetValue: context.targetValue,
            alternateValue: context.alternateValue,
            parameters: transportParameters
        )
        diagnostics.record(.deviceFeedback(feedback), context: context)
        return acceptedByTransport
    }
}
