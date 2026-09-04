import Foundation
import IOBluetooth
import OSLog

enum BluetoothCallConnection: Equatable, Sendable {
    case unavailable
    case disconnected
    case connecting
    case connected
    case failed(String)
}

enum BluetoothCallPhase: String, Sendable {
    case idle
    case ringing
    case outgoing
    case active
}

struct BluetoothCallSnapshot: Sendable {
    let connection: BluetoothCallConnection
    let phase: BluetoothCallPhase
    let caller: String?
}

/// Makes the Mac act as a Bluetooth Hands-Free device, like a car kit.
/// The Galaxy remains the cellular audio gateway; call audio travels over SCO.
final class BluetoothCallManager: NSObject, @unchecked Sendable {
    var onUpdate: (@Sendable (BluetoothCallSnapshot) -> Void)?

    private let logger = Logger(subsystem: "se.macdroid.desktop", category: "BluetoothCalls")
    private let queue = DispatchQueue(label: "se.macdroid.bluetooth-hfp")
    private var handsFree: IOBluetoothHandsFreeDevice?
    private var connection: BluetoothCallConnection = .disconnected
    private var phase: BluetoothCallPhase = .idle
    private var caller: String?
    private var connectAttempt = 0

    func connect() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.handsFree?.isConnected != true else {
                self.connection = .connected
                self.publish()
                return
            }
            guard let phone = Self.pairedGalaxy() else {
                self.logger.error("No paired Galaxy HFP device found")
                self.connection = .unavailable
                self.publish()
                return
            }

            self.connection = .connecting
            self.logger.info("Starting HFP connection to remembered paired device")
            self.connectAttempt += 1
            let attempt = self.connectAttempt
            self.publish()
            guard let handsFree = IOBluetoothHandsFreeDevice(device: phone, delegate: self) else {
                self.logger.error("IOBluetoothHandsFreeDevice initialization failed")
                self.connection = .failed("Bluetooth HFP kunde inte startas.")
                self.publish()
                return
            }
            // CLIP, remote volume, enhanced call state/control and codec negotiation.
            // These capabilities must be advertised before the HFP service-level connection.
            handsFree.supportedFeatures = 0xF4
            self.handsFree = handsFree
            handsFree.connect()
            self.queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self,
                      self.connectAttempt == attempt,
                      self.connection == .connecting else { return }
                self.connection = .failed("Telefonen svarade inte på Bluetooth HFP.")
                self.logger.error("HFP connection timed out")
                self.handsFree?.disconnect()
                self.publish()
            }
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.handsFree?.disconnect()
        }
    }

    func dial(_ number: String) {
        queue.async { [weak self] in
            guard let self, self.handsFree?.isConnected == true else { return }
            self.caller = number
            self.phase = .outgoing
            self.publish()
            self.handsFree?.dialNumber(number)
        }
    }

    func answer() {
        queue.async { [weak self] in
            guard let self, self.handsFree?.isConnected == true else { return }
            self.handsFree?.acceptCallOnPhone()
        }
    }

    func hangUp() {
        queue.async { [weak self] in self?.handsFree?.endCall() }
    }

    private func publish() {
        onUpdate?(
            BluetoothCallSnapshot(
                connection: connection,
                phase: phase,
                caller: caller
            )
        )
    }

    private static func pairedGalaxy() -> IOBluetoothDevice? {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let rememberedAddress = UserDefaults.standard.string(forKey: "bluetoothCallDeviceAddress")
        if let rememberedAddress,
           let remembered = devices.first(where: { $0.addressString == rememberedAddress }) {
            return remembered
        }

        let galaxy = devices.first { device in
            let name = device.nameOrAddress.lowercased()
            return name.contains("s26 ultra") || name.contains("galaxy")
        }
        if let galaxy {
            UserDefaults.standard.set(galaxy.addressString, forKey: "bluetoothCallDeviceAddress")
        }
        return galaxy
    }
}

extension BluetoothCallManager: IOBluetoothHandsFreeDeviceDelegate {
    func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        queue.async { [weak self] in
            guard let self else { return }
            self.logger.info("HFP connection completed with IOReturn \(status.intValue, privacy: .public)")
            self.connection = status.intValue == kIOReturnSuccess
                ? .connected
                : .failed("Bluetooth-anslutningen misslyckades (\(status.intValue)).")
            self.publish()
            if status.intValue == kIOReturnSuccess {
                self.handsFree?.currentCallList()
            }
        }
    }

    func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        queue.async { [weak self] in
            self?.logger.info("HFP disconnected with IOReturn \(status.intValue, privacy: .public)")
            self?.connection = .disconnected
            self?.phase = .idle
            self?.publish()
        }
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingCallFrom number: String!) {
        queue.async { [weak self] in
            self?.logger.notice("HFP reported an incoming call")
            self?.caller = number
            self?.phase = .ringing
            self?.publish()
        }
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callSetupMode mode: NSNumber!) {
        queue.async { [weak self] in
            guard let self else { return }
            self.logger.notice("HFP call setup mode changed to \(mode.intValue, privacy: .public)")
            switch mode.intValue {
            case 1: self.phase = .ringing
            case 2, 3: self.phase = .outgoing
            default: if self.phase != .active { self.phase = .idle }
            }
            self.publish()
        }
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isCallActive active: NSNumber!) {
        queue.async { [weak self] in
            guard let self else { return }
            self.logger.notice("HFP active call state changed to \(active.boolValue, privacy: .public)")
            self.phase = active.boolValue ? .active : .idle
            if !active.boolValue {
                self.caller = nil
            }
            self.publish()
        }
    }
}
