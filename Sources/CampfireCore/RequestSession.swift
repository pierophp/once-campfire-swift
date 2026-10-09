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
    let id: Int64
    let token: String
    let user: SignedInUser
    let refreshed: Bool
}

struct RailsFlash: Sendable { let notice: String?; let alert: String?; let setCookie: String? }

enum SessionPipeline {
    static func load(_ request: Request, database: SQLiteDatabase) async throws -> RequestSession? {
        guard let cookieHeader = request.headers[.cookie],
              let signedCookie = cookieValue("session_token", in: cookieHeader),
              let token = verifiedSessionToken(signedCookie) else { return nil }

        // Rails performs one session lookup followed by one user lookup on the request path.
        let rows = try await database.readAsync { connection -> (SQLiteRow, SQLiteRow)? in
            guard let session = try connection.firstRow("SELECT id, user_id, julianday(last_active_at) <= julianday('now', '-1 hour') FROM sessions WHERE token=? LIMIT 1", bindings: [.text(token)]),
                  let userID = session.integer(1),
                  let user = try connection.firstRow("SELECT id, name, role, email_address, updated_at FROM users WHERE id=? AND status=0 LIMIT 1", bindings: [.integer(userID)]) else { return nil }
            return (session, user)
        }
        guard let (session, userRow) = rows, let sessionID = session.integer(0),
              let id = userRow.integer(0), let name = userRow.string(1) else { return nil }
        let refreshed = session.integer(2) == 1
        if refreshed {
            try await database.writeAsync { connection, _ in
                try connection.execute("UPDATE sessions SET last_active_at=strftime('%Y-%m-%d %H:%M:%f','now'), updated_at=strftime('%Y-%m-%d %H:%M:%f','now') WHERE id=?", bindings: [.integer(sessionID)])
            }
        }
        return RequestSession(id: sessionID, token: token, user: SignedInUser(id: id, name: name, updatedAt: userRow.string(4) ?? "", role: userRow.integer(2) ?? 0, email: userRow.string(3)), refreshed: refreshed)
    }

    static func appendRefreshCookie(_ session: RequestSession, to response: inout Response) {
        guard session.refreshed else { return }
        let expiry = UTCTime.twentyYearsFromNow()
        let value = AppSecrets.cookieVerifier.generate(value: session.token, purpose: "cookie.session_token", expiresAt: UTCTime.iso8601(expiry))
        let escaped = value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")) ?? value
        response.headers[HTTPField.Name("set-cookie")!] = "session_token=\(escaped); path=/; expires=\(UTCTime.httpDate(expiry)); httponly; samesite=lax"
    }

    /// Open the encrypted Rails session only when layout reads flash. An empty session is left
    /// untouched, so an ordinary page read does not emit a Set-Cookie header.
    static func readFlash(_ request: Request) -> RailsFlash {
        guard let header = request.headers[.cookie], let raw = cookieValue("_campfire_session", in: header) else {
            return RailsFlash(notice: nil, alert: nil, setCookie: nil)
        }
        // A session without flash yields no output and no cookie; remember that outcome.
        if flashlessSessions.contains(raw) { return RailsFlash(notice: nil, alert: nil, setCookie: nil) }
        guard let state = decodeRailsSession(raw) else { return RailsFlash(notice: nil, alert: nil, setCookie: nil) }
        let storedFlash = state["flash"] as? [String: Any] ?? [:]
        let flash = storedFlash["flashes"] as? [String: Any] ?? storedFlash
        let notice = flash["notice"] as? String
        let alert = flash["alert"] as? String
        guard notice != nil || alert != nil else {
            flashlessSessions.insert(raw)
            return RailsFlash(notice: nil, alert: nil, setCookie: nil)
        }
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

    private static func sessionEncryptor() -> MessageEncryptor { AppSecrets.sessionEncryptor }

    private static let verifiedCookies = BoundedCache<String, (value: String, expiresAt: String?)>(limit: 16_384)
    private static let flashlessSessions = BoundedSet(limit: 16_384)

    /// Signature checks and JSON decoding depend only on the cookie text; expiry depends on now.
    private static func verifiedSessionToken(_ signedCookie: String) -> String? {
        let cookie: (value: String, expiresAt: String?)
        if let cached = verifiedCookies.value(for: signedCookie) {
            cookie = cached
        } else {
            guard let verified = AppSecrets.cookieVerifier.verifiedCookie(signedCookie, name: "session_token") else { return nil }
            verifiedCookies.insert(verified, for: signedCookie)
            cookie = verified
        }
        if let expiry = cookie.expiresAt, UTCTime.iso8601(UTCTime.nowSeconds()) >= expiry { return nil }
        return cookie.value
    }

    private struct CookieLookup: Hashable { let name: String; let header: String }
    private static let cookieValues = BoundedCache<CookieLookup, String?>(limit: 16_384)

    private static func cookieValue(_ name: String, in header: String) -> String? {
        cookieValues.value(for: CookieLookup(name: name, header: header)) { parseCookieValue(name, in: header) }
    }

    private static func parseCookieValue(_ name: String, in header: String) -> String? {
        for item in header.split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == name else { continue }
            if !pair[1].utf8.contains(UInt8(ascii: "%")) { return String(pair[1]) }
            return String(pair[1]).removingPercentEncoding ?? String(pair[1])
        }
        return nil
    }
}

/// A lock-protected map that forgets everything when full. For memoizing pure functions of
/// request input, where a miss only costs recomputation.
final class BoundedCache<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var values: [Key: Value] = [:]

    init(limit: Int) { self.limit = limit }

    func value(for key: Key) -> Value? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func insert(_ value: Value, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        if values.count >= limit { values.removeAll(keepingCapacity: true) }
        values[key] = value
    }

    func value(for key: Key, orCompute compute: () -> Value) -> Value {
        if let cached = value(for: key) { return cached }
        let computed = compute()
        insert(computed, for: key)
        return computed
    }
}

/// Request cookies as the handlers read them. Parsing is a pure function of the Cookie header,
/// which a client repeats verbatim, so results are memoized per header.
enum RequestCookies {
    private struct Lookup: Hashable { let name: String; let header: String }
    private static let integers = BoundedCache<Lookup, Int64?>(limit: 16_384)
    private static let values = BoundedCache<Lookup, String?>(limit: 16_384)

    /// The first `name=value` whose name matches after trimming and whose value parses as Int64.
    static func integer(_ name: String, in header: String?) -> Int64? {
        guard let header else { return nil }
        return integers.value(for: Lookup(name: name, header: header)) {
            for item in header.split(separator: ";") {
                let pair = item.split(separator: "=", maxSplits: 1)
                if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == name { return Int64(pair[1]) }
            }
            return nil
        }
    }

    /// The raw value of the first item named `name` once the item is trimmed.
    static func trimmedItemValue(_ name: String, in header: String?) -> String? {
        guard let header else { return nil }
        return values.value(for: Lookup(name: name, header: header)) {
            header.split(separator: ";").compactMap { item -> String? in
                let pair = item.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return pair.count == 2 && pair[0] == name ? String(pair[1]) : nil
            }.first
        }
    }
}

final class BoundedSet: @unchecked Sendable {
    private let cache: BoundedCache<String, Bool>
    init(limit: Int) { cache = BoundedCache(limit: limit) }
    func contains(_ key: String) -> Bool { cache.value(for: key) != nil }
    func insert(_ key: String) { cache.insert(true, for: key) }
}
