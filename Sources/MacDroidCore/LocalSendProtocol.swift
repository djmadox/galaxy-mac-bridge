import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers

public enum LocalSendProtocol {
    public static let version = "2.2"
    public static let port = 53_317
    public static let multicastAddress = "224.0.0.167"
    public static let registerPath = "/api/localsend/v2/register"
    public static let prepareUploadPath = "/api/localsend/v2/prepare-upload"
    public static let uploadPath = "/api/localsend/v2/upload"
    public static let cancelPath = "/api/localsend/v2/cancel"
}

public struct LocalSendDevice: Codable, Equatable, Sendable, Identifiable {
    public enum DeviceType: String, Codable, Sendable {
        case mobile, desktop, web, headless, server
    }

    public enum Transport: String, Codable, Sendable {
        case http, https
    }

    public var id: String { fingerprint }
    public let alias: String
    public let version: String
    public let deviceModel: String?
    public let deviceType: DeviceType?
    public let fingerprint: String
    public let port: Int?
    public let `protocol`: Transport?
    public let download: Bool?
    public let announce: Bool?

    public init(
        alias: String,
        version: String = LocalSendProtocol.version,
        deviceModel: String? = nil,
        deviceType: DeviceType? = nil,
        fingerprint: String,
        port: Int? = LocalSendProtocol.port,
        protocol: Transport? = .https,
        download: Bool? = false,
        announce: Bool? = nil
    ) {
        self.alias = alias
        self.version = version
        self.deviceModel = deviceModel
        self.deviceType = deviceType
        self.fingerprint = fingerprint
        self.port = port
        self.protocol = `protocol`
        self.download = download
        self.announce = announce
    }

    public func baseURL(host: String) -> URL? {
        var components = URLComponents()
        components.scheme = (`protocol` ?? .https).rawValue
        components.host = host
        components.port = port ?? LocalSendProtocol.port
        return components.url
    }
}

public struct LocalSendFile: Codable, Equatable, Sendable, Identifiable {
    public struct Metadata: Codable, Equatable, Sendable {
        public let modified: String?
        public let accessed: String?
    }

    public let id: String
    public let fileName: String
    public let size: Int64
    public let fileType: String
    public let sha256: String?
    public let preview: String?
    public let metadata: Metadata?

    public init(
        id: String = UUID().uuidString,
        fileName: String,
        size: Int64,
        fileType: String,
        sha256: String? = nil,
        preview: String? = nil,
        metadata: Metadata? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.size = size
        self.fileType = fileType
        self.sha256 = sha256
        self.preview = preview
        self.metadata = metadata
    }
}

public struct LocalSendTransferFile: Sendable {
    public let url: URL
    public let descriptor: LocalSendFile

    public init(url: URL, calculateChecksum: Bool = true) throws {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .contentAccessDateKey,
            .isRegularFileKey
        ])
        guard values.isRegularFile == true else { throw LocalSendError.notARegularFile }

        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let checksum = calculateChecksum ? try Self.sha256(of: url) : nil
        let formatter = ISO8601DateFormatter()
        self.url = url
        self.descriptor = LocalSendFile(
            fileName: url.lastPathComponent,
            size: Int64(values.fileSize ?? 0),
            fileType: type,
            sha256: checksum,
            metadata: .init(
                modified: values.contentModificationDate.map(formatter.string(from:)),
                accessed: values.contentAccessDate.map(formatter.string(from:))
            )
        )
    }

    private static func sha256(of url: URL) throws -> String {
        guard let stream = InputStream(url: url) else { throw LocalSendError.fileCannotBeRead }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? LocalSendError.fileCannotBeRead }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct LocalSendPrepareUploadRequest: Codable, Equatable, Sendable {
    public let info: LocalSendDevice
    public let files: [String: LocalSendFile]

    public init(info: LocalSendDevice, files: [String: LocalSendFile]) {
        self.info = info
        self.files = files
    }
}

