import Foundation

struct DDCWriteKey: Hashable {
    let stableID: String
    let command: DDCCommand
}

enum DDCWriteOrigin: Equatable {
    case user
    case mediaKey(UInt64)
}

struct DDCWriteRequest: Equatable {
    let key: DDCWriteKey
    let selector: String
    let value: Int
    let origin: DDCWriteOrigin

    init(
        key: DDCWriteKey,
        selector: String,
        value: Int,
        origin: DDCWriteOrigin = .user
    ) {
        self.key = key
        self.selector = selector
        self.value = value
        self.origin = origin
    }

    func withOrigin(_ origin: DDCWriteOrigin) -> Self {
        Self(key: key, selector: selector, value: value, origin: origin)
    }
}

protocol DDCWriteExecuting: AnyObject {
    func execute(_ request: DDCWriteRequest, completion: @escaping (Result<Int, Error>) -> Void)
    func cancelAll()
}

/// Coalesces slider traffic while preserving one transport operation per display.
final class DDCLatestWinsCoordinator {
    typealias Completion = (DDCWriteRequest, Result<Int, Error>) -> Void

    private struct Pending {
        let request: DDCWriteRequest
        let sequence: UInt64
    }

    private let executor: DDCWriteExecuting
    private let lock = NSLock()
    private var pending: [DDCWriteKey: Pending] = [:]
    private var activeDisplays = Set<String>()
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var allowed = true
    var onCompletion: Completion?

    init(executor: DDCWriteExecuting) {
        self.executor = executor
    }

    func submit(_ request: DDCWriteRequest) {
        let displayID = request.key.stableID.lowercased()
        lock.lock()
        guard allowed else { lock.unlock(); return }
        sequence &+= 1
        pending[request.key] = Pending(request: request, sequence: sequence)
        let shouldStart = !activeDisplays.contains(displayID)
        if shouldStart { activeDisplays.insert(displayID) }
        let token = generation
        lock.unlock()
        if shouldStart { startNext(displayID: displayID, generation: token) }
    }

    func isBusy(_ key: DDCWriteKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending[key] != nil || activeDisplays.contains(key.stableID.lowercased())
    }

    func setOperationsAllowed(_ value: Bool) {
        lock.lock()
        allowed = value
        if !value {
            generation &+= 1
            pending.removeAll()
            activeDisplays.removeAll()
        }
        lock.unlock()
        if !value { executor.cancelAll() }
    }

    func cancelAll() {
        setOperationsAllowed(false)
    }

    private func startNext(displayID: String, generation token: UInt64) {
        lock.lock()
        guard allowed, token == generation else {
            activeDisplays.remove(displayID)
            lock.unlock()
            return
        }
        let next = pending.values
            .filter { $0.request.key.stableID.lowercased() == displayID }
            .min { $0.sequence < $1.sequence }
        guard let next else {
            activeDisplays.remove(displayID)
            lock.unlock()
            return
        }
        pending.removeValue(forKey: next.request.key)
        lock.unlock()

        executor.execute(next.request) { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            let shouldPublish = self.allowed && token == self.generation
            self.lock.unlock()
            if shouldPublish { self.onCompletion?(next.request, result) }
            self.startNext(displayID: displayID, generation: token)
        }
    }
}

final class DDCControllerWriteExecutor: DDCWriteExecuting {
    private let queue: DispatchQueue
    private let operation: (DDCWriteRequest) throws -> Void
    private let cancellation: () -> Void

    init(queue: DispatchQueue,
         operation: @escaping (DDCWriteRequest) throws -> Void,
         cancellation: @escaping () -> Void) {
        self.queue = queue
        self.operation = operation
        self.cancellation = cancellation
    }

    func execute(_ request: DDCWriteRequest, completion: @escaping (Result<Int, Error>) -> Void) {
        queue.async { [operation] in
            do {
                try operation(request)
                completion(.success(request.value))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func cancelAll() {
        cancellation()
    }
}
