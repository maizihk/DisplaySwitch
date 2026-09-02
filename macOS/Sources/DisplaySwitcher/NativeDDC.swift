// Native Apple Silicon DDC/CI transport.
// Discovery and I2C packet handling are derived from AppleSiliconDDC:
// https://github.com/waydabber/AppleSiliconDDC
// Copyright (c) 2021 Istvan T., used under the MIT License.
// MonitorControl uses a different read offset (0 instead of 0x51). DS-009 keeps
// the Type-C/DP strategies explicit and bounded. DS-014 adds a diagnostic-only
// HDMI 0 -> 0x51 comparison for chip 0x37 luminance reads; offset 0x51 is only
// accepted after two consecutive, strictly valid and semantically equal replies.

import CoreGraphics
import Foundation
import IOKit

struct NativeDDCDisplay {
    let name: String
    let systemUUID: String
    let serviceLocation: Int
    let serviceIdentity: UInt64
    let service: IOAVService?
    let edidReferences: [[UInt8]]
    let chipAddress: UInt32
    let transportPath: NativeDDCTransportPath
    let isOnline: Bool
}

private struct NativeRegistryTransport {
    let metadata: NativeTransportCandidate
    let service: IOAVService
    let edidReferences: [[UInt8]]
    let chipAddress: UInt32
    let serviceIdentity: UInt64
}

private struct NativeRegistryFramebuffer {
    let topology: NativeFramebufferTopologyNode
    let ioDisplayLocation: String
    let productName: String
    let serialNumber: Int64
    let edidUUID: String
    let edidReferences: [[UInt8]]
}

private struct NativeRegistryService {
    let topology: NativeServiceTopologyNode
    let service: IOAVService
    let edidReferences: [[UInt8]]
    let addressing: NativeDDCTransportAddressing
    let serviceIdentity: UInt64
}

private struct NativeDDCCommunicationTrace {
    let writeIOReturns: [Int32]
    let readIOReturn: Int32?
    let response: [UInt8]
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
    private var diagnosticDiscoveryState = NativeDDCDiagnosticDiscoveryState()
    private let transportParameters: NativeDDCTransportParameters
    private let hardwareArbiter: NativeI2CHardwareArbiter
    private let detailedDiagnosticRecordingEnabled: () -> Bool