public struct LocalSendPrepareUploadResponse: Codable, Equatable, Sendable {
    public let sessionId: String
    public let files: [String: String]
}

public enum LocalSendError: Error, Equatable {
    case notARegularFile
    case fileCannotBeRead
    case invalidEndpoint
    case invalidResponse
    case pinRequired
    case rejected
    case receiverBusy
    case rateLimited
    case checksumMismatch
    case httpStatus(Int)
}

/// LocalSend v2.2-compatible sender. Files are streamed from disk by URLSession.
public actor LocalSendClient {
    private let localDevice: LocalSendDevice

    public init(alias: String, fingerprint: String = UUID().uuidString.lowercased()) {
        self.localDevice = LocalSendDevice(
            alias: alias,
            deviceModel: "Mac",
            deviceType: .desktop,
            fingerprint: fingerprint,
            port: LocalSendProtocol.port,
            protocol: .https,
            download: false
        )
    }

    public func send(
        _ transferFiles: [LocalSendTransferFile],
        to remote: LocalSendDevice,
        host: String,
        pin: String? = nil
    ) async throws {
        guard let baseURL = remote.baseURL(host: host) else { throw LocalSendError.invalidEndpoint }
        let session = Self.session(for: remote)
        var descriptors: [String: LocalSendFile] = [:]
        for file in transferFiles { descriptors[file.descriptor.id] = file.descriptor }

        let prepareURL = try Self.url(baseURL, path: LocalSendProtocol.prepareUploadPath, query: pin.map {
            [URLQueryItem(name: "pin", value: $0)]
        } ?? [])
        var request = URLRequest(url: prepareURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.macDroid.encode(
            LocalSendPrepareUploadRequest(info: localDevice, files: descriptors)
        )
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalSendError.invalidResponse }
        if http.statusCode == 204 { return }
        try Self.validate(http.statusCode)
        let prepared = try JSONDecoder.macDroid.decode(LocalSendPrepareUploadResponse.self, from: body)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for file in transferFiles {
                guard let token = prepared.files[file.descriptor.id] else { continue }
                group.addTask {
                    let uploadURL = try Self.url(baseURL, path: LocalSendProtocol.uploadPath, query: [
                        URLQueryItem(name: "sessionId", value: prepared.sessionId),
                        URLQueryItem(name: "fileId", value: file.descriptor.id),
                        URLQueryItem(name: "token", value: token)
                    ])
                    var upload = URLRequest(url: uploadURL)
                    upload.httpMethod = "POST"
                    upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    let (_, response) = try await session.upload(for: upload, fromFile: file.url)
                    guard let http = response as? HTTPURLResponse else { throw LocalSendError.invalidResponse }
                    try Self.validate(http.statusCode)
                }
            }
            try await group.waitForAll()
        }
    }

    private nonisolated static func session(for remote: LocalSendDevice) -> URLSession {
        guard remote.protocol == .https else { return .shared }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        return URLSession(
            configuration: configuration,
            delegate: CertificatePinningDelegate(expectedFingerprint: remote.fingerprint),
            delegateQueue: nil
        )
    }

    private nonisolated static func url(_ base: URL, path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw LocalSendError.invalidEndpoint
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw LocalSendError.invalidEndpoint }
        return url
    }

    private nonisolated static func validate(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401: throw LocalSendError.pinRequired
        case 403: throw LocalSendError.rejected
        case 409: throw LocalSendError.receiverBusy
        case 422: throw LocalSendError.checksumMismatch
        case 429: throw LocalSendError.rateLimited
        default: throw LocalSendError.httpStatus(status)
        }
    }
}

private final class CertificatePinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let expectedFingerprint: String

    init(expectedFingerprint: String) {
        self.expectedFingerprint = expectedFingerprint
            .lowercased()
            .filter { $0.isHexDigit }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let certificateData = SecCertificateCopyData(certificate) as Data
        let actual = SHA256.hash(data: certificateData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actual == expectedFingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
