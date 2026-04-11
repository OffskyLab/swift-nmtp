import NIO
import NMTP
import Synchronization

public final class PeerDispatcherListener: Sendable {
    public let address: SocketAddress

    private let listener: PeerListener
    private let configure: @Sendable (PeerDispatcher) -> Void
    private let dispatcherTasks = Mutex<[UInt64: Task<Void, Never>]>([:])
    private let nextTaskID = Mutex<UInt64>(0)

    package init(listener: PeerListener, configure: @escaping @Sendable (PeerDispatcher) -> Void) {
        self.address = listener.address
        self.listener = listener
        self.configure = configure
    }
}

extension PeerDispatcherListener {
    public func run() async throws {
        for await peer in listener.peers {
            let dispatcher = PeerDispatcher(peer: peer)
            configure(dispatcher)

            let id = nextTaskID.withLock { id in
                defer { id &+= 1 }
                return id
            }

            let task = Task<Void, Never> { [self] in
                _ = try? await dispatcher.run()
                _ = dispatcherTasks.withLock { $0.removeValue(forKey: id) }
            }
            dispatcherTasks.withLock { $0[id] = task }
        }
    }

    public func close() async throws {
        let tasks = dispatcherTasks.withLock { tasks in
            let copy = tasks
            tasks.removeAll()
            return copy
        }
        // Cancel tasks then await completion so no task runs after ELG shutdown.
        await withTaskGroup(of: Void.self) { group in
            for task in tasks.values {
                task.cancel()
                group.addTask { await task.value }
            }
        }
        try await listener.close()
    }
}
