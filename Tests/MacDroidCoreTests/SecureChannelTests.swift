import CryptoKit
import Foundation
import Testing
@testable import MacDroidCore

@Test func pairingProducesMatchingKeysAndCodes() throws {
    let mac = PairingIdentity(deviceId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let phone = PairingIdentity(deviceId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let macOffer = mac.offer(deviceName: "MacBook", nonce: Data(repeating: 1, count: 32))
    let phoneOffer = phone.offer(deviceName: "Galaxy", nonce: Data(repeating: 2, count: 32))

    let macResult = try mac.deriveSession(with: phoneOffer, localOffer: macOffer)
    let phoneResult = try phone.deriveSession(with: macOffer, localOffer: phoneOffer)

    #expect(macResult.verificationCode == phoneResult.verificationCode)
    #expect(macResult.key.withUnsafeBytes { Data($0) } == phoneResult.key.withUnsafeBytes { Data($0) })
}

@Test func pairingMatchesCrossPlatformRFC7748Vector() throws {
    let alicePrivate = Data(hex: "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    let bobPublic = Data(hex: "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
    let alice = try PairingIdentity(
        deviceId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        rawPrivateKey: alicePrivate
    )
    let local = alice.offer(deviceName: "Mac", nonce: Data(repeating: 1, count: 32))
    let remote = PairingOffer(
        deviceId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        deviceName: "Android",
        publicKey: bobPublic,
        nonce: Data(repeating: 2, count: 32)
    )

    let result = try alice.deriveSession(with: remote, localOffer: local)
    #expect(result.key.withUnsafeBytes { Data($0) }.hex == "e517edf35cf302c5f8a69d0de5652fe731818defc825fe62a287b746c3cb07b2")
    #expect(result.verificationCode == "762753")
}

@Test func encryptedMessageRoundTripsAndRejectsReplay() throws {
    let key = SymmetricKey(size: .bits256)
    let channel = SecureChannel(key: key)
    let payload = SendSMSPayload(address: "+15550100100", body: "Hej")
    let message = try BridgeMessage.make(sequence: 7, kind: .smsSend, payload: payload)

    let envelope = try channel.seal(message)
    let opened = try channel.open(envelope, lastReceivedSequence: 6)

    #expect(opened == message)
    #expect(throws: SecureChannelError.replayedOrOutOfOrderMessage) {
        try channel.open(envelope, lastReceivedSequence: 7)
    }
}

@Test func tamperingIsRejected() throws {
    let channel = SecureChannel(key: SymmetricKey(size: .bits256))
    let message = try BridgeMessage.make(sequence: 1, kind: .ping, payload: ["value": "ping"])
    let valid = try channel.seal(message)
    var bytes = valid.ciphertext
    bytes[bytes.startIndex] ^= 0xff

    #expect(throws: (any Error).self) {
        try channel.open(EncryptedEnvelope(sequence: 1, ciphertext: bytes), lastReceivedSequence: nil)
    }
}

@Test func smsSnapshotChunkFlagsRoundTrip() throws {
    let snapshot = SMSSnapshotPayload(messages: [], reset: true, complete: false)
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(SMSSnapshotPayload.self, from: data)

    #expect(decoded.reset == true)
    #expect(decoded.complete == false)
    #expect(decoded.messages.isEmpty)
}

@Test func encryptedFileChunkRoundTrips() throws {
    let bytes = Data((0..<4_096).map { UInt8($0 % 251) })
    let transferId = UUID()
    let chunk = FileTransferChunkPayload(transferId: transferId, offset: 262_144, data: bytes)
    let message = try BridgeMessage.make(sequence: 12, kind: .fileTransferChunk, payload: chunk)
    let channel = SecureChannel(key: SymmetricKey(size: .bits256))

    let opened = try channel.open(channel.seal(message), lastReceivedSequence: 11)
    let decoded = try opened.decodePayload(as: FileTransferChunkPayload.self)

    #expect(decoded.transferId == transferId)
    #expect(decoded.offset == 262_144)
    #expect(decoded.data == bytes)
}

@Test func encryptedFileCancellationRoundTrips() throws {
    let transferId = UUID()
    let cancellation = FileTransferCancelPayload(transferId: transferId)
    let message = try BridgeMessage.make(sequence: 13, kind: .fileTransferCancel, payload: cancellation)
    let channel = SecureChannel(key: SymmetricKey(size: .bits256))

    let opened = try channel.open(channel.seal(message), lastReceivedSequence: 12)
    let decoded = try opened.decodePayload(as: FileTransferCancelPayload.self)

    #expect(opened.kind == .fileTransferCancel)
    #expect(decoded.transferId == transferId)
}

private extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        })
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
