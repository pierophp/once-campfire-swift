import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest
@testable import CampfireCore

final class MessagePostingTests: XCTestCase {
    func testPostingStoresSearchableMessageAndMarksDisconnectedVisibleMembersUnread() async throws {
        try await withSeed { databasePath, seed in
            let labels = try JSONSerialization.jsonObject(with: Data(contentsOf: seed.appending(path: "labels.json"))) as! [String: Any]
            let roomID = try XCTUnwrap(labels["rooms.watercooler"] as? Int)
            let jasonMembershipID = try XCTUnwrap(labels["memberships.jason_watercooler"] as? Int)
            let benderMembershipID = try XCTUnwrap(labels["memberships.bender_watercooler"] as? Int)
            let database = try SQLiteDatabase(path: databasePath)
            try database.write { connection, _ in
                try connection.execute("UPDATE memberships SET connected_at=NULL, unread_at=NULL, involvement='mentions' WHERE id=?", bindings: [.integer(Int64(jasonMembershipID))])
                try connection.execute("UPDATE memberships SET connected_at=datetime('now'), unread_at=NULL WHERE id=?", bindings: [.integer(Int64(benderMembershipID))])
            }
            let app = try makeApplication(databasePath: databasePath, database: database)

            try await app.test(.router) { client in
                let cookie = try await postLogin(client)
                let response = try await client.execute(
                    uri: "/rooms/\(roomID)/messages", method: .post,
                    headers: postHeaders(cookie: cookie, site: "same-origin"),
                    body: ByteBuffer(string: "message%5Bbody%5D=%3Cdiv%3E%3Cp%3Eswift-index-marker%3C%2Fp%3E%3C%2Fdiv%3E&message%5Bclient_message_id%5D=posting-test-1")
                )
                XCTAssertEqual(response.status.code, 200)
                XCTAssertEqual(response.headers[.contentType], "text/vnd.turbo-stream.html; charset=utf-8")
                let stream = String(buffer: response.body)
                XCTAssertTrue(stream.contains("<turbo-stream action=\"append\""), stream)
                XCTAssertTrue(stream.contains("swift-index-marker"), stream)

                let created = try database.read { connection in
                    try connection.firstRow("SELECT m.id, m.created_at, m.updated_at, r.updated_at, t.body, f.body, recipient.unread_at FROM messages m JOIN rooms r ON r.id=m.room_id JOIN action_text_rich_texts t ON t.record_type='Message' AND t.record_id=m.id AND t.name='body' JOIN message_search_index f ON f.rowid=m.id JOIN memberships recipient ON recipient.id=? WHERE m.client_message_id=?", bindings: [.integer(Int64(jasonMembershipID)), .text("posting-test-1")])
                }
                XCTAssertEqual(created?.string(4), "<div><p>swift-index-marker</p></div>")
                XCTAssertTrue(created?.string(5)?.contains("swift-index-marker") == true)
                XCTAssertNotNil(created?.string(6), "disconnected visible members become unread after the commit")
                XCTAssertNotEqual(created?.string(1), created?.string(2), "Action Text touches the message after insertion")
                XCTAssertNotNil(created?.string(3), "message creation touches the room")
                let connectedUnread = try database.read { connection in
                    try connection.firstRow("SELECT unread_at FROM memberships WHERE id=?", bindings: [.integer(Int64(benderMembershipID))])?.string(0)
                }
                XCTAssertNil(connectedUnread, "connected members aren't marked unread")

                let room = try await client.execute(uri: "/rooms/\(roomID)", method: .get, headers: HTTPFields(dictionaryLiteral: (.cookie, cookie)))
                XCTAssertEqual(room.status.code, 200)
                XCTAssertTrue(String(buffer: room.body).contains("swift-index-marker"))

                let messagesPage = try await client.execute(uri: "/rooms/\(roomID)/messages", method: .get, headers: HTTPFields(dictionaryLiteral: (.cookie, cookie)))
                XCTAssertEqual(messagesPage.status.code, 200)
                XCTAssertTrue(String(buffer: messagesPage.body).contains("swift-index-marker"))

                let search = try await client.execute(uri: "/searches?q=swift-index-marker", method: .get, headers: HTTPFields(dictionaryLiteral: (.cookie, cookie)))
                XCTAssertEqual(search.status.code, 200)
                XCTAssertTrue(String(buffer: search.body).contains("swift-index-marker"))

                let ftsHit = try database.read { connection in
                    try connection.firstRow("SELECT rowid FROM message_search_index WHERE body MATCH '\"swift-index-marker\"'")?.integer(0)
                }
                XCTAssertEqual(ftsHit, created?.integer(0))
            }
        }
    }

