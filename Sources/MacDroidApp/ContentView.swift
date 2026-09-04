import MacDroidCore
import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                phoneHeader
                List(AppSection.allCases, selection: $store.selection) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(section)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            Group {
                switch store.selection ?? .overview {
                case .overview: OverviewView()
                case .notifications: NotificationsView()
                case .messages: MessagesView()
                case .calls: CallsView()
                case .files: FileTransferView()
                case .security: SecurityView()
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(.indigo)
    }

    private var phoneHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.indigo.gradient)
                    .frame(width: 42, height: 42)
                Image(systemName: "smartphone")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(store.phoneName).font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(store.isConnected ? .green : .secondary).frame(width: 7, height: 7)
                    Text(store.isConnected ? "Ansluten · 82 %" : "Frånkopplad")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OverviewView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "God eftermiddag", subtitle: "Din telefon är nära och synkroniserad.")
                HStack(spacing: 16) {
                    statusCard("Aviseringar", value: "\(store.notifications.count)", icon: "bell.fill", color: .orange)
                    statusCard("Batteri", value: "82 %", icon: "battery.75percent", color: .green)
                    statusCard("Anslutning", value: "Direkt", icon: "wifi", color: .indigo)
                }
                Text("Snabbåtgärder").font(.title2.bold())
                HStack(spacing: 12) {
                    quickButton("Nytt SMS", icon: "square.and.pencil", section: .messages)
                    quickButton("Ring", icon: "phone", section: .calls)
                    quickButton("Skicka fil", icon: "paperplane", section: .files)
                }
                Text("Senaste aviseringar").font(.title2.bold())
                ForEach(store.notifications.prefix(3)) { notification in
                    NotificationRow(notification: notification)
                }
            }
            .padding(32)
        }
    }

    private func statusCard(_ title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 38, height: 38)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading) {
                Text(value).font(.title3.bold())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }

    private func quickButton(_ title: String, icon: String, section: AppSection) -> some View {
        Button { store.selection = section } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity).padding(.vertical, 9)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

struct NotificationsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Aviseringar", subtitle: "Speglade direkt från telefonen.")
            if store.notifications.isEmpty {
                ContentUnavailableView("Inga aviseringar", systemImage: "bell.slash")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.notifications) { NotificationRow(notification: $0) }
                    }
                }
            }
        }
        .padding(32)
    }
}

struct NotificationRow: View {
    @EnvironmentObject private var store: AppStore
    let notification: NotificationPayload

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "app.badge.fill")
                .font(.title2)
                .foregroundStyle(.indigo)
                .frame(width: 42, height: 42)
                .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(notification.appName).font(.caption.bold()).foregroundStyle(.secondary)
                    Text(notification.postedAt, style: .relative).font(.caption).foregroundStyle(.tertiary)
                }
                Text(notification.title).font(.headline)
                Text(notification.isSensitive ? "Innehållet är dolt på telefonen" : notification.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.dismiss(notification) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}

struct MessagesView: View {
    private enum FocusField: Hashable {
        case search, reply, recipient, body
    }

    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @State private var selectedID: String?
    @State private var draft = ""
    @State private var search = ""
    @State private var showsNewMessage = false
    @State private var newRecipient = ""
    @State private var newBody = ""
    @FocusState private var focusedField: FocusField?

