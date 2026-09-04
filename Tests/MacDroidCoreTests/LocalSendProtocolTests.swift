import Foundation
import Testing
@testable import MacDroidCore

@Test func localSendPreparePayloadMatchesProtocolShape() throws {
    let device = LocalSendDevice(
        alias: "MacDroid",
        deviceModel: "MacBook",
        deviceType: .desktop,
        fingerprint: "abc",
        port: 53_317,
        protocol: .https
    )
    let file = LocalSendFile(
        id: "file-1",
        fileName: "bild.png",
        size: 42,
        fileType: "image/png",
        sha256: "deadbeef"
    )
    let payload = LocalSendPrepareUploadRequest(info: device, files: [file.id: file])
    let data = try JSONEncoder.macDroid.encode(payload)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let info = try #require(object["info"] as? [String: Any])
    let files = try #require(object["files"] as? [String: Any])

    #expect(info["alias"] as? String == "MacDroid")
    #expect(info["protocol"] as? String == "https")
    #expect(files["file-1"] != nil)
}

@Test func localSendDeviceBuildsEndpoint() {
    let device = LocalSendDevice(alias: "Phone", fingerprint: "abc", port: 53_317, protocol: .https)
    #expect(device.baseURL(host: "192.168.1.9")?.absoluteString == "https://192.168.1.9:53317")
}
