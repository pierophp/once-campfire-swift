import CSQLite
import Crypto
import Foundation
import Hummingbird
import NIOCore
import HTTPTypes

private let dummyPasswordDigest = "$2a$12$FiKmSp4UhLvSB4Sd/ZUjQunyKP6.NjDRHdr5LnKUVk.BUn4Mq12WS"

func installLoginRoutes(on router: Router<BasicRequestContext>, database: SQLiteDatabase) {
    router.get("/session/new") { _, _ -> Response in
        let html = """
        <!doctype html><html><head><meta name="csrf-token" content=""></head><body>
        <main><h1>Sign in</h1><form action="/session" method="post">
        <label>Email address<input type="email" name="email_address" autocomplete="username"></label>
        <label>Password<input type="password" name="password" autocomplete="current-password"></label>
        <input type="hidden" name="authenticity_token" value="">
        <button type="submit">Sign in</button></form></main></body></html>
        """
        var response = Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: html)))
        response.headers[.contentType] = "text/html; charset=utf-8"
        return response
    }

    router.post("/session") { request, _ async throws -> Response in
        guard allowsSameOrigin(request) else { return Response(status: .init(code: 422)) }
        var request = request
        let body = try await request.collectBody(upTo: 64 * 1024)
        let parameters = formParameters(body)
        let email = parameters["email_address"] ?? ""
        let password = parameters["password"] ?? ""
        let address = request.headers[HTTPField.Name("x-forwarded-for")!]?.split(separator: ",").first.map(String.init) ?? "127.0.0.1"

        let ban = try await Task.detached { try database.read { connection in
            try connection.firstRow("SELECT 1 FROM bans WHERE ip_address=? LIMIT 1", bindings: [.text(address)]) != nil
        }}.value
        guard !ban else { return Response(status: .unauthorized) }

        let candidate = try await Task.detached { try database.read { connection in
            try connection.firstRow("SELECT id, password_digest FROM users WHERE email_address=? AND status=0 LIMIT 1", bindings: [.text(email)])
        }}.value
        let digest = candidate?.string(1) ?? dummyPasswordDigest
        let valid = await Task.detached(priority: .userInitiated) {
            let checked = verifyBCrypt(password: password, digest: digest)
            return checked && email.count <= 320 && password.utf8.count <= 72 && candidate != nil
        }.value
        guard valid, let userID = candidate?.integer(0) else { return Response(status: .unauthorized) }

        let token = base58Token(length: 24)
        let now = ISO8601DateFormatter().string(from: Date())
        let userAgent = request.headers[.userAgent] ?? ""
        try await Task.detached {
            try database.write { connection, _ in
                try connection.execute(
                    "INSERT INTO sessions (created_at, ip_address, last_active_at, token, updated_at, user_agent, user_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    bindings: [.text(now), .text(address), .text(now), .text(token), .text(now), .text(userAgent), .integer(userID)]
                )
            }
        }.value

        let secret = ProcessInfo.processInfo.environment["SECRET_KEY_BASE"] ?? "campfire-swift-development-secret-key-base"
        let signingKey = RailsKeyGenerator(secretKeyBase: secret).generate(salt: "signed cookie", length: 64)
        let expiry = Calendar(identifier: .gregorian).date(byAdding: .year, value: 20, to: Date())!
        let expiryISO = ISO8601DateFormatter().string(from: expiry)
        let value = MessageVerifier(secret: signingKey).generate(value: token, purpose: "cookie.session_token", expiresAt: expiryISO)
        let cookieExpiry = DateFormatter()
        cookieExpiry.locale = Locale(identifier: "en_US_POSIX")
        cookieExpiry.timeZone = TimeZone(secondsFromGMT: 0)
        cookieExpiry.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let cookieValue = value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")) ?? value
        var response = Response(status: .found)
        response.headers[.location] = "/"
        response.headers[HTTPField.Name("set-cookie")!] = "session_token=\(cookieValue); path=/; expires=\(cookieExpiry.string(from: expiry)); httponly; samesite=lax"
        return response
    }
}

private func allowsSameOrigin(_ request: Request) -> Bool {
    let origin = request.headers[.origin]
    if let origin {
        if origin == "null" { return false }
        let secure = ProcessInfo.processInfo.environment["DISABLE_SSL"] != "1"
        let expected = "\(secure ? "https" : "http")://\(request.head.authority ?? "localhost")"
        guard origin == expected else { return false }
    }
    switch request.headers[HTTPField.Name("sec-fetch-site")!] {
    case "same-origin", "same-site": return true
    case "cross-site": return false
    case nil: return ProcessInfo.processInfo.environment["DISABLE_SSL"] == "1"
    default: return false
    }
}

private func formParameters(_ buffer: ByteBuffer) -> [String: String] {
    let body = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
    let components = URLComponents(string: "?\(body)")
    return Dictionary(components?.queryItems?.compactMap { item in item.value.map { (item.name, $0) } } ?? [], uniquingKeysWith: { _, last in last })
}

private func verifyBCrypt(password: String, digest: String) -> Bool {
    let nativeResult = campfire_bcrypt_verify(password, digest)
    guard nativeResult < 0 else { return nativeResult == 1 }

    // macOS' system crypt does not implement bcrypt. Apache's verifier uses the same portable
    // bcrypt implementation on developer machines; Linux production uses libxcrypt above.
    let executable = ["/usr/bin/htpasswd", "/usr/sbin/htpasswd"].first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let executable else { return false }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("campfire-bcrypt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    do {
        try Data("campfire:\(digest)\n".utf8).write(to: file, options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-v", file.path, "campfire"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data("\(password)\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func base58Token(length: Int) -> String {
    let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    var generator = SystemRandomNumberGenerator()
    return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
}