    private var visibleConversations: [Conversation] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.conversations }
        return store.conversations.filter { conversation in
            conversation.name.localizedCaseInsensitiveContains(query)
                || conversation.address.localizedCaseInsensitiveContains(query)
                || conversation.messages.contains { $0.body.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("SMS", systemImage: "message.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.blue)
                Text("Historik från \(store.phoneName)")
                    .foregroundStyle(.secondary)
                Spacer()
                Label(store.isConnected ? "Ansluten" : "Frånkopplad", systemImage: store.isConnected ? "lock.shield.fill" : "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(store.isConnected ? .green : .secondary)
                Button { store.refreshSMS() } label: {
                    Label("Uppdatera", systemImage: "arrow.clockwise")
                }
                Button { openWindow(id: "rcs") } label: {
                    Label("RCS", systemImage: "message.badge.waveform.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                Button {
                    showsNewMessage = true
                    DispatchQueue.main.async { focusedField = .recipient }
                } label: {
                    Label("Nytt SMS", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            Divider()

            HSplitView {
                VStack(spacing: 0) {
                    TextField("Sök i SMS", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .search)
                        .padding(12)
                    Divider()
                    if visibleConversations.isEmpty {
                        ContentUnavailableView(
                            search.isEmpty ? "Ingen SMS-historik" : "Inga träffar",
                            systemImage: search.isEmpty ? "message.badge" : "magnifyingglass",
                            description: Text(search.isEmpty ? "Tryck Uppdatera för att hämta historiken från telefonen." : "Prova ett annat sökord.")
                        )
                    } else {
                        List(visibleConversations, selection: $selectedID) { conversation in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(conversation.name).font(.headline)
                                    if conversation.messages.last?.transport == .rcs {
                                        Text("RCS/Chatt")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .foregroundStyle(.blue)
                                            .background(.blue.opacity(0.12), in: Capsule())
                                    }
                                    Spacer()
                                    if let last = conversation.messages.last {
                                        Text(last.timestamp, style: .date)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Text(conversation.messages.last?.body ?? "")
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            .tag(conversation.id)
                        }
                    }
                }
                .frame(minWidth: 300, idealWidth: 350, maxWidth: 480)

                if let conversation = store.conversations.first(where: { $0.id == selectedID }) {
                    let latest = conversation.messages.last
                    let isRCS = latest?.transport == .rcs
                    let canReply = store.isConnected
                        && (!isRCS || (latest?.replyNotificationId != nil && latest?.replyActionId != nil))
                    VStack(spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 7) {
                                    Text(conversation.name).font(.headline)
                                    if isRCS {
                                        Text("RCS/Chatt")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.blue)
                                    }
                                }
                                Text(conversation.address).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(conversation.messages.count) meddelanden")
                                .font(.caption).foregroundStyle(.secondary)
                            if !isRCS {
                                Button { store.startCall(address: conversation.address) } label: {
                                    Image(systemName: "phone")
                                }
                                .buttonStyle(.bordered)
                                .disabled(!store.isConnected)
                            }
                        }
                        .padding()
                        Divider()
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(conversation.messages) { message in
                                    HStack {
                                        if message.direction == .outgoing { Spacer(minLength: 110) }
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(message.body).textSelection(.enabled)
                                            Text(message.timestamp, format: .dateTime.day().month().hour().minute())
                                                .font(.caption2)
                                                .foregroundStyle(message.direction == .outgoing ? .white.opacity(0.72) : .secondary)
                                        }
                                        .padding(.horizontal, 13)
                                        .padding(.vertical, 9)
                                        .background(
                                            message.direction == .outgoing ? Color.blue : Color.secondary.opacity(0.14),
                                            in: RoundedRectangle(cornerRadius: 14)
                                        )
                                        .foregroundStyle(message.direction == .outgoing ? .white : .primary)
                                        if message.direction == .incoming { Spacer(minLength: 110) }
                                    }
                                }
                            }
                            .padding()
                        }
                        Divider()
                        HStack {
                            TextField(isRCS ? "Svara via RCS-aviseringen" : "Svara via telefonen", text: $draft)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .reply)
                                .onSubmit(send)
                            Button(action: send) {
                                Image(systemName: "arrow.up.circle.fill").font(.title2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canReply)
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView("Välj en konversation", systemImage: "message")
                        .frame(minWidth: 500)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.title == "SMS" })?.makeKeyAndOrderFront(nil)
            store.refreshSMS()
            selectedID = selectedID ?? store.conversations.first?.id
            DispatchQueue.main.async { focusedField = selectedID == nil ? .search : .reply }
        }
        .onChange(of: store.conversations.map(\.id)) {
            if selectedID == nil || !store.conversations.contains(where: { $0.id == selectedID }) {
                selectedID = store.conversations.first?.id
            }
        }
        .onChange(of: selectedID) {
            if selectedID != nil { focusedField = .reply }
        }
        .sheet(isPresented: $showsNewMessage) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Nytt SMS").font(.title2.bold())
                TextField("Telefonnummer", text: $newRecipient)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .recipient)
                TextField("Meddelande", text: $newBody, axis: .vertical)
                    .lineLimit(4...8)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .body)
                HStack {
                    Spacer()
                    Button("Avbryt") { showsNewMessage = false }
                    Button("Skicka") { sendNewMessage() }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            newRecipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || newBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || !store.isConnected
                        )
                }
            }
            .padding(24)
            .frame(width: 440)
            .onAppear { focusedField = .recipient }
        }
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let selectedID else { return }
        store.send(body: body, to: selectedID)
        draft = ""
    }

    private func sendNewMessage() {
        let body = newBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipient = newRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !recipient.isEmpty else { return }
        store.send(body: body, toAddress: recipient)
        selectedID = store.conversations.first(where: { $0.address == recipient })?.id
        newRecipient = ""
        newBody = ""
        showsNewMessage = false
    }
}

