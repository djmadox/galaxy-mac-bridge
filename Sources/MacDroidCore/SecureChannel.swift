import CryptoKit
import Foundation

public enum SecureChannelError: Error, Equatable {
    case invalidKey
    case invalidOffer
    case malformedEnvelope
    case replayedOrOutOfOrderMessage
}

public struct PairingOffer: Codable, Equatable, Sendable {
    public let version: Int
    public let deviceId: UUID
    public let deviceName: String
    public let publicKey: Data
    public let nonce: Data
    public let serviceType: String

    public init(
        version: Int = 1,
        deviceId: UUID,
        deviceName: String,
        publicKey: Data,
        nonce: Data,
        serviceType: String = "_macdroid._tcp"
    ) {
        self.version = version
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.nonce = nonce
        self.serviceType = serviceType
    }
}

public struct PairingIdentity: Sendable {
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    public let deviceId: UUID

    public init(deviceId: UUID = UUID()) {
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.deviceId = deviceId
    }

    public init(deviceId: UUID, rawPrivateKey: Data) throws {
        do {
            self.privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
            self.deviceId = deviceId
        } catch {
            throw SecureChannelError.invalidKey
        }
    }

    public var privateKeyData: Data { privateKey.rawRepresentation }
    public var publicKeyData: Data { privateKey.publicKey.rawRepresentation }

    public func offer(deviceName: String, nonce: Data) -> PairingOffer {
        PairingOffer(
            deviceId: deviceId,
            deviceName: deviceName,
            publicKey: publicKeyData,
            nonce: nonce
        )
    }

    public func deriveSession(with remoteOffer: PairingOffer, localOffer: PairingOffer) throws -> PairingResult {
        guard Self.isValid(remoteOffer), Self.isValid(localOffer),
              remoteOffer.deviceId != localOffer.deviceId else {
            throw SecureChannelError.invalidOffer
        }
        let remoteKey: Curve25519.KeyAgreement.PublicKey
        do {
            remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteOffer.publicKey)
        } catch {
            throw SecureChannelError.invalidKey
        }

        let shared = try privateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let transcript = Self.transcript(localOffer, remoteOffer)
        let salt = Data(SHA256.hash(data: transcript))
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("macdroid/session/v1".utf8),
            outputByteCount: 32
        )
        let authentication = HMAC<SHA256>.authenticationCode(
            for: transcript,
            using: key
        )
        let bytes = Array(authentication)
        let value = bytes.prefix(4).reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        return PairingResult(key: key, verificationCode: String(format: "%06d", value % 1_000_000))
    }

    private static func isValid(_ offer: PairingOffer) -> Bool {
        offer.version == 1
            && offer.serviceType == "_macdroid._tcp"
            && offer.publicKey.count == 32
            && offer.nonce.count == 32
            && (1...128).contains(offer.deviceName.utf8.count)
    }

    private static func transcript(_ first: PairingOffer, _ second: PairingOffer) -> Data {
        let offers = [first, second].sorted {
            $0.deviceId.uuidString.lowercased() < $1.deviceId.uuidString.lowercased()
        }
        var data = Data("macdroid/pairing/v1".utf8)
        for offer in offers {
            data.append(Data(offer.deviceId.uuidString.lowercased().utf8))
            data.append(offer.publicKey)
            data.append(offer.nonce)
        }
        return data
    }
}

public struct PairingResult: Sendable {
    public let key: SymmetricKey
    public let verificationCode: String
}

public struct EncryptedEnvelope: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let ciphertext: Data

    public init(sequence: UInt64, ciphertext: Data) {
        self.sequence = sequence
        self.ciphertext = ciphertext
    }
}

public struct TransportPacket: Codable, Equatable, Sendable {
    public enum PacketType: String, Codable, Sendable {
        case offer
        case confirmation
        case envelope
        case error
    }

    public let type: PacketType
    public let offer: PairingOffer?
    public let confirmed: Bool?
    public let envelope: EncryptedEnvelope?
    public let error: String?

    public init(
        type: PacketType,
        offer: PairingOffer? = nil,
        confirmed: Bool? = nil,
        envelope: EncryptedEnvelope? = nil,
        error: String? = nil
    ) {
        self.type = type
        self.offer = offer
        self.confirmed = confirmed
        self.envelope = envelope
        self.error = error
    }
}

/// AES-256-GCM transport encryption with sequence-bound authenticated data.
public struct SecureChannel: Sendable {
    private let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    public func seal(_ message: BridgeMessage) throws -> EncryptedEnvelope {
        let cleartext = try JSONEncoder.macDroid.encode(message)
        let aad = Self.authenticatedData(sequence: message.sequence)
        let box = try AES.GCM.seal(cleartext, using: key, authenticating: aad)
        guard let combined = box.combined else { throw SecureChannelError.malformedEnvelope }
        return EncryptedEnvelope(sequence: message.sequence, ciphertext: combined)
    }

    public func open(_ envelope: EncryptedEnvelope, lastReceivedSequence: UInt64?) throws -> BridgeMessage {
        guard envelope.sequence > 0,
              (28...InputLimits.maximumFrameBytes).contains(envelope.ciphertext.count) else {
            throw SecureChannelError.malformedEnvelope
        }
        if let lastReceivedSequence, envelope.sequence <= lastReceivedSequence {
            throw SecureChannelError.replayedOrOutOfOrderMessage
        }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: envelope.ciphertext)
        } catch {
            throw SecureChannelError.malformedEnvelope
        }
        let cleartext = try AES.GCM.open(
            box,
            using: key,
            authenticating: Self.authenticatedData(sequence: envelope.sequence)
        )
        let message = try JSONDecoder.macDroid.decode(BridgeMessage.self, from: cleartext)
        guard message.version == 1, message.sequence == envelope.sequence else {
            throw SecureChannelError.malformedEnvelope
        }
        return message
    }

    private static func authenticatedData(sequence: UInt64) -> Data {
        var bigEndian = sequence.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}
