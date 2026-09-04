import CryptoKit
import Foundation
import MacDroidCore
import Network
import Security
import UniformTypeIdentifiers

private enum MacBridgeError: LocalizedError, Sendable {
    case notConnected
    case unreadableFile(String)
    case encodingFailed
    case fileTooLarge(String)
    case transferTooLarge

    var errorDescription: String? {
        switch self {
        case .notConnected: "Telefonen är inte ansluten."
        case let .unreadableFile(name): "Filen \(name) kunde inte läsas."
        case .encodingFailed: "Filpaketet kunde inte skapas."
        case let .fileTooLarge(name): "Filen \(name) överskrider säkerhetsgränsen 10 GB."
        case .transferTooLarge: "Överföringen överskrider säkerhetsgränsen 20 GB."
        }
    }
}

final class MacBridgeServer: @unchecked Sendable {
    static let port: UInt16 = 53_318

    var onListening: (@Sendable (Bool) -> Void)?
    var onPairingCode: (@Sendable (String, String) -> Void)?
    var onConnected: (@Sendable (String) -> Void)?
    var onDisconnected: (@Sendable () -> Void)?
    var onMessage: (@Sendable (BridgeMessage) -> Void)?
    var onIncomingFileStatus: (@Sendable (FileTransferStatusPayload, String) -> Void)?

    private let queue = DispatchQueue(label: "se.macdroid.bridge.listener")
    private let identity: PairingIdentity
    private let fileReceiver = MacFileTransferReceiver()
    private var listener: NWListener?
    private var activePeer: MacPeerConnection?

