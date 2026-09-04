import AppKit
import Foundation
import MacDroidCore
import UserNotifications

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Översikt"
    case notifications = "Aviseringar"
    case messages = "Meddelanden"
    case calls = "Samtal"
    case files = "Filer"
    case security = "Säkerhet"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .notifications: "bell.badge"
        case .messages: "message.fill"
        case .calls: "phone.fill"
        case .files: "arrow.left.arrow.right.circle.fill"
        case .security: "lock.shield.fill"
        }
    }
}

struct Conversation: Identifiable {
    let id: String
    let name: String
    let address: String
    var messages: [SMSMessagePayload]
}

@MainActor
final class AppStore: ObservableObject {
    @Published var selection: AppSection? = .overview
    @Published var isConnected = false
    @Published var isListening = false
    @Published var pairingCode: String?
    @Published var phoneName = "Ingen telefon"
    @Published var batteryLevel = 0.82
    @Published var notifications: [NotificationPayload] = []
    @Published var conversations: [Conversation] = []
    @Published var isTransferringFiles = false
    @Published var fileTransferProgress = 0.0
    @Published var fileTransferStatus = ""
    @Published var bluetoothCallConnection: BluetoothCallConnection = .disconnected
    @Published var bluetoothCallPhase: BluetoothCallPhase = .idle
    @Published var bluetoothCaller: String?

