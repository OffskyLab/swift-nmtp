import Foundation

final class PendingRequests: @unchecked Sendable {
    private var waiting: [UUID: CheckedContinuation<Matter, Error>] = [:]
    private let lock = NSLock()

    func register(id: UUID, continuation: CheckedContinuation<Matter, Error>) {
        lock.lock()
        waiting[id] = continuation
        lock.unlock()
    }

    @discardableResult
    func fulfill(_ matter: Matter) -> Bool {
        lock.lock()
        let continuation = waiting.removeValue(forKey: matter.matterID)
        lock.unlock()
        continuation?.resume(returning: matter)
        return continuation != nil
    }

    func fail(id: UUID, error: Error) {
        lock.lock()
        let continuation = waiting.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    func failAll(error: Error) {
        lock.lock()
        let all = waiting
        waiting.removeAll()
        lock.unlock()
        for continuation in all.values {
            continuation.resume(throwing: error)
        }
    }
}
