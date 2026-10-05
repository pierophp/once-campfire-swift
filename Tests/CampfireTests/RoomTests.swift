import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest
@testable import CampfireCore

final class RoomTests: XCTestCase {
    func testWatercoolerShowsItsLastFortyMessagesOldestFirstAndSetsLastRoomCookieOnce() async throws {
        try await withSeed { databasePath, seed in
            let labels = try JSONSerialization.jsonObject(with: Data(contentsOf: seed.appending(path: "labels.json"))) as! [String: Any]
            let roomID = try XCTUnwrap(labels["rooms.watercooler"] as? Int)
            let seedDatabase = try SQLiteDatabase(path: databasePath)
            let expectedIDs = try seedDatabase.read { connection in
                try connection.rows("SELECT id FROM (SELECT id, created_at FROM messages WHERE room_id=? ORDER BY created_at DESC LIMIT 40) ORDER BY created_at ASC", bindings: [.integer(Int64(roomID))]).compactMap { $0.integer(0) }
            }
            let app = try makeApplication(databasePath: databasePath)
            try await app.test(.router) { client in
                let cookie = try await roomLogin(client)
                var headers = HTTPFields(); headers[.cookie] = cookie
                let response = try await client.execute(uri: "/rooms/\(roomID)", method: .get, headers: headers)
                XCTAssertEqual(response.status.code, 200)
                let html = String(buffer: response.body)
                let ids = html.matches(for: #"data-message-id="(\d+)""#).compactMap { Int64($0) }
                XCTAssertEqual(ids.count, 40)
                XCTAssertEqual(ids, expectedIDs, "Rails paginates by created_at, including the seeded fixture messages newer than busy_120")
                XCTAssertTrue(html.contains("turbo-cable-stream-source"))
                XCTAssertTrue(html.contains("/assets/"))
                XCTAssertNotNil(response.headers[HTTPField.Name("etag")!])
                XCTAssertTrue(try XCTUnwrap(response.headers[HTTPField.Name("set-cookie")!]).contains("last_room=\(roomID)"))

                headers[.cookie] = "\(cookie); last_room=\(roomID)"
                let second = try await client.execute(uri: "/rooms/\(roomID)", method: .get, headers: headers)
                XCTAssertNil(second.headers[HTTPField.Name("set-cookie")!])
            }
        }
    }

    func testRoomShowRedirectsNonMembersAndMessageFragmentsRefreshAfterUpdatedAtChanges() async throws {
        try await withSeed { databasePath, seed in
            let labels = try JSONSerialization.jsonObject(with: Data(contentsOf: seed.appending(path: "labels.json"))) as! [String: Any]
            let roomID = try XCTUnwrap(labels["rooms.watercooler"] as? Int)
            let messageID = try XCTUnwrap(labels["messages.busy_120"] as? Int)
            let database = try SQLiteDatabase(path: databasePath)
            let app = try makeApplication(databasePath: databasePath, database: database)
            try await app.test(.router) { client in
                let memberCookie = try await roomLogin(client)
                var outsiderHeaders = HTTPFields(); outsiderHeaders[.cookie] = try await roomLogin(client, email: "lou@37signals.com")
                let denied = try await client.execute(uri: "/rooms/\(roomID)", method: .get, headers: outsiderHeaders)
                XCTAssertEqual(denied.status.code, 302)
                XCTAssertEqual(denied.headers[.location], "/")
                let alertCookie = try XCTUnwrap(denied.headers[HTTPField.Name("set-cookie")!]).components(separatedBy: ";").first!
                outsiderHeaders[.cookie] = "\(outsiderHeaders[.cookie] ?? ""); \(alertCookie)"
                let redirectedPage = try await client.execute(uri: "/users/me/sidebar", method: .get, headers: outsiderHeaders)
                XCTAssertTrue(String(buffer: redirectedPage.body).contains("Room not found or inaccessible"))

                var headers = HTTPFields(); headers[.cookie] = "\(memberCookie); last_room=\(roomID)"
                let first = try await client.execute(uri: "/rooms/\(roomID)", method: .get, headers: headers)
                let before = String(buffer: first.body)
                try database.write { connection, _ in
                    try connection.execute("UPDATE action_text_rich_texts SET body=? WHERE record_type='Message' AND record_id=? AND name='body'", bindings: [.text("<div><p>updated room cache marker</p></div>"), .integer(Int64(messageID))])
                    try connection.execute("UPDATE messages SET updated_at='2026-10-05 12:00:00.123456' WHERE id=?", bindings: [.integer(Int64(messageID))])
                }
                let second = try await client.execute(uri: "/rooms/\(roomID)", method: .get, headers: headers)
                let after = String(buffer: second.body)
                XCTAssertFalse(before.contains("updated room cache marker"))
                XCTAssertTrue(after.contains("updated room cache marker"))
            }
        }
    }

    func testMessagesPageReturnsFortyEarlierMessagesAndSupportsFreshness() async throws {
        try await withSeed { databasePath, seed in
            let labels = try JSONSerialization.jsonObject(with: Data(contentsOf: seed.appending(path: "labels.json"))) as! [String: Any]
            let roomID = try XCTUnwrap(labels["rooms.watercooler"] as? Int)
            let beforeID = try XCTUnwrap(labels["messages.busy_060"] as? Int)
            let database = try SQLiteDatabase(path: databasePath)
            let expectedIDs = try database.read { connection in
                Array(try connection.rows("SELECT id FROM messages WHERE room_id=? AND created_at < (SELECT created_at FROM messages WHERE id=?) ORDER BY created_at DESC LIMIT 40", bindings: [.integer(Int64(roomID)), .integer(Int64(beforeID))]).compactMap { $0.integer(0) }.reversed())
            }
            XCTAssertEqual(expectedIDs.count, 40)
            let firstMessageID = try database.read { connection in
                try XCTUnwrap(connection.firstRow("SELECT id FROM messages WHERE room_id=? ORDER BY created_at ASC LIMIT 1", bindings: [.integer(Int64(roomID))])?.integer(0))
            }
            let app = try makeApplication(databasePath: databasePath, database: database)
            try await app.test(.router) { client in
                let memberCookie = try await roomLogin(client)
                var headers = HTTPFields(); headers[.cookie] = memberCookie
                let response = try await client.execute(uri: "/rooms/\(roomID)/messages?before=\(beforeID)", method: .get, headers: headers)
                XCTAssertEqual(response.status.code, 200)
                let html = String(buffer: response.body)
                let ids = html.matches(for: #"data-message-id="(\d+)""#).compactMap { Int64($0) }
                XCTAssertEqual(ids, expectedIDs)
                XCTAssertFalse(html.contains("<html"), "the messages endpoint returns only the message fragment")
                XCTAssertNotNil(response.headers[HTTPField.Name("last-modified")!])
                let etag = try XCTUnwrap(response.headers[HTTPField.Name("etag")!])

                headers[HTTPField.Name("if-none-match")!] = etag
                let unchanged = try await client.execute(uri: "/rooms/\(roomID)/messages?before=\(beforeID)", method: .get, headers: headers)
                XCTAssertEqual(unchanged.status.code, 304)
                XCTAssertEqual(unchanged.headers[HTTPField.Name("etag")!], etag)

                headers[HTTPField.Name("if-none-match")!] = nil
                let empty = try await client.execute(uri: "/rooms/\(roomID)/messages?before=\(firstMessageID)", method: .get, headers: headers)
                XCTAssertEqual(empty.status.code, 204)

                var outsiderHeaders = HTTPFields(); outsiderHeaders[.cookie] = try await roomLogin(client, email: "lou@37signals.com")
                let denied = try await client.execute(uri: "/rooms/\(roomID)/messages?before=\(beforeID)", method: .get, headers: outsiderHeaders)
                XCTAssertEqual(denied.status.code, 302)
                XCTAssertEqual(denied.headers[.location], "/")
            }
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

private func roomLogin(_ client: TestClientProtocol, email: String = "david@37signals.com") async throws -> String {
    var loginHeaders = HTTPFields()
    loginHeaders[.contentType] = "application/x-www-form-urlencoded"
    loginHeaders[HTTPField.Name("sec-fetch-site")!] = "same-origin"
    let address = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
    let login = try await client.execute(uri: "/session", method: .post, headers: loginHeaders,
        body: ByteBuffer(string: "email_address=\(address)&password=secret123456&authenticity_token="))
    XCTAssertEqual(login.status.code, 302)
    return try XCTUnwrap(login.headers[HTTPField.Name("set-cookie")!]).components(separatedBy: ";").first!
}

private extension String {
    func matches(for pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap {
            guard $0.numberOfRanges > 1, let range = Range($0.range(at: 1), in: self) else { return nil }
            return String(self[range])
        }
    }
}
