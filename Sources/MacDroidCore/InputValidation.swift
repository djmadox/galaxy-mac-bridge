import Foundation

public enum InputLimits {
    public static let maximumMessageBytes = 16 * 1_024
    public static let maximumNotificationTextBytes = 16 * 1_024
    public static let maximumFileBytes: Int64 = 10 * 1_024 * 1_024 * 1_024
    public static let maximumTransferBytes: Int64 = 20 * 1_024 * 1_024 * 1_024
    public static let maximumFrameBytes = 4 * 1_024 * 1_024
}

public enum InputValidation {
    /// Accepts ordinary international/national numbers but rejects URI, USSD and MMI syntax.
    public static func normalizedPhoneAddress(_ input: String) -> String? {
        let separators = CharacterSet(charactersIn: " -().")
        var output = ""

        for scalar in input.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if scalar.value >= 48, scalar.value <= 57 {
                output.unicodeScalars.append(scalar)
            } else if scalar == "+", output.isEmpty {
                output.unicodeScalars.append(scalar)
            } else if separators.contains(scalar) {
                continue
            } else {
                return nil
            }
        }

        let digits = output.first == "+" ? output.dropFirst() : output[...]
        guard (1...20).contains(digits.count), digits.allSatisfy(\.isNumber) else { return nil }
        return output
    }

    public static func isValidMessageText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.utf8.count <= InputLimits.maximumMessageBytes
    }

    public static func isReasonableTransportText(_ text: String) -> Bool {
        text.utf8.count <= InputLimits.maximumNotificationTextBytes
    }

    /// Produces a single, non-hidden path component suitable for a received file.
    public static func safeFileName(_ input: String, maximumCharacters: Int = 180) -> String? {
        guard maximumCharacters > 0 else { return nil }
        let replaced = input.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == "\\" {
                return "_"
            }
            return Character(String(scalar))
        }
        let name = String(replaced)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maximumCharacters)
        let result = String(name)
        guard !result.isEmpty, result != ".", result != ".." else { return nil }
        return result
    }
}
