import CryptoKit
import Foundation
import Security

enum SlackPKCEFailureCode: String, Codable, Sendable {
    case randomGenerationFailed = "slack_pkce_random_generation_failed"
    case invalidRandomByteCount = "slack_pkce_invalid_random_byte_count"
    case invalidVerifier = "slack_pkce_invalid_verifier"
}

struct SlackPKCEFailure: Error, Equatable, Sendable, LocalizedError {
    let code: SlackPKCEFailureCode

    var reasonCode: String { code.rawValue }

    var errorDescription: String? {
        switch code {
        case .randomGenerationFailed:
            "Secure random generation failed."
        case .invalidRandomByteCount:
            "Secure random generation returned an invalid byte count."
        case .invalidVerifier:
            "The PKCE verifier is invalid."
        }
    }
}

protocol SlackSecureRandomGenerating: Sendable {
    func bytes(count: Int) throws -> Data
}

struct SystemSlackSecureRandomGenerator: SlackSecureRandomGenerating {
    func bytes(count: Int) throws -> Data {
        guard count > 0 else { throw SlackPKCEFailure(code: .invalidRandomByteCount) }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else { throw SlackPKCEFailure(code: .randomGenerationFailed) }
        return data
    }
}

struct SlackPKCEMaterial: Equatable, Sendable {
    let verifier: String
    let challenge: String
    let state: String
}

struct SlackPKCEGenerator: Sendable {
    static let randomByteCount = 32
    static let encodedCharacterCount = 43

    private let random: any SlackSecureRandomGenerating

    init(random: any SlackSecureRandomGenerating = SystemSlackSecureRandomGenerator()) {
        self.random = random
    }

    func generate() throws -> SlackPKCEMaterial {
        let verifierBytes = try random.bytes(count: Self.randomByteCount)
        let stateBytes = try random.bytes(count: Self.randomByteCount)
        guard verifierBytes.count == Self.randomByteCount, stateBytes.count == Self.randomByteCount else {
            throw SlackPKCEFailure(code: .invalidRandomByteCount)
        }

        let verifier = Self.base64URLEncoded(verifierBytes)
        let state = Self.base64URLEncoded(stateBytes)
        guard Self.isValidVerifier(verifier), state.count == Self.encodedCharacterCount else {
            throw SlackPKCEFailure(code: .invalidVerifier)
        }

        return SlackPKCEMaterial(
            verifier: verifier,
            challenge: try Self.s256Challenge(for: verifier),
            state: state
        )
    }

    static func s256Challenge(for verifier: String) throws -> String {
        guard isValidVerifier(verifier), let data = verifier.data(using: .ascii) else {
            throw SlackPKCEFailure(code: .invalidVerifier)
        }
        return base64URLEncoded(Data(SHA256.hash(data: data)))
    }

    static func isValidVerifier(_ verifier: String) -> Bool {
        guard (43...128).contains(verifier.utf8.count), verifier.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return verifier.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