    func testPostingRequiresMembershipAndRejectsCrossSiteRequests() async throws {
        try await withSeed { databasePath, seed in
            let labels = try JSONSerialization.jsonObject(with: Data(contentsOf: seed.appending(path: "labels.json"))) as! [String: Any]
            let roomID = try XCTUnwrap(labels["rooms.watercooler"] as? Int)
            let davidID = try XCTUnwrap(labels["users.david"] as? Int)
            let database = try SQLiteDatabase(path: databasePath)
            try database.write { connection, _ in
                try connection.execute("INSERT INTO bans (ip_address, user_id, created_at, updated_at) VALUES ('203.0.113.77', ?, '2026-10-05 00:00:00', '2026-10-05 00:00:00')", bindings: [.integer(Int64(davidID))])
            }
            let app = try makeApplication(databasePath: databasePath, database: database)
            try await app.test(.router) { client in
                let memberCookie = try await postLogin(client)
                let before = try database.read { try $0.scalarInt("SELECT COUNT(*) FROM messages") }
                var bannedHeaders = postHeaders(cookie: memberCookie, site: "same-origin")
                bannedHeaders[HTTPField.Name("x-forwarded-for")!] = "203.0.113.77"
                let banned = try await client.execute(uri: "/rooms/\(roomID)/messages", method: .post, headers: bannedHeaders,
                    body: ByteBuffer(string: "message%5Bbody%5D=must-not-save"))
                XCTAssertEqual(banned.status.code, 429)
                XCTAssertEqual(try database.read { try $0.scalarInt("SELECT COUNT(*) FROM messages") }, before)

                let crossSite = try await client.execute(
                    uri: "/rooms/\(roomID)/messages", method: .post,
                    headers: postHeaders(cookie: memberCookie, site: "cross-site"),
                    body: ByteBuffer(string: "message%5Bbody%5D=must-not-save")
                )
                XCTAssertEqual(crossSite.status.code, 422)
                XCTAssertEqual(try database.read { try $0.scalarInt("SELECT COUNT(*) FROM messages") }, before)

                let outsiderCookie = try await postLogin(client, email: "lou@37signals.com")
                let denied = try await client.execute(
                    uri: "/rooms/\(roomID)/messages", method: .post,
                    headers: postHeaders(cookie: outsiderCookie, site: "same-origin"),
                    body: ByteBuffer(string: "message%5Bbody%5D=must-not-save")
                )
                XCTAssertEqual(denied.status.code, 302)
                XCTAssertEqual(denied.headers[.location], "/")
                XCTAssertEqual(try database.read { try $0.scalarInt("SELECT COUNT(*) FROM messages") }, before)
            }
        }
    }

    func testPostMessageWorkloadReturnsOnlySuccessfulStatusesAndKeepsDatabaseValid() async throws {
        try await withSeed { databasePath, seed in
            let labels = try JSONSerialization.jsonObject(with: Data(contentsOf: seed.appending(path: "labels.json"))) as! [String: Any]
            let roomID = try XCTUnwrap(labels["rooms.hq"] as? Int)
            let database = try SQLiteDatabase(path: databasePath)
            let app = try makeApplication(databasePath: databasePath, database: database)
            try await app.test(.router) { client in
                let cookie = try await postLogin(client)
                for index in 0..<30 {
                    var fields = URLComponents()
                    fields.queryItems = [
                        URLQueryItem(name: "message[body]", value: "<p>post workload \(index)</p>"),
                        URLQueryItem(name: "message[client_message_id]", value: "post-workload-\(index)"),
                    ]
                    let response = try await client.execute(
                        uri: "/rooms/\(roomID)/messages", method: .post,
                        headers: postHeaders(cookie: cookie, site: "same-origin"),
                        body: ByteBuffer(string: fields.percentEncodedQuery ?? "")
                    )
                    XCTAssertLessThan(response.status.code, 400, "post workload request \(index) failed")
                }
                let integrity = try database.read { connection in
                    try connection.firstRow("PRAGMA integrity_check")?.string(0)
                }
                XCTAssertEqual(integrity, "ok")
                let rowCounts = try database.read { connection in
                    try connection.firstRow("SELECT (SELECT COUNT(*) FROM messages WHERE client_message_id LIKE 'post-workload-%'), (SELECT COUNT(*) FROM message_search_index WHERE body MATCH 'workload')")
                }
                XCTAssertEqual(rowCounts?.integer(0), 30)
                XCTAssertEqual(rowCounts?.integer(1), 30)
            }
        }
    }

