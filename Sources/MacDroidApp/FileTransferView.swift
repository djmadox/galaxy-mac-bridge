import SwiftUI
import UniformTypeIdentifiers

struct FileTransferView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isImporterPresented = false
    @State private var selectedFiles: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(
                title: "Filöverföring",
                subtitle: "Skicka direkt till din parkopplade Galaxy – ingen annan app behövs."
            )

            HStack(spacing: 12) {
                Image(systemName: store.isConnected ? "lock.shield.fill" : "iphone.slash")
                    .font(.title2)
                    .foregroundStyle(store.isConnected ? .green : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.isConnected ? "Säker filkanal redo" : "Telefonen är frånkopplad")
                        .font(.headline)
                    Text(store.isConnected
                         ? "End-to-end-krypterad överföring med SHA-256-kontroll"
                         : "Öppna MacDroid på telefonen för att ansluta.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("MacDroid", systemImage: "arrow.left.arrow.right")
                    .font(.caption)
                    .foregroundStyle(store.isConnected ? .green : .secondary)
            }
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.quaternary))

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Filer att skicka").font(.headline)
                    Spacer()
                    if !selectedFiles.isEmpty && !store.isTransferringFiles {
                        Button("Rensa") { selectedFiles.removeAll() }
                    }
                    Button("Välj filer…") { isImporterPresented = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isTransferringFiles)
                }

                if selectedFiles.isEmpty {
                    ContentUnavailableView(
                        "Släpp filer här",
                        systemImage: "arrow.down.doc",
                        description: Text("Du kan också använda Välj filer.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 190)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(selectedFiles, id: \.self) { url in
                                HStack(spacing: 11) {
                                    Image(systemName: "doc.fill").foregroundStyle(.blue)
                                    Text(url.lastPathComponent).lineLimit(1)
                                    Spacer()
                                    if !store.isTransferringFiles {
                                        Button {
                                            selectedFiles.removeAll { $0 == url }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(10)
                                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .frame(minHeight: 150, maxHeight: 280)
                }
            }
            .padding(18)
            .background(.background, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.quaternary))
            .dropDestination(for: URL.self) { urls, _ in
                add(urls)
                return !urls.isEmpty
            }

            HStack(spacing: 12) {
                Button {
                    store.sendFiles(selectedFiles)
                } label: {
                    if store.isTransferringFiles {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Skicka till Galaxy", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedFiles.isEmpty || !store.isConnected || store.isTransferringFiles)

                if store.isTransferringFiles {
                    Button("Avbryt", role: .destructive) {
                        store.cancelFileTransfer()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Text("Filerna sparas i Hämtade filer/MacDroid på telefonen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.isTransferringFiles || store.fileTransferProgress > 0 {
                ProgressView(value: store.fileTransferProgress)
                    .animation(.easeInOut, value: store.fileTransferProgress)
            }
            if !store.fileTransferStatus.isEmpty {
                Text(store.fileTransferStatus).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(32)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result { add(urls) }
        }
    }

    private func add(_ urls: [URL]) {
        guard !store.isTransferringFiles else { return }
        for url in urls where !selectedFiles.contains(url) {
            selectedFiles.append(url)
        }
        store.fileTransferStatus = ""
        store.fileTransferProgress = 0
    }
}
