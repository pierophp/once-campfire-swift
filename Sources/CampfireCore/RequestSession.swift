import Foundation
import HTTPTypes
import Hummingbird

struct SignedInUser: Sendable {
    let id: Int64
    let name: String
    let updatedAt: String
    let role: Int64
    let email: String?
}

struct RequestSession: Sendable {
    let token: String
    let user: SignedInUser
    let refreshed: Bool
}

struct RailsFlash: Sendable { let notice: String?; let alert: String?; let setCookie: String? }

enum SessionPipeline {
    static func load(_ request: Request, database: SQLiteDatabase) async throws -> RequestSession? {
        guard let cookieHeader = request.headers[.cookie],
              let signedCookie = cookieValue("session_token", in: cookieHeader),
              let token = verifier().verifyCookie(signedCookie, name: "session_token", now: iso8601(Date())) else { return nil }

        // Rails performs one session lookup followed by one user lookup on the request path.
        let session = try await Task.detached {
            try database.read { connection in
                try connection.firstRow("SELECT id, user_id, julianday(last_active_at) <= julianday('now', '-1 hour') FROM sessions WHERE token=? LIMIT 1", bindings: [.text(token)])
            }
        }.value
        guard let session, let sessionID = session.integer(0), let userID = session.integer(1) else { return nil }
        let userRow = try await Task.detached {
            try database.read { connection in
                try connection.firstRow("SELECT id, name, role, email_address, updated_at FROM users WHERE id=? AND status=0 LIMIT 1", bindings: [.integer(userID)])
            }
        }.value
        guard let userRow, let id = userRow.integer(0), let name = userRow.string(1) else { return nil }
        let refreshed = session.integer(2) == 1
        if refreshed {
            try await Task.detached {
                try database.write { connection, _ in
                    try connection.execute("UPDATE sessions SET last_active_at=strftime('%Y-%m-%d %H:%M:%f','now'), updated_at=strftime('%Y-%m-%d %H:%M:%f','now') WHERE id=?", bindings: [.integer(sessionID)])
                }
            }.value
        }
        return RequestSession(token: token, user: SignedInUser(id: id, name: name, updatedAt: userRow.string(4) ?? "", role: userRow.integer(2) ?? 0, email: userRow.string(3)), refreshed: refreshed)
    }

    static func appendRefreshCookie(_ session: RequestSession, to response: inout Response) {
        guard session.refreshed else { return }
        let expiry = Calendar(identifier: .gregorian).date(byAdding: .year, value: 20, to: Date()) ?? Date()
        let value = verifier().generate(value: session.token, purpose: "cookie.session_token", expiresAt: iso8601(expiry))
        let escaped = value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")) ?? value
        response.headers[HTTPField.Name("set-cookie")!] = "session_token=\(escaped); path=/; expires=\(httpDate(expiry)); httponly; samesite=lax"
    }

    /// Open the encrypted Rails session only when layout reads flash. An empty session is left
    /// untouched, so an ordinary page read does not emit a Set-Cookie header.
    static func readFlash(_ request: Request) -> RailsFlash {
        guard let header = request.headers[.cookie], let raw = cookieValue("_campfire_session", in: header),
              let state = decodeRailsSession(raw) else { return RailsFlash(notice: nil, alert: nil, setCookie: nil) }
        let storedFlash = state["flash"] as? [String: Any] ?? [:]
        let flash = storedFlash["flashes"] as? [String: Any] ?? storedFlash
        let notice = flash["notice"] as? String
        let alert = flash["alert"] as? String
        guard notice != nil || alert != nil else { return RailsFlash(notice: nil, alert: nil, setCookie: nil) }
        var updated = state
        updated.removeValue(forKey: "flash")
        guard let bytes = try? JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]),
              let json = String(data: bytes, encoding: .utf8),
              let encrypted = try? sessionEncryptor().encryptCookie(serializedValue: json, purpose: "cookie._campfire_session") else {
            return RailsFlash(notice: notice, alert: alert, setCookie: nil)
        }
        let escaped = encrypted.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")) ?? encrypted
        return RailsFlash(notice: notice, alert: alert, setCookie: "_campfire_session=\(escaped); path=/; httponly; samesite=lax")
    }

    static func alertCookie(_ alert: String) -> String? {
        let flash: [String: Any] = ["flash": ["discard": [], "flashes": ["alert": alert]]]
        guard let bytes = try? JSONSerialization.data(withJSONObject: flash, options: [.sortedKeys]),
              let json = String(data: bytes, encoding: .utf8),
              let encrypted = try? sessionEncryptor().encryptCookie(serializedValue: json, purpose: "cookie._campfire_session") else { return nil }
        let escaped = encrypted.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")) ?? encrypted
        return "_campfire_session=\(escaped); path=/; httponly; samesite=lax"
    }

    private static func decodeRailsSession(_ value: String) -> [String: Any]? {
        guard let data = sessionEncryptor().decrypt(value),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rails = root["_rails"] as? [String: Any],
              let encoded = rails["message"] as? String, let payload = Data(base64Encoded: encoded),
              let decoded = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return decoded
    }

    private static func sessionEncryptor() -> MessageEncryptor {
        let secret = ProcessInfo.processInfo.environment["SECRET_KEY_BASE"] ?? "campfire-swift-development-secret-key-base"
        let key = RailsKeyGenerator(secretKeyBase: secret).generate(salt: "authenticated encrypted cookie", length: 32)
        return MessageEncryptor(key: key)
    }

    private static func verifier() -> MessageVerifier {
        let secret = ProcessInfo.processInfo.environment["SECRET_KEY_BASE"] ?? "campfire-swift-development-secret-key-base"
        return MessageVerifier(secret: RailsKeyGenerator(secretKeyBase: secret).generate(salt: "signed cookie", length: 64))
    }

    private static func cookieValue(_ name: String, in header: String) -> String? {
        for item in header.split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == name else { continue }
            return String(pair[1]).removingPercentEncoding ?? String(pair[1])
        }
        return nil
    }

    private static func iso8601(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    private static func httpDate(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(weekdays[(c.weekday ?? 1) - 1]), \(String(format: "%02d", c.day ?? 1)) \(months[(c.month ?? 1) - 1]) \(c.year ?? 1970) \(String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)) GMT"
    }
}
