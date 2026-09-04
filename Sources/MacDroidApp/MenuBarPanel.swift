import AppKit
import SwiftUI

private enum QuickPanel {
    case phone, settings
}

struct MenuBarPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @State private var panel: QuickPanel?
    @State private var number = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 15) {
                glossyButton(
                    title: "Samtal",
                    icon: "phone.fill",
                    color: Color(red: 0.20, green: 0.86, blue: 0.42),
                    selected: panel == .phone
                ) { toggle(.phone) }

                glossyButton(
                    title: "SMS",
                    icon: "message.fill",
                    color: Color(red: 0.18, green: 0.55, blue: 1.0),
                    selected: false
                ) {
                    panel = nil
                    store.refreshSMS()
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "sms")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.windows.first(where: { $0.title == "SMS" })?.makeKeyAndOrderFront(nil)
                    }
                }

                glossyButton(
                    title: "Inställningar",
                    icon: "gearshape.fill",
                    color: Color(white: 0.78),
                    selected: panel == .settings
                ) { toggle(.settings) }
            }
            .padding(14)

            if let notification = store.notifications.first {
                Divider().overlay(.white.opacity(0.12))
                Button {
                    panel = nil
                    store.selection = .notifications
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "main")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.windows.first(where: { $0.title == "MacDroid" })?.makeKeyAndOrderFront(nil)
                    }
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: notification.packageName == "android.telecom"
                              ? "phone.badge.waveform.fill" : "bell.fill")
                            .font(.title3)
                            .foregroundStyle(notification.packageName == "android.telecom" ? .green : .orange)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notification.title.isEmpty ? notification.appName : notification.title)
                                .font(.subheadline.bold())
                                .lineLimit(1)
                            Text(notification.isSensitive ? "Innehållet är dolt" : notification.body)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let panel {
                Divider().overlay(.white.opacity(0.12))
                detail(panel)
                    .padding(16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: 356)
        .background(GlossyBackground())
        .preferredColorScheme(.dark)
        .animation(.snappy(duration: 0.22), value: panel)
    }

    private func toggle(_ value: QuickPanel) {
        panel = panel == value ? nil : value
    }

    private func glossyButton(
        title: String,
        icon: String,
        color: Color,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.34), color.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.46), color.opacity(0.35), .white.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: selected ? 1.5 : 1
                        )
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(color)
                        .shadow(color: color.opacity(0.6), radius: 7)
                }
                .frame(width: 60, height: 48)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func detail(_ panel: QuickPanel) -> some View {
        switch panel {
        case .phone:
            VStack(alignment: .leading, spacing: 12) {
                panelHeader("Samtal", detail: bluetoothStatus)

                if store.bluetoothCallPhase == .ringing {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Inkommande samtal")
                            .font(.caption).foregroundStyle(.white.opacity(0.58))
                        Text(store.bluetoothCaller ?? "Okänt nummer")
                            .font(.headline)
                        HStack {
                            Button("Avvisa") { store.endBluetoothCall() }
                                .buttonStyle(GlossyActionStyle(tint: .red))
                            Button("Svara") { store.answerBluetoothCall() }
                                .buttonStyle(GlossyActionStyle(tint: .green))
                        }
                    }
                } else if store.bluetoothCallPhase == .active || store.bluetoothCallPhase == .outgoing {
                    Text(store.bluetoothCallPhase == .active ? "Samtal pågår" : "Ringer…")
                        .font(.headline)
                    Button("Lägg på") { store.endBluetoothCall() }
                        .buttonStyle(GlossyActionStyle(tint: .red))
                } else {
                    TextField("Telefonnummer", text: $number)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    Button { store.startCall(address: number) } label: {
                        Label(store.bluetoothCallConnection == .connected ? "Ring från Mac" : "Ring via Galaxy", systemImage: "phone.arrow.up.right.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlossyActionStyle(tint: .green))
                    .disabled(number.trimmingCharacters(in: .whitespaces).isEmpty || (!store.isConnected && store.bluetoothCallConnection != .connected))
                }

                if store.bluetoothCallConnection != .connected {
                    Button {
                        store.connectBluetoothCalls()
                    } label: {
                        Label(store.bluetoothCallConnection == .connecting ? "Ansluter…" : "Anslut Bluetooth-samtal", systemImage: "wave.3.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlossyActionStyle(tint: .blue))
                    .disabled(store.bluetoothCallConnection == .connecting)
                }
                Text(bluetoothDetail)
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
            }
        case .settings:
            VStack(alignment: .leading, spacing: 13) {
                panelHeader("Anslutning", detail: store.phoneName)
                settingRow("Status", value: store.isConnected ? "Ansluten" : "Frånkopplad", color: store.isConnected ? .green : .gray)
                settingRow("Transport", value: "Lokalt · krypterat", color: .blue)
                settingRow("Batteri", value: "82 %", color: .green)
                if let pairingCode = store.pairingCode {
                    VStack(spacing: 8) {
                        Text("Jämför koden med telefonen")
                            .font(.caption).foregroundStyle(.white.opacity(0.62))
                        Text(pairingCode)
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .tracking(5)
                        Button("Koderna matchar") { store.confirmPairing() }
                            .buttonStyle(GlossyActionStyle(tint: .green))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                } else if !store.isConnected {
                    Text(store.isListening ? "Öppna MacDroid på telefonen för att parkoppla." : "Startar lokal anslutning…")
                        .font(.caption).foregroundStyle(.white.opacity(0.52))
                }
                Divider().overlay(.white.opacity(0.12))
                SettingsLink {
                    Label("Öppna alla inställningar", systemImage: "gear")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlossyActionStyle(tint: .gray))
                Button(role: .destructive) {
                    store.quitApplication()
                } label: {
                    Label("Avsluta MacDroid", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlossyActionStyle(tint: .red))
            }
        }
    }

    private func panelHeader(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(store.isConnected ? .green : .gray).frame(width: 6, height: 6)
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.52))
            }
        }
    }

    private func settingRow(_ title: String, value: String, color: Color) -> some View {
        HStack {
            Text(title).foregroundStyle(.white.opacity(0.68))
            Spacer()
            Circle().fill(color).frame(width: 7, height: 7)
            Text(value)
        }
        .font(.caption)
    }

    private var bluetoothStatus: String {
        switch store.bluetoothCallConnection {
        case .unavailable: "Ingen parkopplad Galaxy"
        case .disconnected: "Bluetooth frånkopplad"
        case .connecting: "Bluetooth ansluter"
        case .connected: "Bluetooth ansluten"
        case .failed: "Bluetooth-fel"
        }
    }

    private var bluetoothDetail: String {
        switch store.bluetoothCallConnection {
        case .unavailable:
            "Parkoppla telefonen med macOS Bluetooth-inställningar först."
        case .failed(let reason):
            reason
        case .connected:
            "Ring, svara och lägg på från Macen. Samtalsljudet stannar på telefonen."
        default:
            "Anslut bara när du vill använda Macens högtalare och mikrofon för samtal."
        }
    }

}