    init(knownDisplays: [DDCKnownDisplay] = [],
         transportParameters: NativeDDCTransportParameters = .appleSiliconDDCCompatible,
         hardwareArbiter: NativeI2CHardwareArbiter = .shared,
         detailedDiagnosticRecordingEnabled: @escaping () -> Bool = { true }) {
        self.knownDisplays = knownDisplays
        self.transportParameters = transportParameters
        self.hardwareArbiter = hardwareArbiter
        self.detailedDiagnosticRecordingEnabled = detailedDiagnosticRecordingEnabled
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
        readPreferenceCache.retainOnly(Set(displays.compactMap { display in
            guard display.service != nil, display.serviceIdentity != 0 else { return nil }
            return NativeDDCReadPreferenceKey(
                selector: display.systemUUID,
                serviceIdentity: display.serviceIdentity,
                transportPath: display.transportPath
            )
        }))
        cacheLock.unlock()
        for display in displays {
            recordDiscoveryDiagnostic(
                selector: display.systemUUID,
                path: display.transportPath,
                serviceMatched: display.service != nil,
                serviceIdentity: display.serviceIdentity
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
            var hdmiReadDiagnostics: [NativeDDCReadAttemptDiagnostic] = []
            var requestChecksumMode: NativeDDCRequestChecksumMode?
            let recordsDetailedDiagnostics = detailedDiagnosticRecordingEnabled()
            let readPreference = preferredReadPreference(display: display)
            let readOutcome = hardwareArbiter.withControlOperation(displayKey: selector) {
                Self.read(
                    service: service,
                    chipAddress: display.chipAddress,
                    command: command,
                    transportPath: display.transportPath,
                    primaryDataAddress: readPreference.dataAddress,
                    preferredChecksumMode: readPreference.checksumMode,
                    parameters: transportParameters,
                    edidReferences: display.edidReferences,
                    diagnosticRecorder: recordsDetailedDiagnostics
                        ? { hdmiReadDiagnostics = $0 } : nil,
                    checksumModeRecorder: { requestChecksumMode = $0 }
                )
            }
            switch readOutcome {
            case .success(let reading, let dataAddress, let attempts):
                try token.throwIfCancelled()
                resolved = reading
                if let requestChecksumMode {
                    rememberReadPreference(
                        NativeDDCReadPreference(
                            dataAddress: dataAddress,
                            checksumMode: requestChecksumMode
                        ),
                        display: display
                    )
                }
                recordDiagnostic(selector: selector, path: display.transportPath, serviceMatched: true,
                                 category: reading.estimated ? .readChecksumEstimated
                                    : (!hdmiReadDiagnostics.isEmpty && dataAddress == 0x51
                                        ? .readDiagnosticSucceeded : .readSucceeded),
                                 chipAddress: display.chipAddress,
                                 readDataAddress: dataAddress,
                                 readAttemptCount: attempts,
                                 requestChecksumMode: requestChecksumMode,
                                 hdmiReadDiagnostics: hdmiReadDiagnostics)
            case .failure(
                let issue, let dataAddress, let attempts, _,
                let compatibilityRejection, let compatibilityEvidence
            ):
                if display.transportPath == .builtinHDMIConverter,
                   display.chipAddress == 0x37 {
                    recordDiagnostic(
                        selector: selector, path: display.transportPath, serviceMatched: true,
                        category: .reliableReadUnsupported,
                        hdmiReadDiagnostics: hdmiReadDiagnostics
                    )
                    throw DDCBackendError.reliableReadUnsupported(command: command)
                }
                recordDiagnostic(
                    selector: selector, path: display.transportPath, serviceMatched: true,
                    category: diagnosticCategory(for: issue), replyIssue: issue,
                    chipAddress: display.chipAddress, readDataAddress: dataAddress,
                    readAttemptCount: attempts,
                    requestChecksumMode: requestChecksumMode,
                    checksumCompatibilityRejection: compatibilityRejection,
                    checksumCompatibilityEvidence: compatibilityEvidence,
                    hdmiReadDiagnostics: hdmiReadDiagnostics
                )
                throw DDCBackendError.invalidReply(command: command, issue: issue)
            }
        }, recover: {
            try token.throwIfCancelled()
            incrementRebuild(selector: selector)
            invalidate(selector: selector)
            _ = discover()
        }, shouldRetry: { error in
            if case DDCBackendError.reliableReadUnsupported = error {
                return false
            }
            return true
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
        guard command != .input || InputSourceValuePolicy.isSafe(value),
              let nativeValue = UInt16(exactly: value) else {
            throw DDCError.invalidValue(value)
        }
        try DDCSingleRetry.perform(operation: {
            try token.throwIfCancelled()
            let candidate = display(for: selector)
            guard let display = candidate, let service = display.service else {
                let path = candidate?.transportPath ?? .unmatched
                recordDiagnostic(selector: selector, path: path, serviceMatched: false,
                                 category: .serviceUnmatched)
                throw DDCBackendError.displayUnavailable(stableID: stableID)
            }
            let writeSucceeded = hardwareArbiter.withControlOperation(displayKey: selector) {
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

    func clearDiagnostics() {
        diagnosticsLock.lock()
        diagnosticsBySelector.removeAll()
        diagnosticDiscoveryState = NativeDDCDiagnosticDiscoveryState()
        diagnosticsLock.unlock()
    }

    func removeLocalState(selector: String) {
        let key = selector.uppercased()
        cacheLock.lock()
        displaysByUUID.removeValue(forKey: key)
        readPreferenceCache.invalidate(selector: selector)
        cacheLock.unlock()
        transportLocksLock.lock()
        transportLocks.removeValue(forKey: key)
        transportLocksLock.unlock()
        diagnosticsLock.lock()
        diagnosticsBySelector.removeValue(forKey: key)
        diagnosticsLock.unlock()
    }

    private func recordDiagnostic(selector: String, path: NativeDDCTransportPath,
                                  serviceMatched: Bool, category: NativeDDCOperationCategory,
                                  replyIssue: NativeDDCReplyIssue? = nil,
                                  chipAddress: UInt32? = nil,
                                  readDataAddress: UInt8? = nil,
                                  readAttemptCount: Int? = nil,
                                  requestChecksumMode: NativeDDCRequestChecksumMode? = nil,
                                  checksumCompatibilityRejection: NativeDDCChecksumCompatibilityRejection? = nil,
                                  checksumCompatibilityEvidence: NativeDDCChecksumCompatibilityEvidence? = nil,
                                  hdmiReadDiagnostics: [NativeDDCReadAttemptDiagnostic] = []) {
        guard detailedDiagnosticRecordingEnabled() else { return }
        let key = selector.uppercased()
        diagnosticsLock.lock()
        let rebuildCount = diagnosticsBySelector[key]?.rebuildCount ?? 0
        diagnosticsBySelector[key] = NativeDDCDiagnosticSnapshot(
            transportPath: path, serviceMatched: serviceMatched,
            operationCategory: category, rebuildCount: rebuildCount,
            replyIssue: replyIssue, chipAddress: chipAddress,
            readDataAddress: readDataAddress,
            readAttemptCount: readAttemptCount,
            requestChecksumMode: requestChecksumMode,
            checksumCompatibilityRejection: checksumCompatibilityRejection,
            checksumCompatibilityEvidence: checksumCompatibilityEvidence,
            hdmiReadDiagnostics: hdmiReadDiagnostics
        )
        diagnosticsLock.unlock()
    }

    private func recordDiscoveryDiagnostic(
        selector: String,
        path: NativeDDCTransportPath,
        serviceMatched: Bool,
        serviceIdentity: UInt64
    ) {
        guard detailedDiagnosticRecordingEnabled() else { return }
        let key = selector.uppercased()
        let binding = NativeDDCDiagnosticBinding(
            transportPath: path,
            serviceMatched: serviceMatched,
            serviceIdentity: serviceIdentity
        )
        diagnosticsLock.lock()
        if let replacement = diagnosticDiscoveryState.replacementSnapshot(
            selector: selector,
            binding: binding,
            current: diagnosticsBySelector[key]
        ) {
            diagnosticsBySelector[key] = replacement
        }
        diagnosticsLock.unlock()
    }

    private func incrementRebuild(selector: String) {
        guard detailedDiagnosticRecordingEnabled() else { return }
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
            requestChecksumMode: current.requestChecksumMode,
            checksumCompatibilityRejection: current.checksumCompatibilityRejection,
            checksumCompatibilityEvidence: current.checksumCompatibilityEvidence,
            hdmiReadDiagnostics: current.hdmiReadDiagnostics
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

    private func preferredReadPreference(display: NativeDDCDisplay) -> NativeDDCReadPreference {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let defaultMode: NativeDDCRequestChecksumMode = display.transportPath == .builtinHDMIConverter
            ? .standard : .legacy
        return readPreferenceCache.preferred(
            for: readPreferenceKey(for: display),
            default: NativeDDCReadPreference(
                dataAddress: transportParameters.readDataAddress(for: display.transportPath),
                checksumMode: defaultMode
            )
        )
    }

    private func rememberReadPreference(_ preference: NativeDDCReadPreference,
                                        display: NativeDDCDisplay) {
        cacheLock.lock()
        readPreferenceCache.remember(preference, for: readPreferenceKey(for: display))
        cacheLock.unlock()
    }

    private func readPreferenceKey(for display: NativeDDCDisplay) -> NativeDDCReadPreferenceKey {
        NativeDDCReadPreferenceKey(
            selector: display.systemUUID,
            serviceIdentity: display.serviceIdentity,
            transportPath: display.transportPath
        )
    }

    private func display(for selector: String) -> NativeDDCDisplay? {
        let key = selector.uppercased()
        // IOAVService objects are tied to the current physical route. Re-resolve
        // before each explicit hardware operation so reconnects and interface
        // changes cannot silently reuse a service from an older topology.
        _ = discover()
        cacheLock.lock()
        let display = displaysByUUID[key]
        cacheLock.unlock()
        return display
    }

    fileprivate static func discoverDisplays(
        knownDisplays: [DDCKnownDisplay],
        diagnosticSelector: String? = nil,
        diagnosticContext: InputSourceDiagnosticContext? = nil,
        diagnostics: InputSourceDiagnosticRecording? = nil
    ) -> [NativeDDCDisplay] {
        let identities = onlineExternalDisplayIDs().compactMap(displayInfo(for:))
        let transports = registryTransports(ioDisplayLocations: Set(identities.map(\.ioLocation)))
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
        if let diagnosticSelector, let diagnosticContext, let diagnostics,
           diagnostics.isRecordingEnabled {
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
                serviceIdentity: transport?.serviceIdentity ?? 0,
                service: transport?.service,
                edidReferences: transport?.edidReferences ?? [],
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

    private static func registryTransports(ioDisplayLocations: Set<String>)
        -> [NativeRegistryTransport] {
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

        var framebuffers: [NativeRegistryFramebuffer] = []
        var services: [NativeRegistryService] = []
        var framebufferLocation = 0
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
                let path = registryPath(entry)
                guard ioDisplayLocations.contains(path) else { continue }
                framebufferLocation += 1
                let productName = productName(for: entry) ?? ""
                framebuffers.append(NativeRegistryFramebuffer(
                    topology: NativeFramebufferTopologyNode(
                        location: framebufferLocation,
                        endpointToken: NativeDisplayEndpointToken.extractFramebuffer(
                            from: [path, entryName]
                        )
                    ),
                    ioDisplayLocation: path,
                    productName: productName,
                    serialNumber: productSerialNumber(for: entry),
                    edidUUID: property(entry: entry, key: "EDID UUID") as? String ?? "",
                    edidReferences: edidReferences(for: entry, productName: productName)
                ))
                continue
            }
            guard
                entryName == "DCPAVServiceProxy",
                property(entry: entry, key: "Location") as? String == "External",
                let unmanagedService = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)
            else { continue }
            serviceLocation += 1
            let topology = transportTopology(for: entry)
            var registryEntryID: UInt64 = 0
            _ = IORegistryEntryGetRegistryEntryID(entry, &registryEntryID)
            services.append(NativeRegistryService(
                topology: NativeServiceTopologyNode(
                    location: serviceLocation,
                    endpointToken: topology.endpointToken
                ),
                service: unmanagedService.takeRetainedValue() as IOAVService,
                edidReferences: edidReferences(for: entry, productName: ""),
                addressing: topology.addressing,
                serviceIdentity: registryEntryID
            ))
        }

        let topologyMatches = NativeServiceTopologyMatcher.matches(
            framebuffers: framebuffers.map(\.topology),
            services: services.map(\.topology)
        )
        let servicesByLocation = Dictionary(uniqueKeysWithValues: services.map {
            ($0.topology.location, $0)
        })
        return framebuffers.compactMap { framebuffer in
            guard let matchedServiceLocation = topologyMatches[framebuffer.topology.location],
                  let service = servicesByLocation[matchedServiceLocation] else { return nil }
            return NativeRegistryTransport(
                metadata: NativeTransportCandidate(
                    serviceLocation: service.topology.location,
                    ioDisplayLocation: framebuffer.ioDisplayLocation,
                    productName: framebuffer.productName,
                    serialNumber: framebuffer.serialNumber,
                    edidUUID: framebuffer.edidUUID,
                    transportPath: service.addressing.transportPath
                ),
                service: service.service,
                edidReferences: service.edidReferences + framebuffer.edidReferences,
                chipAddress: service.addressing.chipAddress,
                serviceIdentity: service.serviceIdentity
            )
        }
    }

    private static func transportTopology(for proxy: io_registry_entry_t)
        -> (addressing: NativeDDCTransportAddressing, endpointToken: String?) {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return (
                NativeDDCTransportAddressing(
                    transportPath: .unknownExternal, chipAddress: 0x37
                ),
                nil
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
        let endpointToken = NativeDisplayEndpointToken.extractService(from: [
            registryPath(proxy),
            registryPath(parent),
            parentName
        ])
        return (
            NativeDDCTransportAddressing.resolve(
                endpointToken: endpointToken,
                epicProviderClass: provider,
                transportDescription: descriptions.joined(separator: " ")
            ),
            endpointToken
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

    private static func edidReferences(for entry: io_registry_entry_t,
                                       productName: String) -> [[UInt8]] {
        var references: [[UInt8]] = []
        if let data = property(entry: entry, key: "IODisplayEDID") as? Data,
           !data.isEmpty {
            references.append(Array(data))
        }
        if !productName.isEmpty {
            references.append(Array(productName.utf8))
        }
        return references
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
        preferredChecksumMode: NativeDDCRequestChecksumMode = .legacy,
        parameters: NativeDDCTransportParameters,
        edidReferences: [[UInt8]] = [],
        diagnosticRecorder: (([NativeDDCReadAttemptDiagnostic]) -> Void)? = nil,
        checksumModeRecorder: ((NativeDDCRequestChecksumMode) -> Void)? = nil
    ) -> NativeDDCReadStrategyOutcome {
        if transportPath == .builtinHDMIConverter,
           chipAddress == 0x37 {
            checksumModeRecorder?(.standard)
            let recordsDetailedDiagnostics = diagnosticRecorder != nil
            var attemptDiagnostics: [NativeDDCReadAttemptDiagnostic] = []
            var strategyAttempt = 0
            let outcome = NativeDDCBuiltinHDMIReadPolicy.run(
                readDataAddress: parameters.readDataAddress(for: transportPath),
                attempts: parameters.readAttempts(for: transportPath),
                retry: {
                    usleep(parameters.builtinHDMIReadRetrySleepMicroseconds)
                }
            ) { readDataAddress, response in
                strategyAttempt += 1
                var request: [UInt8] = [command.rawValue]
                var communicationTrace: NativeDDCCommunicationTrace?
                let exchange = communicate(
                    service: service,
                    chipAddress: chipAddress,
                    request: &request,
                    response: &response,
                    attempts: 1,
                    readDataAddress: readDataAddress,
                    readSleepMicroseconds: parameters.readSleepMicroseconds(for: transportPath),
                    requestWriteCycles: parameters.builtinHDMIReadRequestWriteCycles,
                    requestChecksumIncludesDataAddress: true,
                    parameters: parameters,
                    trace: recordsDetailedDiagnostics ? { communicationTrace = $0 } : nil
                )
                let result: Result<DDCReading, NativeDDCReplyIssue>
                if case .failure(let issue) = exchange {
                    result = .failure(issue)
                } else {
                    result = NativeDDCReplyValidator.reading(from: response, command: command)
                }
                let validation: NativeDDCStrictReadValidation
                switch result {
                case .success(let reading): validation = .valid(reading)
                case .failure(let issue): validation = .rejected(issue)
                }
                if recordsDetailedDiagnostics {
                    attemptDiagnostics.append(NativeDDCReadAttemptDiagnostic(
                        dataAddress: readDataAddress,
                        strategyAttempt: strategyAttempt,
                        delayMicroseconds: parameters.readSleepMicroseconds(for: transportPath),
                        writeIOReturns: communicationTrace?.writeIOReturns ?? [],
                        readIOReturn: communicationTrace?.readIOReturn,
                        reply: communicationTrace?.response ?? response,
                        validation: validation,
                        edidReferences: edidReferences
                    ))
                }
                return result
            }
            diagnosticRecorder?(attemptDiagnostics)
            return outcome
        }
        diagnosticRecorder?([])
        let strictResult = NativeDDCChecksumStrategyRunner.run(
            preferredMode: preferredChecksumMode,
            primaryDataAddress: primaryDataAddress,
            defaultDataAddress: parameters.typeCDPReadDataAddress,
            attemptsPerAddress: parameters.readAttempts(for: transportPath),
            allowsFallback: transportPath == .typeCDPAlt
        ) { checksumMode, readDataAddress, response in
            var request: [UInt8] = [command.rawValue]
            let exchange = communicate(
                service: service,
                chipAddress: chipAddress,
                request: &request,
                response: &response,
                attempts: 1,
                readDataAddress: readDataAddress,
                readSleepMicroseconds: parameters.readSleepMicroseconds(for: transportPath),
                requestWriteCycles: parameters.writeCycles,
                requestChecksumIncludesDataAddress: checksumMode.includesDataAddress,
                parameters: parameters
            )
            if case .failure(let issue) = exchange {
                return .failure(issue)
            }
            return NativeDDCReplyValidator.reading(from: response, command: command)
        }
        checksumModeRecorder?(strictResult.checksumMode)
        guard case .failure(
            let finalIssue,
            let finalDataAddress,
            let totalAttempts,
            let finalOnlyBadChecksum,
            _, _
        ) = strictResult.outcome else {
            return strictResult.outcome
        }

        guard finalIssue == .badChecksum, finalOnlyBadChecksum else {
            return strictResult.outcome
        }
        let compatibility = NativeDDCChecksumCompatibilityRunner.run(command: command) { response in
            var request: [UInt8] = [command.rawValue]
            return communicate(
                service: service,
                chipAddress: chipAddress,
                request: &request,
                response: &response,
                attempts: 1,
                readDataAddress: finalDataAddress,
                readSleepMicroseconds: parameters.readSleepMicroseconds(for: transportPath),
                requestWriteCycles: parameters.writeCycles,
                requestChecksumIncludesDataAddress: strictResult.checksumMode.includesDataAddress,
                parameters: parameters
            )
        }
        switch compatibility {
        case .accepted(let reading):
            return .success(
                reading, dataAddress: finalDataAddress,
                attempts: totalAttempts + NativeDDCChecksumCompatibilityValidator.requiredReplyCount
            )
        case .rejected(let rejection, let evidence):
            return .failure(
                .badChecksum, dataAddress: finalDataAddress,
                attempts: totalAttempts + NativeDDCChecksumCompatibilityValidator.requiredReplyCount,
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
            requestWriteCycles: parameters.writeCycles,
            requestChecksumIncludesDataAddress: true,
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
        requestWriteCycles: Int,
        requestChecksumIncludesDataAddress: Bool,
        parameters: NativeDDCTransportParameters,
        diagnosticContext: InputSourceDiagnosticContext? = nil,
        diagnostics: InputSourceDiagnosticRecording? = nil,
        trace: ((NativeDDCCommunicationTrace) -> Void)? = nil
    ) -> Result<Void, NativeDDCReplyIssue> {
        let dataAddress = parameters.writeDataAddress
        let packet = NativeDDCRequestPacketBuilder.packet(
            request: request,
            chipAddress: chipAddress,
            dataAddress: dataAddress,
            includesDataAddressInChecksum: requestChecksumIncludesDataAddress
        )

        for attemptIndex in 0..<attempts {
            var cycleIndex = 0
            var writeIOReturns: [Int32] = []
            let writeSucceeded = NativeDDCWriteCyclePolicy.perform(
                cycles: requestWriteCycles
            ) {
                cycleIndex += 1
                usleep(parameters.writeSleepMicroseconds)
                let startedAt = Date()
                let startedNanos = DispatchTime.now().uptimeNanoseconds
                let result = NativeDDCI2CBufferBridge.withInputBytes(packet) { buffer in
                    IOAVServiceWriteI2C(
                        service,
                        chipAddress,
                        UInt32(dataAddress),
                        buffer.baseAddress,
                        UInt32(buffer.count)
                    )
                }
                writeIOReturns.append(result)
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
                let readResult = NativeDDCI2CBufferBridge.withOutputBytes(&response) { buffer in
                    IOAVServiceReadI2C(
                        service,
                        chipAddress,
                        UInt32(readDataAddress ?? parameters.typeCDPReadDataAddress),
                        buffer.baseAddress,
                        UInt32(buffer.count)
                    )
                }
                trace?(NativeDDCCommunicationTrace(
                    writeIOReturns: writeIOReturns,
                    readIOReturn: readResult,
                    response: response
                ))
                if readResult == kIOReturnTimeout || readResult == kIOReturnNotResponding {
                    return .failure(.responseTimeout)
                }
                if readResult != KERN_SUCCESS { return .failure(.responseReadFailed) }
            }

            if writeSucceeded {
                if response.isEmpty {
                    trace?(NativeDDCCommunicationTrace(
                        writeIOReturns: writeIOReturns,
                        readIOReturn: nil,
                        response: response
                    ))
                }
                return .success(())
            }
            trace?(NativeDDCCommunicationTrace(
                writeIOReturns: writeIOReturns,
                readIOReturn: nil,
                response: response
            ))
            usleep(parameters.retrySleepMicroseconds)
        }
        return .failure(.requestWriteFailed)
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
