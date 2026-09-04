import Foundation

public enum BridgeMessageKind: String, Codable, Sendable {
    case hello
    case notificationPosted
    case notificationRemoved
    case notificationAction
    case smsSyncRequest
    case smsSnapshot
    case smsSend
    case smsStatus
    case callStart
    case callState
    case fileTransferStart
    case fileTransferChunk
    case fileTransferComplete
    case fileTransferCancel
    case fileTransferStatus
    case ping
    case pong
}

/// The stable, versioned envelope used on both Android and macOS.
public struct BridgeMessage: Codable, Equatable, Sendable, Identifiable {
    public let version: Int
    public let id: UUID
    public let sequence: UInt64
    public let sentAt: Date
    public let kind: BridgeMessageKind
    public let payload: Data

    public init(
        version: Int = 1,
        id: UUID = UUID(),
        sequence: UInt64,
        sentAt: Date = Date(),
        kind: BridgeMessageKind,
        payload: Data
    ) {
        self.version = version
        self.id = id
        self.sequence = sequence
        let milliseconds = floor(sentAt.timeIntervalSince1970 * 1_000)
        self.sentAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        self.kind = kind
        self.payload = payload
    }

    public static func make<Payload: Encodable & Sendable>(
        sequence: UInt64,
        kind: BridgeMessageKind,
        payload: Payload,
        encoder: JSONEncoder = .macDroid
    ) throws -> BridgeMessage {
        BridgeMessage(
            sequence: sequence,
            kind: kind,
            payload: try encoder.encode(payload)
        )
    }

    public func decodePayload<Payload: Decodable & Sendable>(
        as type: Payload.Type,
        decoder: JSONDecoder = .macDroid
    ) throws -> Payload {
        try decoder.decode(type, from: payload)
    }
}

public struct NotificationPayload: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let packageName: String
    public let appName: String
    public let title: String
    public let body: String
    public let postedAt: Date
    public let actions: [NotificationAction]
    public let isSensitive: Bool

    public init(
        id: String,
        packageName: String,
        appName: String,
        title: String,
        body: String,
        postedAt: Date,
        actions: [NotificationAction] = [],
        isSensitive: Bool = false
    ) {
        self.id = id
        self.packageName = packageName
        self.appName = appName
        self.title = title
        self.body = body
        self.postedAt = postedAt
        self.actions = actions
        self.isSensitive = isSensitive
    }
}

public struct NotificationAction: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let acceptsText: Bool

    public init(id: String, title: String, acceptsText: Bool) {
        self.id = id
        self.title = title
        self.acceptsText = acceptsText
    }
}

public struct SMSMessagePayload: Codable, Equatable, Sendable, Identifiable {
    public enum Direction: String, Codable, Sendable { case incoming, outgoing }
    public enum DeliveryState: String, Codable, Sendable { case pending, sent, delivered, failed }
    public enum Transport: String, Codable, Sendable { case sms, rcs }

    public let id: String
    public let threadId: String
    public let address: String
    public let contactName: String?
    public let body: String
    public let timestamp: Date
    public let direction: Direction
    public let deliveryState: DeliveryState
    public let transport: Transport?
    public let replyNotificationId: String?
    public let replyActionId: String?

    public init(
        id: String,
        threadId: String,
        address: String,
        contactName: String? = nil,
        body: String,
        timestamp: Date,
        direction: Direction,
        deliveryState: DeliveryState,
        transport: Transport? = nil,
        replyNotificationId: String? = nil,
        replyActionId: String? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.address = address
        self.contactName = contactName
        self.body = body
        self.timestamp = timestamp
        self.direction = direction
        self.deliveryState = deliveryState
        self.transport = transport
        self.replyNotificationId = replyNotificationId
        self.replyActionId = replyActionId
    }
}

public struct NotificationActionRequest: Codable, Equatable, Sendable {
    public let notificationId: String
    public let actionId: String
    public let text: String

    public init(notificationId: String, actionId: String, text: String) {
        self.notificationId = notificationId
        self.actionId = actionId
        self.text = text
    }
}

public struct SMSSnapshotPayload: Codable, Equatable, Sendable {
    public let messages: [SMSMessagePayload]
    public let reset: Bool?
    public let complete: Bool?

    public init(messages: [SMSMessagePayload], reset: Bool? = nil, complete: Bool? = nil) {
        self.messages = messages
        self.reset = reset
        self.complete = complete
    }
}

public struct EmptyPayload: Codable, Equatable, Sendable {
    public init() {}
}

public struct SendSMSPayload: Codable, Equatable, Sendable {
    public let clientMessageId: UUID
    public let address: String
    public let body: String

    public init(clientMessageId: UUID = UUID(), address: String, body: String) {
        self.clientMessageId = clientMessageId
        self.address = address
        self.body = body
    }
}

public struct StartCallPayload: Codable, Equatable, Sendable {
    public let address: String

    public init(address: String) {
        self.address = address
    }
}

public struct FileTransferStartPayload: Codable, Equatable, Sendable {
    public let transferId: UUID
    public let fileName: String
    public let size: Int64
    public let mimeType: String

    public init(transferId: UUID, fileName: String, size: Int64, mimeType: String) {
        self.transferId = transferId
        self.fileName = fileName
        self.size = size
        self.mimeType = mimeType
    }
}

public struct FileTransferChunkPayload: Codable, Equatable, Sendable {
    public let transferId: UUID
    public let offset: Int64
    public let data: Data

    public init(transferId: UUID, offset: Int64, data: Data) {
        self.transferId = transferId
        self.offset = offset
        self.data = data
    }
}

public struct FileTransferCompletePayload: Codable, Equatable, Sendable {
    public let transferId: UUID
    public let sha256: String

    public init(transferId: UUID, sha256: String) {
        self.transferId = transferId
        self.sha256 = sha256
    }
}

public struct FileTransferCancelPayload: Codable, Equatable, Sendable {
    public let transferId: UUID

    public init(transferId: UUID) {
        self.transferId = transferId
    }
}

public struct FileTransferStatusPayload: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case accepted, progress, completed, cancelled, failed
    }

    public let transferId: UUID
    public let state: State
    public let bytesReceived: Int64
    public let totalBytes: Int64
    public let error: String?

    public init(
        transferId: UUID,
        state: State,
        bytesReceived: Int64,
        totalBytes: Int64,
        error: String? = nil
    ) {
        self.transferId = transferId
        self.state = state
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.error = error
    }
}

public enum CallAudioMode: String, Codable, Sendable {
    /// Controls a carrier call. Android does not expose its media to third-party apps.
    case cellularControl
    /// A separate SIP/VoIP call terminates on the Mac; no phone microphone is involved.
    case sipOnMac
}

public struct CallStatePayload: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case ringing, connecting, active, held, ended, failed
    }

    public let callId: UUID
    public let address: String
    public let displayName: String?
    public let state: State
    public let audioMode: CallAudioMode

    public init(
        callId: UUID,
        address: String,
        displayName: String? = nil,
        state: State,
        audioMode: CallAudioMode
    ) {
        self.callId = callId
        self.address = address
        self.displayName = displayName
        self.state = state
        self.audioMode = audioMode
    }
}


public extension JSONEncoder {
    static var macDroid: JSONEncoder {
        let encoder = JSONEncoder()
        // Android system events are millisecond based; keep the same exact precision on both sides.
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public extension JSONDecoder {
    static var macDroid: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