    private let bridge = MacBridgeServer()
    private let bluetoothCalls = BluetoothCallManager()
    private var smsSyncBuffer: [String: SMSMessagePayload] = [:]
    private var isReceivingFullSMSSync = false
    private var expectedFileCompletions = 0
    private var completedFileTransfers = 0
    private var fileTransferTask: Task<Void, Never>?
    private var activeIncomingTransferID: UUID?
    private var isShuttingDown = false

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        bridge.onListening = { [weak self] ready in
            Task { @MainActor in self?.isListening = ready }
        }
        bridge.onPairingCode = { [weak self] code, deviceName in
            Task { @MainActor in
                self?.pairingCode = code
                self?.phoneName = deviceName
                self?.isConnected = false
            }
        }
        bridge.onConnected = { [weak self] deviceName in
            Task { @MainActor in
                self?.phoneName = deviceName
                self?.pairingCode = nil
                self?.isConnected = true
            }
        }
        bridge.onDisconnected = { [weak self] in
            Task { @MainActor in
                self?.isConnected = false
                self?.pairingCode = nil
            }
        }
        bridge.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        bridge.onIncomingFileStatus = { [weak self] status, fileName in
            Task { @MainActor in self?.handleIncomingFile(status, fileName: fileName) }
        }
        bluetoothCalls.onUpdate = { [weak self] snapshot in
            Task { @MainActor in self?.applyBluetoothCall(snapshot) }
        }
        bridge.start()
        bluetoothCalls.connect()
    }

    func confirmPairing() {
        bridge.confirmPairing()
    }

    func refreshSMS() {
        bridge.requestSMSSync()
    }

    func dismiss(_ notification: NotificationPayload) {
        notifications.removeAll { $0.id == notification.id }
    }

    func send(body: String, to conversationID: String) {
        guard InputValidation.isValidMessageText(body) else { return }
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let conversation = conversations[index]
        let latest = conversation.messages.last

        if latest?.transport == .rcs {
            guard let notificationId = latest?.replyNotificationId,
                  let actionId = latest?.replyActionId else {
                return
            }
            conversations[index].messages.append(
                SMSMessagePayload(
                    id: UUID().uuidString,
                    threadId: conversationID,
                    address: conversation.address,
                    contactName: conversation.name,
                    body: body,
                    timestamp: Date(),
                    direction: .outgoing,
                    deliveryState: .pending,
                    transport: .rcs,
                    replyNotificationId: notificationId,
                    replyActionId: actionId
                )
            )
            bridge.replyToNotification(
                notificationId: notificationId,
                actionId: actionId,
                text: body
            )
            return
        }

        conversations[index].messages.append(
            SMSMessagePayload(
                id: UUID().uuidString,
                threadId: conversationID,
                address: conversation.address,
                contactName: conversation.name,
                body: body,
                timestamp: Date(),
                direction: .outgoing,
                deliveryState: .pending,
                transport: latest?.transport,
                replyNotificationId: latest?.replyNotificationId,
                replyActionId: latest?.replyActionId
            )
        )
        guard let address = InputValidation.normalizedPhoneAddress(conversation.address) else { return }
        bridge.sendSMS(address: address, body: body)
    }

    func send(body: String, toAddress address: String) {
        guard InputValidation.isValidMessageText(body),
              let normalized = InputValidation.normalizedPhoneAddress(address) else { return }
        if let conversation = conversations.first(where: { $0.address == normalized }) {
            send(body: body, to: conversation.id)
            return
        }
        let id = UUID().uuidString
        conversations.insert(Conversation(id: id, name: normalized, address: normalized, messages: []), at: 0)
        send(body: body, to: id)
    }

    func startCall(address: String) {
        guard let number = InputValidation.normalizedPhoneAddress(address) else { return }
        if bluetoothCallConnection == .connected {
            bluetoothCalls.dial(number)
        } else {
            bridge.startCall(address: number)
        }
    }

    func connectBluetoothCalls() {
        bluetoothCalls.connect()
    }

    func disconnectBluetoothCalls() {
        bluetoothCalls.disconnect()
    }

    func answerBluetoothCall() {
        bluetoothCalls.answer()
    }

    func endBluetoothCall() {
        bluetoothCalls.hangUp()
    }

    func sendFiles(_ urls: [URL]) {
        guard isConnected else {
            fileTransferStatus = "Anslut telefonen innan du skickar."
            return
        }
        guard !urls.isEmpty, !isTransferringFiles else { return }

        isTransferringFiles = true
        fileTransferProgress = 0
        fileTransferStatus = "Förbereder säker överföring…"
        expectedFileCompletions = urls.count
        completedFileTransfers = 0

        fileTransferTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await bridge.sendFiles(urls) { [weak self] fraction, fileName in
                    Task { @MainActor in
                        self?.fileTransferProgress = fraction
                        self?.fileTransferStatus = "Skickar \(fileName)…"
                    }
                }
                if completedFileTransfers < expectedFileCompletions {
                    fileTransferStatus = "Verifierar filerna på telefonen…"
                }
            } catch is CancellationError {
                isTransferringFiles = false
                fileTransferStatus = "Filöverföringen avbröts."
            } catch {
                isTransferringFiles = false
                fileTransferStatus = error.localizedDescription
            }
            fileTransferTask = nil
        }
    }

    func cancelFileTransfer() {
        if let activeIncomingTransferID {
            bridge.cancelIncomingFileTransfer(activeIncomingTransferID)
            self.activeIncomingTransferID = nil
        }
        fileTransferTask?.cancel()
        fileTransferTask = nil
        isTransferringFiles = false
        fileTransferStatus = "Filöverföringen avbröts."
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        cancelFileTransfer()
        bridge.stop()
        bluetoothCalls.disconnect()
    }

    func quitApplication() {
        shutdown()
        NSApplication.shared.terminate(nil)
    }

    private func handle(_ message: BridgeMessage) {
        switch message.kind {
        case .notificationPosted:
            guard let payload = try? message.decodePayload(as: NotificationPayload.self) else { return }
            guard Self.isReasonable(payload) else { return }
            notifications.removeAll { $0.id == payload.id }
            notifications.insert(payload, at: 0)
            showSystemNotification(payload)
        case .notificationRemoved:
            guard let payload = try? message.decodePayload(as: RemovedNotificationPayload.self) else { return }
            notifications.removeAll { $0.id == payload.id }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [payload.id])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [payload.id])
        case .smsSnapshot:
            guard let snapshot = try? message.decodePayload(as: SMSSnapshotPayload.self) else { return }
            let safeMessages = snapshot.messages.filter(Self.isReasonable)
            receive(.init(messages: safeMessages, reset: snapshot.reset, complete: snapshot.complete))
        case .fileTransferStatus:
            guard let payload = try? message.decodePayload(as: FileTransferStatusPayload.self) else { return }
            switch payload.state {
            case .accepted, .progress:
                break
            case .completed:
                completedFileTransfers += 1
                if completedFileTransfers >= expectedFileCompletions {
                    fileTransferProgress = 1
                    fileTransferStatus = expectedFileCompletions == 1
                        ? "Filen är sparad i Hämtade filer/MacDroid."
                        : "Alla filer är sparade i Hämtade filer/MacDroid."
                    isTransferringFiles = false
                }
            case .cancelled:
                isTransferringFiles = false
                fileTransferStatus = "Filöverföringen avbröts."
            case .failed:
                isTransferringFiles = false
                fileTransferStatus = payload.error ?? "Filöverföringen misslyckades."
            }
        default:
            break
        }
    }

    private func handleIncomingFile(_ status: FileTransferStatusPayload, fileName: String) {
        let denominator = max(status.totalBytes, 1)
        switch status.state {
        case .accepted, .progress:
            activeIncomingTransferID = status.transferId
            isTransferringFiles = true
            fileTransferProgress = min(Double(status.bytesReceived) / Double(denominator), 1)
            fileTransferStatus = "Tar emot \(fileName) från telefonen…"
        case .completed:
            activeIncomingTransferID = nil
            isTransferringFiles = false
            fileTransferProgress = 1
            fileTransferStatus = "\(fileName) är sparad i Hämtade filer/MacDroid."
        case .cancelled:
            activeIncomingTransferID = nil
            isTransferringFiles = false
            fileTransferStatus = "Mottagningen av \(fileName) avbröts."
        case .failed:
            activeIncomingTransferID = nil
            isTransferringFiles = false
            fileTransferStatus = status.error ?? "Mottagningen av \(fileName) misslyckades."
        }
    }

    private func showSystemNotification(_ notification: NotificationPayload) {
        let content = UNMutableNotificationContent()
        content.title = notification.appName
        content.subtitle = notification.title
        content.body = notification.isSensitive
            ? "Innehållet är dolt på telefonen"
            : notification.body
        content.threadIdentifier = notification.packageName
        if notification.packageName == "android.telecom" {
            content.sound = .default
        }
        let request = UNNotificationRequest(
            identifier: notification.id,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func applyBluetoothCall(_ snapshot: BluetoothCallSnapshot) {
        let previousPhase = bluetoothCallPhase
        bluetoothCallConnection = snapshot.connection
        bluetoothCallPhase = snapshot.phase
        bluetoothCaller = snapshot.caller

        let identifier = "macdroid.bluetooth.incoming-call"
        if snapshot.phase == .ringing {
            let caller = snapshot.caller?.isEmpty == false ? snapshot.caller! : "Okänt nummer"
            let notification = NotificationPayload(
                id: identifier,
                packageName: "android.telecom",
                appName: "Telefon",
                title: "Inkommande samtal",
                body: caller,
                postedAt: Date()
            )
            notifications.removeAll { $0.id == identifier }
            notifications.insert(notification, at: 0)
            if previousPhase != .ringing {
                showSystemNotification(notification)
            }
        } else if snapshot.phase == .idle {
            notifications.removeAll { $0.id == identifier }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        }
    }

    private func receive(_ snapshot: SMSSnapshotPayload) {
        if snapshot.reset == true {
            smsSyncBuffer.removeAll(keepingCapacity: true)
            isReceivingFullSMSSync = true
        }
        if isReceivingFullSMSSync {
            snapshot.messages.forEach { smsSyncBuffer[$0.id] = $0 }
            if snapshot.complete == true {
                apply(Array(smsSyncBuffer.values))
                smsSyncBuffer.removeAll(keepingCapacity: false)
                isReceivingFullSMSSync = false
            }
            return
        }

        var merged = Dictionary(
            uniqueKeysWithValues: conversations.flatMap(\.messages).map { ($0.id, $0) }
        )
        snapshot.messages.forEach { merged[$0.id] = $0 }
        apply(Array(merged.values))
    }

    private func apply(_ messages: [SMSMessagePayload]) {
        let grouped = Dictionary(grouping: messages, by: \.threadId)
        conversations = grouped.map { threadID, messages in
            let sorted = messages.sorted { $0.timestamp < $1.timestamp }
            let last = sorted.last!
            return Conversation(
                id: threadID,
                name: last.contactName ?? last.address,
                address: last.address,
                messages: sorted
            )
        }
        .sorted { ($0.messages.last?.timestamp ?? .distantPast) > ($1.messages.last?.timestamp ?? .distantPast) }
    }

    private static func isReasonable(_ notification: NotificationPayload) -> Bool {
        notification.id.utf8.count <= 512
            && notification.packageName.utf8.count <= 256
            && notification.appName.utf8.count <= 256
            && InputValidation.isReasonableTransportText(notification.title)
            && InputValidation.isReasonableTransportText(notification.body)
            && notification.actions.count <= 32
    }

    private static func isReasonable(_ message: SMSMessagePayload) -> Bool {
        message.id.utf8.count <= 512
            && message.threadId.utf8.count <= 512
            && message.address.utf8.count <= 512
            && (message.contactName?.utf8.count ?? 0) <= 512
            && InputValidation.isReasonableTransportText(message.body)
    }

}

private struct RemovedNotificationPayload: Codable, Sendable {
    let id: String
}