    init() {
        identity = MacIdentityStore.loadOrCreate()
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            do {
                let port = NWEndpoint.Port(rawValue: Self.port)!
                let listener = try NWListener(using: .tcp, on: port)
                // Do not expose the user's computer name through unauthenticated Bonjour discovery.
                listener.service = .init(name: "MacDroid", type: "_macdroid._tcp")
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: self?.onListening?(true)
                    case .failed, .cancelled: self?.onListening?(false)
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                self.listener = listener
                listener.start(queue: self.queue)
            } catch {
                self.onListening?(false)
            }
        }
    }

    func stop() {
        queue.sync {
            fileReceiver.abortAll()
            activePeer?.cancel()
            activePeer = nil
            listener?.cancel()
            listener = nil
            onListening?(false)
        }
    }

    func confirmPairing() {
        queue.async { [weak self] in self?.activePeer?.confirmPairing() }
    }

    func sendSMS(address: String, body: String) {
        queue.async { [weak self] in
            self?.activePeer?.send(kind: .smsSend, payload: SendSMSPayload(address: address, body: body))
        }
    }

    func requestSMSSync() {
        queue.async { [weak self] in
            self?.activePeer?.send(kind: .smsSyncRequest, payload: EmptyPayload())
        }
    }

    func replyToNotification(notificationId: String, actionId: String, text: String) {
        queue.async { [weak self] in
            self?.activePeer?.send(
                kind: .notificationAction,
                payload: NotificationActionRequest(
                    notificationId: notificationId,
                    actionId: actionId,
                    text: text
                )
            )
        }
    }

    func startCall(address: String) {
        queue.async { [weak self] in
            self?.activePeer?.send(kind: .callStart, payload: StartCallPayload(address: address))
        }
    }

    func cancelIncomingFileTransfer(_ transferId: UUID) {
        queue.async { [weak self] in
            guard let self, let peer = self.activePeer else { return }
            self.fileReceiver.cancel(.init(transferId: transferId)) { [weak self, weak peer] status, name in
                peer?.send(kind: .fileTransferStatus, payload: status)
                self?.onIncomingFileStatus?(status, name)
            }
        }
    }

    func sendFiles(
        _ urls: [URL],
        progress: @escaping @Sendable (_ fraction: Double, _ fileName: String) -> Void
    ) async throws {
        let sizes = try urls.map { url -> Int64 in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize else {
                throw MacBridgeError.unreadableFile(url.lastPathComponent)
            }
            return Int64(size)
        }
        var selectedBytes: Int64 = 0
        for (index, size) in sizes.enumerated() {
            guard size <= InputLimits.maximumFileBytes else {
                throw MacBridgeError.fileTooLarge(urls[index].lastPathComponent)
            }
            guard selectedBytes <= InputLimits.maximumTransferBytes - size else {
                throw MacBridgeError.transferTooLarge
            }
            selectedBytes += size
        }
        let totalBytes = max(selectedBytes, 1)
        var allBytesSent: Int64 = 0

        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            let transferId = UUID()
            do {
                let fileSize = sizes[index]
                let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
                try await send(
                    kind: .fileTransferStart,
                    payload: FileTransferStartPayload(
                        transferId: transferId,
                        fileName: url.lastPathComponent,
                        size: fileSize,
                        mimeType: mimeType
                    )
                )

                let handle: FileHandle
                do {
                    handle = try FileHandle(forReadingFrom: url)
                } catch {
                    throw MacBridgeError.unreadableFile(url.lastPathComponent)
                }
                defer { try? handle.close() }

                var offset: Int64 = 0
                var hasher = SHA256()
                while let data = try handle.read(upToCount: 256 * 1_024), !data.isEmpty {
                    try Task.checkCancellation()
                    hasher.update(data: data)
                    try await send(
                        kind: .fileTransferChunk,
                        payload: FileTransferChunkPayload(
                            transferId: transferId,
                            offset: offset,
                            data: data
                        )
                    )
                    offset += Int64(data.count)
                    allBytesSent += Int64(data.count)
                    progress(min(Double(allBytesSent) / Double(totalBytes), 1), url.lastPathComponent)
                }

                try Task.checkCancellation()
                let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                try await send(
                    kind: .fileTransferComplete,
                    payload: FileTransferCompletePayload(transferId: transferId, sha256: checksum)
                )
            } catch {
                try? await send(
                    kind: .fileTransferCancel,
                    payload: FileTransferCancelPayload(transferId: transferId)
                )
                throw error
            }
        }
    }

    private func send<Payload: Encodable & Sendable>(
        kind: BridgeMessageKind,
        payload: Payload
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let peer = self?.activePeer else {
                    continuation.resume(throwing: MacBridgeError.notConnected)
                    return
                }
                peer.send(kind: kind, payload: payload) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        // A random LAN client must not be able to evict an authenticated phone.
        guard activePeer == nil else {
            connection.cancel()
            return
        }
        let peer = MacPeerConnection(connection: connection, identity: identity, queue: queue)
        activePeer = peer
        peer.onPairingCode = { [weak self] code, name in self?.onPairingCode?(code, name) }
        peer.onConnected = { [weak self] name in self?.onConnected?(name) }
        peer.onDisconnected = { [weak self, weak peer] in
            guard let self, self.activePeer === peer else { return }
            self.fileReceiver.abortAll()
            self.activePeer = nil
            self.onDisconnected?()
        }
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, self.activePeer === peer else { return }
            if self.handleIncomingFileMessage(message, peer: peer) { return }
            self.onMessage?(message)
        }
        peer.start()
    }

    private func handleIncomingFileMessage(_ message: BridgeMessage, peer: MacPeerConnection?) -> Bool {
        let publish: MacFileTransferReceiver.StatusHandler = { [weak self, weak peer] status, name in
            peer?.send(kind: .fileTransferStatus, payload: status)
            self?.onIncomingFileStatus?(status, name)
        }
        switch message.kind {
        case .fileTransferStart:
            guard let payload = try? message.decodePayload(as: FileTransferStartPayload.self) else {
                peer?.cancel()
                return true
            }
            fileReceiver.start(payload, status: publish)
            return true
        case .fileTransferChunk:
            guard let payload = try? message.decodePayload(as: FileTransferChunkPayload.self) else {
                peer?.cancel()
                return true
            }
            fileReceiver.append(payload, status: publish)
            return true
        case .fileTransferComplete:
            guard let payload = try? message.decodePayload(as: FileTransferCompletePayload.self) else {
                peer?.cancel()
                return true
            }
            fileReceiver.complete(payload, status: publish)
            return true
        case .fileTransferCancel:
            guard let payload = try? message.decodePayload(as: FileTransferCancelPayload.self) else {
                peer?.cancel()
                return true
            }
            fileReceiver.cancel(payload, status: publish)
            return true
        default:
            return false
        }
    }
}

private final class MacPeerConnection: @unchecked Sendable {
    var onPairingCode: (@Sendable (String, String) -> Void)?
    var onConnected: (@Sendable (String) -> Void)?
    var onDisconnected: (@Sendable () -> Void)?
    var onMessage: (@Sendable (BridgeMessage) -> Void)?

    private let connection: NWConnection
    private let identity: PairingIdentity
    private let queue: DispatchQueue
    private let localOffer: PairingOffer
    private var remoteOffer: PairingOffer?
    private var channel: SecureChannel?
    private var localConfirmed = false
    private var remoteConfirmed = false
    private var didBecomeConnected = false
    private var sendSequence: UInt64 = 0
    private var receivedSequence: UInt64?

