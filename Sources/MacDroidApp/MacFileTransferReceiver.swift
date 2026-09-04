import CryptoKit
import Darwin
import Foundation
import MacDroidCore

final class MacFileTransferReceiver: @unchecked Sendable {
    typealias StatusHandler = @Sendable (FileTransferStatusPayload, String) -> Void

    private struct Transfer {
        let fileName: String
        let temporaryURL: URL
        let handle: FileHandle
        let expectedSize: Int64
        var received: Int64 = 0
        var digest = SHA256()
    }

    private var active: [UUID: Transfer] = [:]
    private let fileManager = FileManager.default

    init() {
        // Clean up only this app's private partial files after an unclean system shutdown.
        if let directory = try? destinationDirectory(),
           let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            contents
                .filter { $0.lastPathComponent.hasPrefix(".macdroid-") && $0.pathExtension == "part" }
                .forEach { try? fileManager.removeItem(at: $0) }
        }
    }

    func start(_ payload: FileTransferStartPayload, status: StatusHandler) {
        do {
            guard active[payload.transferId] == nil else { throw ReceiverError.duplicate }
            guard active.count < 4 else { throw ReceiverError.tooMany }
            guard let name = InputValidation.safeFileName(payload.fileName) else {
                throw ReceiverError.invalidName
            }
            guard (0...InputLimits.maximumFileBytes).contains(payload.size) else {
                throw ReceiverError.invalidSize
            }

            let directory = try destinationDirectory()
            let temporaryURL = directory.appendingPathComponent(".macdroid-\(payload.transferId.uuidString).part")
            let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw ReceiverError.cannotCreate }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            active[payload.transferId] = Transfer(
                fileName: name,
                temporaryURL: temporaryURL,
                handle: handle,
                expectedSize: payload.size
            )
            status(.init(
                transferId: payload.transferId,
                state: .accepted,
                bytesReceived: 0,
                totalBytes: payload.size
            ), name)
        } catch {
            status(.init(
                transferId: payload.transferId,
                state: .failed,
                bytesReceived: 0,
                totalBytes: max(payload.size, 0),
                error: error.localizedDescription
            ), InputValidation.safeFileName(payload.fileName) ?? "Fil")
        }
    }

    func append(_ payload: FileTransferChunkPayload, status: StatusHandler) {
        guard var transfer = active.removeValue(forKey: payload.transferId) else {
            status(.init(
                transferId: payload.transferId,
                state: .failed,
                bytesReceived: 0,
                totalBytes: 0,
                error: ReceiverError.missing.localizedDescription
            ), "Fil")
            return
        }

        do {
            guard payload.offset == transfer.received else { throw ReceiverError.outOfOrder }
            guard !payload.data.isEmpty, payload.data.count <= 256 * 1_024 else {
                throw ReceiverError.invalidChunk
            }
            guard transfer.received + Int64(payload.data.count) <= transfer.expectedSize else {
                throw ReceiverError.tooMuchData
            }
            try transfer.handle.write(contentsOf: payload.data)
            transfer.digest.update(data: payload.data)
            transfer.received += Int64(payload.data.count)
            active[payload.transferId] = transfer
            status(.init(
                transferId: payload.transferId,
                state: .progress,
                bytesReceived: transfer.received,
                totalBytes: transfer.expectedSize
            ), transfer.fileName)
        } catch {
            discard(transfer)
            status(.init(
                transferId: payload.transferId,
                state: .failed,
                bytesReceived: transfer.received,
                totalBytes: transfer.expectedSize,
                error: error.localizedDescription
            ), transfer.fileName)
        }
    }

    func complete(_ payload: FileTransferCompletePayload, status: StatusHandler) {
        guard let transfer = active.removeValue(forKey: payload.transferId) else {
            status(.init(
                transferId: payload.transferId,
                state: .failed,
                bytesReceived: 0,
                totalBytes: 0,
                error: ReceiverError.missing.localizedDescription
            ), "Fil")
            return
        }

        do {
            guard transfer.received == transfer.expectedSize else { throw ReceiverError.incomplete }
            let expectedHash = payload.sha256.lowercased()
            guard expectedHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw ReceiverError.invalidHash
            }
            let actualHash = transfer.digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard actualHash == expectedHash else { throw ReceiverError.hashMismatch }
            try transfer.handle.synchronize()
            try transfer.handle.close()
            let destination = uniqueDestination(named: transfer.fileName, in: transfer.temporaryURL.deletingLastPathComponent())
            try fileManager.moveItem(at: transfer.temporaryURL, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            status(.init(
                transferId: payload.transferId,
                state: .completed,
                bytesReceived: transfer.received,
                totalBytes: transfer.expectedSize
            ), destination.lastPathComponent)
        } catch {
            discard(transfer)
            status(.init(
                transferId: payload.transferId,
                state: .failed,
                bytesReceived: transfer.received,
                totalBytes: transfer.expectedSize,
                error: error.localizedDescription
            ), transfer.fileName)
        }
    }

    func cancel(_ payload: FileTransferCancelPayload, status: StatusHandler) {
        guard let transfer = active.removeValue(forKey: payload.transferId) else { return }
        discard(transfer)
        status(.init(
            transferId: payload.transferId,
            state: .cancelled,
            bytesReceived: transfer.received,
            totalBytes: transfer.expectedSize,
            error: "Överföringen avbröts."
        ), transfer.fileName)
    }

    func abortAll() {
        active.values.forEach(discard)
        active.removeAll(keepingCapacity: false)
    }

    private func destinationDirectory() throws -> URL {
        guard let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw ReceiverError.cannotCreate
        }
        let directory = downloads.appendingPathComponent("MacDroid", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func uniqueDestination(named name: String, in directory: URL) -> URL {
        let original = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: original.path) else { return original }
        let extensionName = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        for number in 1...9_999 {
            let candidateName = extensionName.isEmpty
                ? "\(stem) (\(number))"
                : "\(stem) (\(number)).\(extensionName)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    private func discard(_ transfer: Transfer) {
        try? transfer.handle.close()
        try? fileManager.removeItem(at: transfer.temporaryURL)
    }
}

private enum ReceiverError: LocalizedError {
    case duplicate, tooMany, invalidName, invalidSize, cannotCreate, missing
    case outOfOrder, invalidChunk, tooMuchData, incomplete, invalidHash, hashMismatch

    var errorDescription: String? {
        switch self {
        case .duplicate: "Överföringen finns redan."
        case .tooMany: "För många samtidiga överföringar."
        case .invalidName: "Ogiltigt filnamn."
        case .invalidSize: "Ogiltig filstorlek."
        case .cannotCreate: "Macen kunde inte skapa filen."
        case .missing: "Överföringen saknas."
        case .outOfOrder: "Fildata kom i fel ordning."
        case .invalidChunk: "Ogiltig delstorlek."
        case .tooMuchData: "Filen är större än utlovat."
        case .incomplete: "Filen blev inte komplett."
        case .invalidHash: "Ogiltig kontrollsumma."
        case .hashMismatch: "Filens kontrollsumma stämmer inte."
        }
    }
}
