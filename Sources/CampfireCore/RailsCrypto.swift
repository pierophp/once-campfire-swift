import Crypto
import Foundation

public final class RailsKeyGenerator: @unchecked Sendable {
    private let secret: Data
    private let lock = NSLock()
    private var cache: [CacheKey: Data] = [:]
    private struct CacheKey: Hashable { let salt: String; let length: Int }

    public init(secretKeyBase: String) { secret = Data(secretKeyBase.utf8) }

    public func generate(salt: String, length: Int = 64) -> Data {
        precondition(length >= 0)
        let cacheKey = CacheKey(salt: salt, length: length)
        lock.lock(); defer { lock.unlock() }
        if let key = cache[cacheKey] { return key }
        let key = Self.pbkdf2(password: secret, salt: Data(salt.utf8), length: length)
        cache[cacheKey] = key
        return key
    }

    private static func pbkdf2(password: Data, salt: Data, length: Int) -> Data {
        guard length > 0 else { return Data() }
        let blockCount = (length + 31) / 32
        var output = Data(); output.reserveCapacity(blockCount * 32)
        for block in 1...blockCount {
            var input = salt
            input.append(contentsOf: [UInt8((block >> 24) & 255), UInt8((block >> 16) & 255), UInt8((block >> 8) & 255), UInt8(block & 255)])
            var u = Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: password)))
            var result = u
            if 1000 > 1 {
                for _ in 2...1000 {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: SymmetricKey(data: password)))
                    for index in result.indices { result[index] ^= u[index] }
                }
            }
            output.append(result)
        }
        return output.prefix(length)
    }
}

public enum MessageVerifierDigest { case sha1, sha256 }
public enum MessageVerifierEncoding { case strict, urlSafe, urlSafePadded }

public struct MessageVerifier {
    private let secret: SymmetricKey
    private let digest: MessageVerifierDigest
    private let encoding: MessageVerifierEncoding
    public init(secret: Data, digest: MessageVerifierDigest = .sha1, encoding: MessageVerifierEncoding = .strict) { self.secret = SymmetricKey(data: secret); self.digest = digest; self.encoding = encoding }

    public func sign(serialized: String) -> String {
        let payload = encoded(Data(serialized.utf8))
        let signature = mac(Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(payload)--\(signature)"
    }

    public func verify(_ token: String) -> String? {
        guard let range = token.range(of: "--", options: .backwards) else { return nil }
        let payload = String(token[..<range.lowerBound])
        let signature = String(token[range.upperBound...])
        guard !payload.isEmpty, !signature.isEmpty,
              constantTimeEqual(Data(signature.utf8), Data(mac(Data(payload.utf8)).map { String(format: "%02x", $0) }.joined().utf8)),
              let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").paddingBase64()),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    public func generate(value: String, purpose: String, expiresAt: String? = nil) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("\"\(value)\"".utf8)
        let inner = data.base64EncodedString()
        let exp = expiresAt.map { "\"\(jsonEscape($0))\"" } ?? "null"
        let envelope = "{\"_rails\":{\"message\":\"\(inner)\",\"exp\":\(exp),\"pur\":\"\(jsonEscape(purpose))\"}}"
        return sign(serialized: envelope)
    }

    public func verifyCookie(_ token: String, name: String, now: String) -> String? {
        guard let serialized = verify(token), let data = serialized.data(using: .utf8) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rails = root["_rails"] as? [String: Any] else {
            return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
        }
        if let expiry = rails["exp"] as? String, now >= expiry { return nil }
        if let purpose = rails["pur"] as? String, !purpose.isEmpty, purpose != "cookie.\(name)" { return nil }
        if let message = rails["message"] as? String,
           let bytes = Data(base64Encoded: message),
           let value = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) as? String { return value }
        return nil
    }

    public func verify(_ token: String, purpose: String, now: String) -> String? {
        guard let envelope = verify(token), let data = envelope.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rails = root["_rails"] as? [String: Any],
              let message = rails["message"] as? String,
              let storedPurpose = rails["pur"] as? String, storedPurpose == purpose,
              let dumped = Data(base64Encoded: message), let value = try? JSONSerialization.jsonObject(with: dumped, options: [.fragmentsAllowed]) as? String else { return nil }
        if let exp = rails["exp"] as? String, now >= exp { return nil }
        return value
    }

    private func encoded(_ data: Data) -> String {
        let strict = data.base64EncodedString()
        switch encoding {
        case .strict: return strict
        case .urlSafe: return strict.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        case .urlSafePadded: return strict.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
    }

    fileprivate func mac(_ data: Data) -> [UInt8] {
        switch digest {
        case .sha1: return Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: secret))
        case .sha256: return Array(HMAC<SHA256>.authenticationCode(for: data, using: secret))
        }
    }
}

public enum MessageEncryptorError: Error { case invalidNonce }

public struct MessageEncryptor {
    private let key: SymmetricKey
    public init(key: Data) { precondition(key.count == 32, "AES-256-GCM requires a 32-byte key"); self.key = SymmetricKey(data: key) }

    public func encrypt(_ plaintext: Data) throws -> String {
        try encrypt(plaintext, nonce: Data(AES.GCM.Nonce()))
    }