    init(connection: NWConnection, identity: PairingIdentity, queue: DispatchQueue) {
        self.connection = connection
        self.identity = identity
        self.queue = queue
        self.localOffer = identity.offer(
            deviceName: "MacDroid",
            nonce: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        )
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendPacket(.init(type: .offer, offer: self.localOffer))
                self.receiveHeader()
            case .failed, .cancelled:
                self.onDisconnected?()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.didBecomeConnected else { return }
            self.cancel()
        }
    }

    func cancel() { connection.cancel() }

    func confirmPairing() {
        guard channel != nil else { return }
        localConfirmed = true
        sendPacket(.init(type: .confirmation, confirmed: true))
        finishPairingIfReady()
    }

    func send<Payload: Encodable & Sendable>(
        kind: BridgeMessageKind,
        payload: Payload,
        completion: (@Sendable (Error?) -> Void)? = nil
    ) {
        guard didBecomeConnected, let channel else {
            completion?(MacBridgeError.notConnected)
            return
        }
        do {
            sendSequence += 1
            let message = try BridgeMessage.make(sequence: sendSequence, kind: kind, payload: payload)
            sendPacket(.init(type: .envelope, envelope: try channel.seal(message)), completion: completion)
        } catch {
            completion?(MacBridgeError.encodingFailed)
        }
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, data.count == 4 {
                let length = data.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
                guard length > 0, length <= 4_194_304 else { self.cancel(); return }
                self.receiveBody(length: Int(length))
            } else if complete || error != nil {
                self.onDisconnected?()
            } else {
                self.receiveHeader()
            }
        }
    }

    private func receiveBody(length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, complete, error in
            guard let self else { return }
            guard let data, data.count == length else {
                if complete || error != nil { self.onDisconnected?() } else { self.cancel() }
                return
            }
            do {
                self.handle(try JSONDecoder.macDroid.decode(TransportPacket.self, from: data))
                self.receiveHeader()
            } catch {
                self.cancel()
            }
        }
    }

    private func handle(_ packet: TransportPacket) {
        switch packet.type {
        case .offer:
            guard remoteOffer == nil, !didBecomeConnected, let offer = packet.offer else {
                cancel()
                return
            }
            do {
                let result = try identity.deriveSession(with: offer, localOffer: localOffer)
                remoteOffer = offer
                channel = SecureChannel(key: result.key)
                if MacTrustStore.isTrusted(offer) {
                    localConfirmed = true
                    sendPacket(.init(type: .confirmation, confirmed: true))
                    finishPairingIfReady()
                } else {
                    onPairingCode?(result.verificationCode, offer.deviceName)
                }
            } catch { cancel() }
        case .confirmation:
            guard channel != nil, packet.confirmed == true else { cancel(); return }
            remoteConfirmed = true
            finishPairingIfReady()
        case .envelope:
            guard didBecomeConnected, let channel, let envelope = packet.envelope else { cancel(); return }
            do {
                let message = try channel.open(envelope, lastReceivedSequence: receivedSequence)
                receivedSequence = message.sequence
                onMessage?(message)
            } catch { cancel() }
        case .error:
            break
        }
    }

    private func finishPairingIfReady() {
        guard localConfirmed, remoteConfirmed, !didBecomeConnected, let remoteOffer else { return }
        MacTrustStore.trust(remoteOffer)
        didBecomeConnected = true
        onConnected?(remoteOffer.deviceName)
        send(kind: .smsSyncRequest, payload: EmptyPayload())
    }

    private func sendPacket(
        _ packet: TransportPacket,
        completion: (@Sendable (Error?) -> Void)? = nil
    ) {
        do {
            let body = try JSONEncoder.macDroid.encode(packet)
            guard body.count <= InputLimits.maximumFrameBytes else {
                throw MacBridgeError.encodingFailed
            }
            var length = UInt32(body.count).bigEndian
            var frame = withUnsafeBytes(of: &length) { Data($0) }
            frame.append(body)
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.onDisconnected?() }
                completion?(error)
            })
        } catch {
            completion?(error)
            cancel()
        }
    }
}

private enum MacIdentityStore {
    private static let service = "se.macdroid.identity"
    private static let account = "bridge-x25519-v1"

    private struct StoredIdentity: Codable {
        let deviceId: UUID
        let privateKey: Data
    }

    static func loadOrCreate() -> PairingIdentity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data),
           let identity = try? PairingIdentity(deviceId: stored.deviceId, rawPrivateKey: stored.privateKey) {
            return identity
        }

        let identity = PairingIdentity()
        let stored = StoredIdentity(deviceId: identity.deviceId, privateKey: identity.privateKeyData)
        if let data = try? JSONEncoder().encode(stored) {
            let add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String: data
            ]
            SecItemAdd(add as CFDictionary, nil)
        }
        return identity
    }
}

private enum MacTrustStore {
    private static let service = "se.macdroid.trusted-peer-x25519-v1"

    static func isTrusted(_ offer: PairingOffer) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: offer.deviceId.uuidString.lowercased(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
            && (result as? Data) == offer.publicKey
    }

    static func trust(_ offer: PairingOffer) {
        let account = offer.deviceId.uuidString.lowercased()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: offer.publicKey]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess { return }

        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: offer.publicKey
        ]
        SecItemAdd(add as CFDictionary, nil)
    }
}
