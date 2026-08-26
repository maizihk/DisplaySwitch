// Native Apple Silicon DDC/CI transport.
// Discovery and I2C packet handling are derived from AppleSiliconDDC:
// https://github.com/waydabber/AppleSiliconDDC
// Copyright (c) 2021 Istvan T., used under the MIT License.

import CoreGraphics
import Foundation
import IOKit

struct NativeDDCDisplay {
    let name: String
    let systemUUID: String
    let serviceLocation: Int
    let service: IOAVService
    let chipAddress: UInt32
    let isOnline: Bool
}

struct NativeDDCKnownDisplay {
    let name: String
    let systemUUID: String
}

enum NativeDDCWriteResult {
    case success
    case unavailable
    case failed
}

final class NativeDDCBackend {
    private let knownDisplays: [NativeDDCKnownDisplay]
    private let cacheLock = NSLock()
    private var displaysByUUID: [String: NativeDDCDisplay] = [:]

    init(knownDisplays: [NativeDDCKnownDisplay] = []) {
        self.knownDisplays = knownDisplays
    }

    func discover() -> [NativeDDCDisplay] {
        #if arch(arm64)
        let displays = Self.discoverDisplays(knownDisplays: knownDisplays)
        cacheLock.lock()
        displaysByUUID = Dictionary(uniqueKeysWithValues: displays.map { ($0.systemUUID.uppercased(), $0) })
        cacheLock.unlock()
        return displays
        #else
        return []
        #endif
    }

    func read(selector: String, command: UInt8) -> (current: Int, maximum: Int)? {
        guard let display = display(for: selector) else { return nil }
        guard display.isOnline else { return nil }
        guard let value = Self.read(
            service: display.service,
            chipAddress: display.chipAddress,
            command: command
        ) else { return nil }
        return (Int(value.current), Int(value.maximum))
    }

    func hasDisplay(selector: String) -> Bool {
        display(for: selector) != nil
    }

    func write(selector: String, command: UInt8, value: UInt16) -> NativeDDCWriteResult {
        guard let display = display(for: selector) else { return .unavailable }
        return Self.write(
            service: display.service,
            chipAddress: display.chipAddress,
            command: command,
            value: value
        ) ? .success : .failed
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
        knownDisplays: [NativeDDCKnownDisplay]
    ) -> [NativeDDCDisplay] {
        let displayIDs = onlineExternalDisplayIDs()
        let onlineDisplays: [NativeDDCDisplay] = displayIDs.enumerated().compactMap { offset, displayID in
            guard let info = displayInfo(for: displayID) else { return nil }
            let adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, info.ioLocation as CFString)
            guard adapter != IO_OBJECT_NULL else { return nil }
            defer { IOObjectRelease(adapter) }

            guard let transport = transport(for: adapter) else { return nil }
            return NativeDDCDisplay(
                name: productName(for: adapter) ?? "显示器 \(offset + 1)",
                systemUUID: info.systemUUID,
                serviceLocation: offset + 1,
                service: transport.service,
                chipAddress: transport.chipAddress,
                isOnline: true
            )
        }

