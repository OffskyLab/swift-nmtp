import NIO
import NMTP

/// Echoes each incoming .call Matter back as .reply with the same matterID and body.
struct EchoHandler: NMTHandler {
    func handle(matter: Matter, channel: Channel) async throws -> Matter? {
        Matter(type: .reply, matterID: matter.matterID, body: matter.body)
    }
}
