//
//  MatterBodies.swift
//

import Foundation

// MARK: - Clone

public struct CloneBody: Codable, Sendable {}

public struct CloneReplyBody: Codable, Sendable {
    public var identifier: String
    public var name: String
    public var category: UInt8

    public init(identifier: String, name: String, category: UInt8) {
        self.identifier = identifier
        self.name = name
        self.category = category
    }
}

// MARK: - Register

public struct RegisterBody: Codable, Sendable {
    /// Fully qualified namespace in forward order, e.g. "production.ml.embedding"
    public var namespace: String
    public var host: String
    public var port: Int
    public var identifier: String

    public init(namespace: String, host: String, port: Int, identifier: String) {
        self.namespace = namespace
        self.host = host
        self.port = port
        self.identifier = identifier
    }
}

public struct RegisterReplyBody: Codable, Sendable {
    public var status: String

    public init(status: String) {
        self.status = status
    }
}

// MARK: - Find

public struct FindBody: Codable, Sendable {
    public var namespace: String

    public init(namespace: String) {
        self.namespace = namespace
    }
}

public struct FindReplyBody: Codable, Sendable {
    /// Stellar endpoint (nil = not found)
    public var stellarHost: String?
    public var stellarPort: Int?

    public init(stellarHost: String? = nil, stellarPort: Int? = nil) {
        self.stellarHost = stellarHost
        self.stellarPort = stellarPort
    }
}

// MARK: - FindGalaxy (Broker discovery)

public struct FindGalaxyBody: Codable, Sendable {
    /// Fully qualified broker topic, e.g. "production.orders.jobs"
    public var topic: String

    public init(topic: String) {
        self.topic = topic
    }
}

public struct FindGalaxyReplyBody: Codable, Sendable {
    /// Galaxy address that manages this broker topic (nil = not found)
    public var galaxyHost: String?
    public var galaxyPort: Int?

    public init(galaxyHost: String? = nil, galaxyPort: Int? = nil) {
        self.galaxyHost = galaxyHost
        self.galaxyPort = galaxyPort
    }
}

// MARK: - Unregister

public struct UnregisterBody: Codable, Sendable {
    public var namespace: String
    public var host: String
    public var port: Int

    public init(namespace: String, host: String, port: Int) {
        self.namespace = namespace
        self.host = host
        self.port = port
    }
}

public struct UnregisterReplyBody: Codable, Sendable {
    /// Next available Stellar endpoint (nil = pool exhausted)
    public var nextHost: String?
    public var nextPort: Int?

    public init(nextHost: String? = nil, nextPort: Int? = nil) {
        self.nextHost = nextHost
        self.nextPort = nextPort
    }
}

// MARK: - Call

public struct CallBody: Codable, Sendable {
    public var namespace: String
    public var service: String
    public var method: String
    public var arguments: [EncodedArgument]

    public init(namespace: String, service: String, method: String, arguments: [EncodedArgument]) {
        self.namespace = namespace
        self.service = service
        self.method = method
        self.arguments = arguments
    }
}

public struct EncodedArgument: Codable, Sendable {
    public var key: String
    public var value: Data

    public init(key: String, value: Data) {
        self.key = key
        self.value = value
    }
}

// MARK: - Enqueue / ACK

public struct EnqueueBody: Codable, Sendable {
    public var namespace: String
    public var service: String
    public var method: String
    public var arguments: [EncodedArgument]

    public init(namespace: String, service: String, method: String, arguments: [EncodedArgument]) {
        self.namespace = namespace
        self.service = service
        self.method = method
        self.arguments = arguments
    }
}

public struct AckBody: Codable, Sendable {
    public var matterID: String

    public init(matterID: String) {
        self.matterID = matterID
    }
}

// MARK: - Subscribe / Event

public struct SubscribeBody: Codable, Sendable {
    public var topic: String
    public var subscription: String

    public init(topic: String, subscription: String) {
        self.topic = topic
        self.subscription = subscription
    }
}

public struct UnsubscribeBody: Codable, Sendable {
    public var topic: String
    public var subscription: String

    public init(topic: String, subscription: String) {
        self.topic = topic
        self.subscription = subscription
    }
}

public struct EventBody: Codable, Sendable {
    public var topic: String
    public var method: String
    public var arguments: [EncodedArgument]

    public init(topic: String, method: String, arguments: [EncodedArgument]) {
        self.topic = topic
        self.method = method
        self.arguments = arguments
    }
}

// MARK: - Call Reply

public struct CallReplyBody: Codable, Sendable {
    public var result: Data?
    public var error: String?

    public init(result: Data? = nil, error: String? = nil) {
        self.result = result
        self.error = error
    }
}