struct CallsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var number = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Samtal", subtitle: "Ring och hantera Galaxy-samtal från datorn.")
            VStack(spacing: 16) {
                HStack {
                    Circle()
                        .fill(store.bluetoothCallConnection == .connected ? .green : .gray)
                        .frame(width: 9, height: 9)
                    Text(bluetoothStatus)
                    Spacer()
                    if store.bluetoothCallConnection != .connected {
                        Button("Anslut Bluetooth") { store.connectBluetoothCalls() }
                            .disabled(store.bluetoothCallConnection == .connecting)
                    }
                }

                if store.bluetoothCallPhase == .ringing {
                    Text(store.bluetoothCaller ?? "Okänt nummer").font(.title2.bold())
                    HStack {
                        Button("Avvisa") { store.endBluetoothCall() }
                            .buttonStyle(.bordered)
                        Button("Svara") { store.answerBluetoothCall() }
                            .buttonStyle(.borderedProminent).tint(.green)
                    }
                } else if store.bluetoothCallPhase == .active || store.bluetoothCallPhase == .outgoing {
                    Text(store.bluetoothCallPhase == .active ? "Samtal pågår" : "Ringer…")
                        .font(.title2.bold())
                    Button("Lägg på") { store.endBluetoothCall() }
                        .buttonStyle(.borderedProminent).tint(.red)
                } else {
                TextField("Telefonnummer", text: $number).font(.title2).textFieldStyle(.roundedBorder)
                    Button { store.startCall(address: number) } label: {
                        Label(store.bluetoothCallConnection == .connected ? "Ring från Mac" : "Ring från telefonen", systemImage: "phone.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!store.isConnected && store.bluetoothCallConnection != .connected))
                }
                Text("Bluetooth HFP styr samtalet från Macen. På macOS 15 stannar mobilnätssamtalets ljud på telefonen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(maxWidth: 480)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
            Spacer()
        }
        .padding(32)
    }

    private var bluetoothStatus: String {
        switch store.bluetoothCallConnection {
        case .unavailable: "Ingen parkopplad Galaxy hittades"
        case .disconnected: "Bluetooth-samtal är frånkopplat"
        case .connecting: "Ansluter Bluetooth-samtal…"
        case .connected: "Bluetooth-samtal anslutet · ljud på telefonen"
        case .failed(let reason): reason
        }
    }
}

struct SecurityView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Säkerhet", subtitle: "Din anslutning är privat och verifierad.")
            Label("End-to-end-kryptering aktiv", systemImage: "checkmark.shield.fill")
                .font(.title3.bold()).foregroundStyle(.green)
            securityRow("Nycklar", "X25519-parning och AES-256-GCM per session", "key.fill")
            securityRow("Nätverk", "Direkt på lokalt nätverk; ingen central lagring", "network")
            securityRow("Telefon", "Privata nycklar sparas i Android Keystore", "smartphone")
            securityRow("Mac", "Privata nycklar sparas i Keychain", "laptopcomputer")
            Spacer()
        }
        .padding(32)
    }

    private func securityRow(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).frame(width: 32).foregroundStyle(.indigo)
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}
