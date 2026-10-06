import Foundation

/// Process-wide configuration and signers. The environment is read once: building
/// `ProcessInfo.environment` copies every variable, which dominated avatar signing.
enum AppSecrets {
    static let secretKeyBase = ProcessInfo.processInfo.environment["SECRET_KEY_BASE"] ?? "campfire-swift-development-secret-key-base"
    static let sslDisabled = ProcessInfo.processInfo.environment["DISABLE_SSL"] == "1"

    static let signedID = RailsSignedID(secretKeyBase: secretKeyBase)
    static let turboStreams = RailsTurboStreamSigner(secretKeyBase: secretKeyBase)
    static let actionText = ActionTextRenderer(secretKeyBase: secretKeyBase)
    static let cookieVerifier = MessageVerifier(secret: RailsKeyGenerator(secretKeyBase: secretKeyBase).generate(salt: "signed cookie", length: 64))
    static let sessionEncryptor = MessageEncryptor(key: RailsKeyGenerator(secretKeyBase: secretKeyBase).generate(salt: "authenticated encrypted cookie", length: 32))

    private static let streamNames = BoundedCache<String, String>(limit: 65_536)

    /// Signed Turbo stream names are deterministic, and signing serializes JSON.
    static func turboStreamName(_ name: String) -> String {
        if let cached = streamNames.value(for: name) { return cached }
        let signed = turboStreams.sign(name)
        streamNames.insert(signed, for: name)
        return signed
    }
}

/// Signed avatar IDs are a pure function of the user ID and the process secret.
enum AvatarTokens {
    private static let cache = AvatarTokenCache()

    static func token(for userID: Int64) -> String { cache.token(for: userID) }

    /// `/users/<signed id>/avatar?v=<first 14 digits of updated_at>`
    static func path(userID: Int64, updatedAt: String) -> String {
        "/users/\(token(for: userID))/avatar?v=\(avatarVersion(updatedAt))"
    }

    static func avatarVersion(_ updatedAt: String) -> String {
        var digits: [UInt8] = []
        digits.reserveCapacity(14)
        for byte in updatedAt.utf8 where byte >= 48 && byte <= 57 {
            digits.append(byte)
            if digits.count == 14 { break }
        }
        if updatedAt.utf8.allSatisfy({ $0 < 128 }) { return String(decoding: digits, as: UTF8.self) }
        // Non-ASCII digits also satisfy Character.isNumber; keep the original semantics for them.
        return String(updatedAt.filter(\.isNumber).prefix(14))
    }
}

private final class AvatarTokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [Int64: String] = [:]

    func token(for userID: Int64) -> String {
        lock.lock()
        if let cached = tokens[userID] { lock.unlock(); return cached }
        lock.unlock()
        let token = AppSecrets.signedID.generate(model: "User", id: Int(userID), purpose: "avatar")
        lock.lock()
        if tokens.count >= 100_000 { tokens.removeAll(keepingCapacity: true) }
        tokens[userID] = token
        lock.unlock()
        return token
    }
}
