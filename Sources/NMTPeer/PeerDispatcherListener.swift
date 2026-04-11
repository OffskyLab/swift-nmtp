import NIO
import NMTP
import Synchronization

public final class PeerDispatcherListener: Sendable {
    public let address: SocketAddress

    private let listener: PeerListener
    private let configure: @Sendable (PeerDispatcher) -> Void
    private let dispatcherTasks = Mutex<[Task<Void, Never>]>([])

    init(
        listener: PeerListener,
        configure: @escaping @Sendable (PeerDispatcher) -> Void
    ) {
        self.address = listener.address
        self.listener = listener
        self.configure = configure
    }
}

// MARK: - Run / Close

extension PeerDispatcherListener {
    public func run() async throws {
        for await peer in listener.peers {
            let dispatcher = PeerDispatcher(peer: peer)
            configure(dispatcher)

            let task = Task<Void, Never> {
                _ = try? await dispatcher.run()
            }
            dispatcherTasks.withLock { $0.append(task) }
        }
    }

    public func close() async throws {
        let tasks = dispatcherTasks.withLock {
            let tasks = $0
            $0.removeAll()
            return tasks
        }
        tasks.forEach { $0.cancel() }
        try await listener.close()
    }
}
