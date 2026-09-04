import Foundation
import Testing
@testable import MacDroidCore

@Test func phoneAddressNormalizationRejectsCommandSyntax() {
    #expect(InputValidation.normalizedPhoneAddress("+1 (555) 010-0100") == "+15550100100")
    #expect(InputValidation.normalizedPhoneAddress("*#06#") == nil)
    #expect(InputValidation.normalizedPhoneAddress("123;phone-context=evil") == nil)
    #expect(InputValidation.normalizedPhoneAddress(String(repeating: "1", count: 21)) == nil)
}

@Test func messageLimitsAreEnforced() {
    #expect(InputValidation.isValidMessageText("Hej"))
    #expect(!InputValidation.isValidMessageText("   \n"))
    #expect(!InputValidation.isValidMessageText(String(repeating: "x", count: InputLimits.maximumMessageBytes + 1)))
}

@Test func receivedFileNamesAreReducedToOneSafeComponent() {
    #expect(InputValidation.safeFileName("../folder\\photo\n.jpg") == ".._folder_photo_.jpg")
    #expect(InputValidation.safeFileName("..") == nil)
    #expect(InputValidation.safeFileName("   ") == nil)
    #expect(InputValidation.safeFileName(String(repeating: "a", count: 200))?.count == 180)
}

@Test func malformedPairingOffersAreRejected() throws {
    let local = PairingIdentity(deviceId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let remote = PairingIdentity(deviceId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let localOffer = local.offer(deviceName: "MacDroid", nonce: Data(repeating: 1, count: 32))
    let malformed = PairingOffer(
        deviceId: remote.deviceId,
        deviceName: "Galaxy",
        publicKey: remote.publicKeyData,
        nonce: Data(repeating: 2, count: 12)
    )

    #expect(throws: SecureChannelError.invalidOffer) {
        try local.deriveSession(with: malformed, localOffer: localOffer)
    }
}