    public func encrypt(_ plaintext: Data, nonce: Data) throws -> String {
        guard nonce.count == 12, let gcmNonce = try? AES.GCM.Nonce(data: nonce) else {
            throw MessageEncryptorError.invalidNonce
        }
        let box = try AES.GCM.seal(plaintext, using: key, nonce: gcmNonce)
        return "\(box.ciphertext.base64EncodedString())--\(nonce.base64EncodedString())--\(box.tag.base64EncodedString())"
    }

    public func encryptCookie(serializedValue: String, purpose: String, expiresAt: String? = nil) throws -> String {
        let dumped = Data(serializedValue.utf8).base64EncodedString()
        let exp = expiresAt.map { "\"\(jsonEscape($0))\"" } ?? "null"
        let envelope = "{\"_rails\":{\"message\":\"\(dumped)\",\"exp\":\(exp),\"pur\":\"\(jsonEscape(purpose))\"}}"
        return try encrypt(Data(envelope.utf8))
    }

    public func decrypt(_ message: String) -> Data? {
        let parts = message.components(separatedBy: "--")
        guard parts.count == 3,
              let ciphertext = Data(base64Encoded: parts[0]),
              let nonceData = Data(base64Encoded: parts[1]), nonceData.count == 12,
              let tag = Data(base64Encoded: parts[2]), tag.count == 16,
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plaintext = try? AES.GCM.open(box, using: key) else { return nil }
        return plaintext
    }
}

public struct RailsSignedID {
    private let verifier: MessageVerifier
    public init(secretKeyBase: String) {
        let key = RailsKeyGenerator(secretKeyBase: secretKeyBase).generate(salt: "active_record/signed_id", length: 64)
        verifier = MessageVerifier(secret: key, digest: .sha256, encoding: .urlSafe)
    }
    public func generate(model: String, id: Int, purpose: String) -> String {
        let combined = "\(underscore(model))/\(purpose)"
        let payload = "{\"_rails\":{\"data\":\(id),\"pur\":\"\(jsonEscape(combined))\"}}"
        return verifier.sign(serialized: payload)
    }
    public func verify(_ token: String, model: String, purpose: String, now: String) -> Int? {
        guard let payload = verifier.verify(token), let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rails = root["_rails"] as? [String: Any], rails["pur"] as? String == "\(underscore(model))/\(purpose)",
              let id = rails["data"] as? Int else { return nil }
        if let exp = rails["exp"] as? String, now >= exp { return nil }
        return id
    }
}

public struct RailsSignedGlobalID {
    private let verifier: MessageVerifier
    public init(secretKeyBase: String) {
        let key = RailsKeyGenerator(secretKeyBase: secretKeyBase).generate(salt: "signed_global_ids", length: 64)
        verifier = MessageVerifier(secret: key, digest: .sha1, encoding: .urlSafePadded)
    }
    public func generate(uri: String, purpose: String, expiresAt: String? = nil) -> String {
        let data = jsonEscape(uri)
        var fields = "\"data\":\"\(data)\""
        if let expiresAt { fields += ",\"exp\":\"\(jsonEscape(expiresAt))\"" }
        fields += ",\"pur\":\"\(jsonEscape(purpose))\""
        return verifier.sign(serialized: "{\"_rails\":{\(fields)}}")
    }
    public func locate(_ token: String, purpose: String, now: String) -> String? {
        guard let serialized = verifier.verify(token), let data = serialized.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rails = root["_rails"] as? [String: Any], rails["pur"] as? String == purpose,
              let uri = rails["data"] as? String else { return nil }
        if let expiry = rails["exp"] as? String, now > expiry { return nil }
        return uri
    }
}

public struct RailsTurboStreamSigner {
    private let verifier: MessageVerifier
    public init(secretKeyBase: String) {
        let key = RailsKeyGenerator(secretKeyBase: secretKeyBase).generate(salt: "turbo/signed_stream_verifier_key", length: 64)
        verifier = MessageVerifier(secret: key, digest: .sha256)
    }
    public func verify(_ token: String) -> String? {
        guard let serialized = verifier.verify(token), let data = serialized.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else { return nil }
        return value
    }
    public func sign(_ streamName: String) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: streamName, options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(jsonEscape(streamName))\""
        return verifier.sign(serialized: json)
    }
}

private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}

private func jsonEscape(_ value: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
    return String(decoding: data.dropFirst().dropLast(), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
}

private func underscore(_ name: String) -> String {
    let characters = Array(name.replacingOccurrences(of: "::", with: "/"))
    var output = ""
    for (index, character) in characters.enumerated() {
        if character.isASCII && character.isUppercase {
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let followsLowerOrDigit = previous.map { $0.isLowercase || $0.isNumber } ?? false
            let acronymBoundary = previous?.isUppercase == true && next?.isLowercase == true
            if followsLowerOrDigit || acronymBoundary { output.append("_") }
            output.append(character.lowercased())
        } else {
            output.append(character == "-" ? "_" : character)
        }
    }
    return output
}

private extension String {
    func paddingBase64() -> String {
        let remainder = count % 4
        return remainder == 0 ? self : self + String(repeating: "=", count: 4 - remainder)
    }
}