        let onlineUUIDs = Set(onlineDisplays.map { $0.systemUUID.uppercased() })
        let onlineNames = Set(onlineDisplays.map { $0.name.lowercased() })
        let offlineDisplays = registryDisplays(knownDisplays: knownDisplays)
            .filter {
                !onlineUUIDs.contains($0.systemUUID.uppercased()) &&
                !onlineNames.contains($0.name.lowercased())
            }
        return onlineDisplays + offlineDisplays
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
        ioLocation: String
    )? {
        guard let dictionary = CoreDisplay_DisplayCreateInfoDictionary(displayID)?.takeRetainedValue()
            as? [String: Any] else { return nil }
        guard let uuid = dictionary["kCGDisplayUUID"] as? String,
              let ioLocation = dictionary["IODisplayLocation"] as? String else { return nil }
        return (uuid.uppercased(), ioLocation)
    }

    private static func productName(for adapter: io_registry_entry_t) -> String? {
        guard
            let attributes = property(entry: adapter, key: "DisplayAttributes") as? [String: Any],
            let product = attributes["ProductAttributes"] as? [String: Any]
        else { return nil }
        return product["ProductName"] as? String
    }

    private static func registryDisplays(
        knownDisplays: [NativeDDCKnownDisplay]
    ) -> [NativeDDCDisplay] {
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

        var displays: [NativeDDCDisplay] = []
        while true {
            let adapter = IOIteratorNext(iterator)
            guard adapter != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(adapter) }
            guard
                IOObjectConformsTo(adapter, "IOMobileFramebuffer") != 0,
                let edidUUID = property(entry: adapter, key: "EDID UUID") as? String,
                let transport = transport(for: adapter)
            else { continue }

            let name = productName(for: adapter) ?? "外接显示器 \(displays.count + 1)"
            let knownMatches = knownDisplays.filter {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
            let selector = knownMatches.count == 1
                ? knownMatches[0].systemUUID.uppercased()
                : edidUUID.uppercased()
            displays.append(NativeDDCDisplay(
                name: name,
                systemUUID: selector,
                serviceLocation: displays.count + 1,
                service: transport.service,
                chipAddress: transport.chipAddress,
                isOnline: false
            ))
        }
        return displays
    }

    private static func transport(for adapter: io_registry_entry_t) -> (
        service: IOAVService,
        chipAddress: UInt32
    )? {
        var selectedAdapterID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(adapter, &selectedAdapterID) == KERN_SUCCESS else {
            return nil
        }

        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            root,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var framebufferMatchesDisplay = false

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(entry) }

            if IOObjectConformsTo(entry, "IOMobileFramebuffer") != 0 {
                var framebufferID: UInt64 = 0
                framebufferMatchesDisplay =
                    IORegistryEntryGetRegistryEntryID(entry, &framebufferID) == KERN_SUCCESS &&
                    framebufferID == selectedAdapterID
                continue
            }

            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { continue }
            guard
                framebufferMatchesDisplay,
                String(cString: name) == "DCPAVServiceProxy",
                property(entry: entry, key: "Location") as? String == "External",
                let unmanagedService = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)
            else { continue }

            return (
                unmanagedService.takeRetainedValue() as IOAVService,
                isMCDP29XXProxy(entry) ? 0xB7 : 0x37
            )
        }
        return nil
    }

    private static func isMCDP29XXProxy(_ proxy: io_registry_entry_t) -> Bool {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(parent) }
        return property(entry: parent, key: "EPICProviderClass") as? String == "AppleDCPMCDP29XX"
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
        command: UInt8
    ) -> (current: UInt16, maximum: UInt16)? {
        var request: [UInt8] = [command]
        var response = [UInt8](repeating: 0, count: 11)
        guard communicate(
            service: service,
            chipAddress: chipAddress,
            request: &request,
            response: &response,
            attempts: 1
        ) else { return nil }
        return (
            UInt16(response[8]) << 8 | UInt16(response[9]),
            UInt16(response[6]) << 8 | UInt16(response[7])
        )
    }

    private static func write(
        service: IOAVService,
        chipAddress: UInt32,
        command: UInt8,
        value: UInt16
    ) -> Bool {
        var request: [UInt8] = [command, UInt8(value >> 8), UInt8(value & 0xff)]
        var response: [UInt8] = []
        return communicate(
            service: service,
            chipAddress: chipAddress,
            request: &request,
            response: &response,
            attempts: 5
        )
    }

    private static func communicate(
        service: IOAVService,
        chipAddress: UInt32,
        request: inout [UInt8],
        response: inout [UInt8],
        attempts: Int
    ) -> Bool {
        let dataAddress: UInt8 = 0x51
        var packet = [UInt8(0x80 | (request.count + 1)), UInt8(request.count)] + request + [0]
        packet[packet.count - 1] = checksum(
            initial: request.count == 1 ? UInt8(truncatingIfNeeded: chipAddress << 1) : UInt8(truncatingIfNeeded: chipAddress << 1) ^ dataAddress,
            bytes: packet.dropLast()
        )

        for _ in 0..<attempts {
            var writeSucceeded = false
            for _ in 0..<2 {
                usleep(10_000)
                writeSucceeded = IOAVServiceWriteI2C(
                    service,
                    chipAddress,
                    UInt32(dataAddress),
                    &packet,
                    UInt32(packet.count)
                ) == KERN_SUCCESS
            }

            if !response.isEmpty {
                usleep(50_000)
                let readSucceeded = IOAVServiceReadI2C(
                    service,
                    chipAddress,
                    UInt32(dataAddress),
                    &response,
                    UInt32(response.count)
                ) == KERN_SUCCESS
                writeSucceeded = readSucceeded && checksum(
                    initial: 0x50,
                    bytes: response.dropLast()
                ) == response.last
            }

            if writeSucceeded { return true }
            usleep(20_000)
        }
        return false
    }

    private static func checksum<S: Sequence>(initial: UInt8, bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(initial, ^)
    }
}