private struct GlossyBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [Color.black.opacity(0.82), Color.black.opacity(0.94)],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                colors: [.white.opacity(0.10), .clear, .white.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct GlossyActionStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 9)
            .background(
                LinearGradient(
                    colors: [tint.opacity(configuration.isPressed ? 0.38 : 0.58), tint.opacity(0.22)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            )
    }
}

struct SettingsPanel: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        TabView {
            Form {
                Section("Parkopplad telefon") {
                    LabeledContent("Enhet", value: store.phoneName)
                    Toggle("Anslut automatiskt på lokala nätverket", isOn: $store.isConnected)
                }
                Section("Integritet") {
                    Toggle("Spegla aviseringar", isOn: .constant(true))
                    Toggle("Synka SMS", isOn: .constant(true))
                    Text("Samtalsljudet stannar på telefonen och fångas aldrig av MacDroid.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Bluetooth-samtal") {
                    LabeledContent("Status", value: bluetoothSettingsStatus)
                    Button("Anslut Galaxy för samtal") { store.connectBluetoothCalls() }
                        .disabled(store.bluetoothCallConnection == .connecting || store.bluetoothCallConnection == .connected)
                    if store.bluetoothCallConnection == .connected {
                        Button("Koppla från samtalsljud") { store.disconnectBluetoothCalls() }
                    }
                }
                Section("Filer") {
                    Text("Inbyggd krypterad överföring · SHA-256-verifiering")
                }
                Section {
                    Button("Avsluta MacDroid", role: .destructive) {
                        store.quitApplication()
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("Allmänt", systemImage: "gear") }

            FileTransferView()
                .tabItem { Label("Filöverföring", systemImage: "arrow.left.arrow.right") }
        }
        .padding(.top, 8)
    }

    private var bluetoothSettingsStatus: String {
        switch store.bluetoothCallConnection {
        case .unavailable: "Ingen parkopplad telefon"
        case .disconnected: "Frånkopplad"
        case .connecting: "Ansluter…"
        case .connected: "Ansluten"
        case .failed(let reason): reason
        }
    }
}
