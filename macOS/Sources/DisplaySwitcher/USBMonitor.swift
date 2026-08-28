import Foundation
import IOKit

struct USBDevice: Codable, Hashable {
    let vendorID: Int
    let productID: Int
    let name: String
    let serialNumber: String?

    var displayName: String {
        name
    }

    var localReference: String {
        (try? JSONEncoder().encode(self).base64EncodedString()) ?? ""
    }

    func matches(_ other: USBDevice) -> Bool {
        guard vendorID == other.vendorID, productID == other.productID else { return false }
        if let serialNumber, !serialNumber.isEmpty {
            return serialNumber == other.serialNumber
        }
        return name == other.name
    }
}

struct USBDeviceReference: Equatable {
    let vendorID: Int
    let productID: Int
    let exactDevice: USBDevice?

    init?(localReference: String) {
        if let data = Data(base64Encoded: localReference),
           let device = try? JSONDecoder().decode(USBDevice.self, from: data) {
            vendorID = device.vendorID
            productID = device.productID
            exactDevice = device
            return
        }
        let parts = localReference.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let vendorID = Int(parts[0]), let productID = Int(parts[1]),
              (0...65_535).contains(vendorID), (0...65_535).contains(productID) else { return nil }
        self.vendorID = vendorID
        self.productID = productID
        exactDevice = nil
    }

    func matches(_ device: USBDevice) -> Bool {
        if let exactDevice { return exactDevice.matches(device) }
        return device.vendorID == vendorID && device.productID == productID
    }
}

final class USBMonitor {
    static let learningTimeoutSeconds: TimeInterval = 30
    var onPresenceChanged: ((Bool) -> Void)?
    var onInitialPresenceObserved: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "DisplaySwitcher.usb-monitor")
    private var timer: DispatchSourceTimer?
    private var previousDevices: Set<USBDevice>?
    private var triggerDevice: USBDevice?
    private var triggerReference: USBDeviceReference?
    private var lastPresence: Bool?
    private var learningHandler: (([USBDevice]) -> Void)?
    private var learningBaseline: Set<USBDevice>?
    private var learningTimeout: DispatchWorkItem?

    func start(triggerDevice: USBDevice?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.triggerDevice = triggerDevice
            self.triggerReference = nil
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

    func start(triggerReference: USBDeviceReference) {
        queue.async { [weak self] in
            guard let self else { return }
            self.triggerDevice = nil
            self.triggerReference = triggerReference
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

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.triggerDevice = nil
            self.triggerReference = nil
            self.lastPresence = nil
            self.previousDevices = nil
            self.learningHandler = nil
            self.learningBaseline = nil
            self.learningTimeout?.cancel()
            self.learningTimeout = nil
        }
    }

    func beginLearning(completion: @escaping ([USBDevice]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let devices = Self.currentDevices()
            self.learningTimeout?.cancel()
            self.learningBaseline = devices
            self.learningHandler = completion
            self.previousDevices = devices
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, let handler = self.learningHandler else { return }
                self.learningBaseline = nil
                self.learningHandler = nil
                self.learningTimeout = nil
                DispatchQueue.main.async { handler([]) }
            }
            self.learningTimeout = timeout
            self.queue.asyncAfter(deadline: .now() + Self.learningTimeoutSeconds, execute: timeout)
        }
    }

    func cancelLearning() {
        queue.async { [weak self] in
            self?.learningBaseline = nil
            self?.learningHandler = nil
            self?.learningTimeout?.cancel()
            self?.learningTimeout = nil
        }
    }

    func triggerPresence(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.triggerDevice != nil || self.triggerReference != nil else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let isPresent = Self.currentDevices().contains { self.matchesTrigger($0) }
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
                learningTimeout?.cancel()
                learningTimeout = nil
                DispatchQueue.main.async { handler(changed) }
            }
        }

        if triggerDevice != nil || triggerReference != nil {
            let isPresent = devices.contains { matchesTrigger($0) }
            if let lastPresence, lastPresence != isPresent {
                DispatchQueue.main.async { [weak self] in
                    self?.onPresenceChanged?(isPresent)
                }
            } else if lastPresence == nil {
                DispatchQueue.main.async { [weak self] in
                    self?.onInitialPresenceObserved?(isPresent)
                }
            }
            lastPresence = isPresent
        }

        previousDevices = devices
    }

    private func matchesTrigger(_ device: USBDevice) -> Bool {
        if let triggerDevice { return triggerDevice.matches(device) }
        if let triggerReference { return triggerReference.matches(device) }
        return false
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