    /// Message timestamps are computed in Swift for Rails' shape; SQLite's expression is the oracle.
    func testMessageTimestampMillisecondsMatchSQLite() async throws {
        try await withSeed { databasePath, _ in
            let database = try SQLiteDatabase(path: databasePath)
            var generator = SystemRandomNumberGenerator()
            var values = ["2026-01-01 00:00:00", "2026-01-01 00:00:00.9999999", "2024-02-29 23:59:59.999500", "1970-01-01 00:00:00.000",
                          "2026-01-01 00:00:00.5", "2026-01-01 00:00:00.12", "2026-01-01T00:00:00.123456", "2026-01-01 00:00:00.123456Z",
                          "2023-02-29 00:00:00.000000", "1969-12-31 23:59:59.999999", "", "not a time"]
            for _ in 0..<5_000 {
                let fraction = String((0..<Int.random(in: 3...9, using: &generator)).map { _ in "0123456789".randomElement(using: &generator)! })
                values.append(String(format: "%04d-%02d-%02d %02d:%02d:%02d.", Int.random(in: 1970...2400, using: &generator), Int.random(in: 1...12, using: &generator),
                                     Int.random(in: 1...28, using: &generator), Int.random(in: 0...23, using: &generator), Int.random(in: 0...59, using: &generator),
                                     Int.random(in: 0...59, using: &generator)) + fraction)
            }
            let expected = try database.read { connection in
                try values.map { try connection.firstRow("SELECT CAST(strftime('%s', ?1) AS INTEGER) * 1000 + CAST(substr(?1 || '.000', 21, 3) AS INTEGER)", bindings: [.text($0)])?.integer(0) }
            }
            var fast = 0
            for (value, sqlite) in zip(values, expected) {
                guard let computed = UTCTime.sqliteEpochMilliseconds(value) else { continue }
                XCTAssertEqual(computed, sqlite, value)
                fast += 1
            }
            XCTAssertGreaterThan(fast, 4_900)
        }
    }

    private func withSeed(_ body: (String, URL) async throws -> Void) async throws {
        let source = seedDirectory
        guard FileManager.default.fileExists(atPath: source.appending(path: "db/production.sqlite3").path),
              FileManager.default.fileExists(atPath: source.appending(path: "labels.json").path) else {
            if ProcessInfo.processInfo.environment["CAMPFIRE_REQUIRE_SEED"] == "1" {
                XCTFail("Parity seed required but db/production.sqlite3 or labels.json was not found at \(source.path)")
                return
            }
            throw XCTSkip("Parity seed missing; set CAMPFIRE_REQUIRE_SEED=1 to require it")
        }
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try await body(temporary.appending(path: "db/production.sqlite3").path, temporary)
    }

    private var seedDirectory: URL {
        if let configured = ProcessInfo.processInfo.environment["CAMPFIRE_SEED_DIR"] {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "parity/.seed/default", directoryHint: .isDirectory)
    }
}

private func postHeaders(cookie: String, site: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.cookie] = cookie
    headers[.contentType] = "application/x-www-form-urlencoded"
    headers[HTTPField.Name("accept")!] = "text/vnd.turbo-stream.html"
    headers[HTTPField.Name("sec-fetch-site")!] = site
    return headers
}

private func postLogin(_ client: TestClientProtocol, email: String = "david@37signals.com") async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/x-www-form-urlencoded"
    headers[HTTPField.Name("sec-fetch-site")!] = "same-origin"
    let address = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
    let login = try await client.execute(uri: "/session", method: .post, headers: headers,
        body: ByteBuffer(string: "email_address=\(address)&password=secret123456&authenticity_token="))
    XCTAssertEqual(login.status.code, 302)
    return try XCTUnwrap(login.headers[HTTPField.Name("set-cookie")!]).components(separatedBy: ";").first!
}
