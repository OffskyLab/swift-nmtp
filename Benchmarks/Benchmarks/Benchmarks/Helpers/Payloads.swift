import Foundation
import MessagePacker
import NMTP

/// Pre-built MessagePack payloads for benchmark use.
/// Never regenerate inside a benchmark loop — pass these constants directly.
enum Payloads {
    struct Echo: Codable {
        let data: Data
    }

    static let small: Data = {
        let payload = Echo(data: Data(repeating: 0xAB, count: 52))   // 52 B data → ~64 B encoded
        guard let encoded = try? MessagePackEncoder().encode(payload) else {
            fatalError("Payloads.small: MessagePack encoding failed")
        }
        return encoded
    }()

    static let medium: Data = {
        let payload = Echo(data: Data(repeating: 0xAB, count: 1012)) // 1012 B data → ~1 KB encoded
        guard let encoded = try? MessagePackEncoder().encode(payload) else {
            fatalError("Payloads.medium: MessagePack encoding failed")
        }
        return encoded
    }()

    static let large: Data = {
        let payload = Echo(data: Data(repeating: 0xAB, count: 65524)) // 65524 B data → ~64 KB encoded
        guard let encoded = try? MessagePackEncoder().encode(payload) else {
            fatalError("Payloads.large: MessagePack encoding failed")
        }
        return encoded
    }()

    /// Wire-size comparison for README table.
    static func printOverheadTable() {
        let httpHeaderEstimate = 130 // typical HTTP/1.1 POST header bytes
        print("| Payload | NMTP wire | HTTP wire |")
        print("|---------|-----------|-----------|")
        for (label, body) in [("Small", small), ("Medium", medium), ("Large", large)] {
            let nmtp = Matter.headerSize + body.count
            let http = httpHeaderEstimate + body.count
            print("| \(label) | \(nmtp) B | \(http) B |")
        }
    }
}
