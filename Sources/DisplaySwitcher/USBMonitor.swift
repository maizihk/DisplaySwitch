import Foundation
import IOKit

struct USBDevice: Codable, Hashable {
    let vendorID: Int
    let productID: Int
    let name: String
    let serialNumber: String?

    var displayName: String {
        let ids = String(format: "%04X:%04X", vendorID, productID)
        if let serialNumber, !serialNumber.isEmpty {
            return "\(name)（\(ids)，序列号 \(serialNumber)）"
        }
        return "\(name)（\(ids)）"
    }

    func matches(_ other: USBDevice) -> Bool {
        guard vendorID == other.vendorID, productID == other.productID else { return false }
        if let serialNumber, !serialNumber.isEmpty {
            return serialNumber == other.serialNumber
        }
        return name == other.name
    }
}

final class USBMonitor {
    var onPresenceChanged: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "DisplaySwitcher.usb-monitor")
    private var timer: DispatchSourceTimer?
    private var previousDevices: Set<USBDevice>?
    private var triggerDevice: USBDevice?
    private var lastPresence: Bool?
    private var learningHandler: (([USBDevice]) -> Void)?
    private var learningBaseline: Set<USBDevice>?

    func start(triggerDevice: USBDevice?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.triggerDevice = triggerDevice
            self.lastPresence = nil
            self.previousDevices = nil

            if self.timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
                timer.setEventHandler { [weak self] in self?.poll() }
                self.timer = timer
                timer.resume()
            }
        }
    }

    func beginLearning(completion: @escaping ([USBDevice]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let devices = Self.currentDevices()
            self.learningBaseline = devices
            self.learningHandler = completion
            self.previousDevices = devices
        }
    }

    func cancelLearning() {
        queue.async { [weak self] in
            self?.learningBaseline = nil
            self?.learningHandler = nil
        }
    }

    func triggerPresence(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, let triggerDevice = self.triggerDevice else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let isPresent = Self.currentDevices().contains { triggerDevice.matches($0) }
            DispatchQueue.main.async { completion(isPresent) }
        }
    }

    private func poll() {
        let devices = Self.currentDevices()

        if let baseline = learningBaseline, let handler = learningHandler {
            let changed = Array(baseline.symmetricDifference(devices)).sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            if !changed.isEmpty {
                learningBaseline = nil
                learningHandler = nil
                DispatchQueue.main.async { handler(changed) }
            }
        }

        if let triggerDevice {
            let isPresent = devices.contains { triggerDevice.matches($0) }
            if let lastPresence, lastPresence != isPresent {
                DispatchQueue.main.async { [weak self] in
                    self?.onPresenceChanged?(isPresent)
                }
            }
            lastPresence = isPresent
        }

        previousDevices = devices
    }

    private static func currentDevices() -> Set<USBDevice> {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var devices = Set<USBDevice>()
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }

            guard
                let vendorID = integerProperty("idVendor", service: service),
                let productID = integerProperty("idProduct", service: service)
            else {
                continue
            }

            let name = stringProperty("USB Product Name", service: service)
                ?? stringProperty("kUSBProductString", service: service)
                ?? "USB 设备"
            let serial = stringProperty("USB Serial Number", service: service)
                ?? stringProperty("kUSBSerialNumberString", service: service)

            devices.insert(USBDevice(
                vendorID: vendorID,
                productID: productID,
                name: name,
                serialNumber: serial
            ))
        }
        return devices
    }

    private static func integerProperty(_ key: String, service: io_service_t) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber else {
            return nil
        }
        return value.intValue
    }

    private static func stringProperty(_ key: String, service: io_service_t) -> String? {
        IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String
    }
}
