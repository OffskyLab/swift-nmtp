import Foundation
#if canImport(os)
import os
#else
import Synchronization
#endif

final class PendingRequests: Sendable {
    #if canImport(os)
    private let waiting = OSAllocatedUnfairLock<[UUID: CheckedContinuation<Matter, Error>]>(initialState: [:])
    #else
    private let waiting = Mutex<[UUID: CheckedContinuation<Matter, Error>]>([:])
    #endif

    func register(id: UUID, continuation: CheckedContinuation<Matter, Error>) {
        waiting.withLock { $0[id] = continuation }
    }

    @discardableResult
    func fulfill(_ matter: Matter) -> Bool {
        let continuation = waiting.withLock { $0.removeValue(forKey: matter.matterID) }
        continuation?.resume(returning: matter)
        return continuation != nil
    }

    func fail(id: UUID, error: Error) {
        let continuation = waiting.withLock { $0.removeValue(forKey: id) }
        continuation?.resume(throwing: error)
    }

    func failAll(error: Error) {
        let all = waiting.withLock { dict -> [CheckedContinuation<Matter, Error>] in
            let values = Array(dict.values)
            dict.removeAll()
            return values
        }
        all.forEach { $0.resume(throwing: error) }
    }
}
