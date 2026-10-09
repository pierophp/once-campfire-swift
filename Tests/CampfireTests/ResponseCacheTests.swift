import CSQLite
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest
@testable import CampfireCore

final class ResponseCacheTests: XCTestCase {
    func testRepeatedReadsAreServedFromTheCacheUntilAnyConnectionCommits() async throws {
        try await withSeededApp { client, cache, databasePath, roomID in
            var headers = HTTPFields()
            headers[.cookie] = "\(try await cacheLogin(client)); last_room=\(roomID)"
            headers[.acceptEncoding] = "gzip"
            for uri in ["/rooms/\(roomID)", "/rooms/\(roomID)/messages", "/users/me/sidebar", "/searches?q=coffee"] {
                let first = try await client.execute(uri: uri, method: .get, headers: headers)
                XCTAssertEqual(first.status.code, 200, uri)
                let before = cache.hits
                let second = try await client.execute(uri: uri, method: .get, headers: headers)
                XCTAssertEqual(cache.hits, before + 1, "\(uri) is served from the cache")
                XCTAssertEqual(second.status.code, 200)
                XCTAssertEqual(second.body, first.body)
                XCTAssertEqual(second.headers[.contentEncoding], "gzip")
                XCTAssertEqual(second.headers[HTTPField.Name("etag")!], first.headers[HTTPField.Name("etag")!])
                XCTAssertEqual(second.headers[.vary], first.headers[.vary])
            }

            // A commit without any timestamp change, from another process's connection.
            try foreignExecute(databasePath, "UPDATE users SET name='Foreign Rename' WHERE email_address='david@37signals.com'")
            let before = cache.hits
            var identity = headers
            identity[.acceptEncoding] = nil
            let renamed = try await client.execute(uri: "/users/me/sidebar", method: .get, headers: identity)
            XCTAssertEqual(cache.hits, before)
            XCTAssertTrue(String(buffer: renamed.body).contains("Foreign Rename"))
        }
    }

    func testCachedPagesKeepPerRequestCookiesAndConditionalResponses() async throws {
        try await withSeededApp { client, cache, _, roomID in
            var headers = HTTPFields()
            headers[.cookie] = try await cacheLogin(client)
            _ = try await client.execute(uri: "/rooms/\(roomID)", method: .get, headers: headers)
            let before = cache.hits
            let cached = try await client.execute(uri: "/rooms/\(roomID)", method: .get, headers: headers)
            XCTAssertEqual(cache.hits, before + 1)
            XCTAssertTrue(try XCTUnwrap(cached.headers[.setCookie]).contains("last_room=\(roomID)"), "the handler's cookie is set on a hit too")

            let sidebar = try await client.execute(uri: "/users/me/sidebar", method: .get, headers: headers)
            XCTAssertNil(sidebar.headers[.setCookie])
            headers[HTTPField.Name("if-none-match")!] = try XCTUnwrap(sidebar.headers[HTTPField.Name("etag")!])
            let notModified = try await client.execute(uri: "/users/me/sidebar", method: .get, headers: headers)
            XCTAssertEqual(notModified.status.code, 304)
            XCTAssertEqual(notModified.body.readableBytes, 0)
            XCTAssertNil(notModified.headers[.contentType])
            XCTAssertNil(notModified.headers[.vary])
        }
    }

    func testFlashIsRenderedFreshAndNeverStored() async throws {
        try await withSeededApp { client, cache, _, _ in
            let secret = ProcessInfo.processInfo.environment["SECRET_KEY_BASE"] ?? "campfire-swift-development-secret-key-base"
            let key = RailsKeyGenerator(secretKeyBase: secret).generate(salt: "authenticated encrypted cookie", length: 32)
            let flash = try MessageEncryptor(key: key).encryptCookie(serializedValue: "{\"flash\":{\"discard\":[],\"flashes\":{\"notice\":\"Cached notice\"}}}", purpose: "cookie._campfire_session")
            var headers = HTTPFields()
            headers[.cookie] = "\(try await cacheLogin(client)); _campfire_session=\(flash)"
            for _ in 0..<2 {
                let before = cache.hits
                let response = try await client.execute(uri: "/users/me/sidebar", method: .get, headers: headers)
                XCTAssertEqual(cache.hits, before)
                XCTAssertTrue(String(buffer: response.body).contains("Cached notice"))
                XCTAssertTrue(try XCTUnwrap(response.headers[.setCookie]).contains("_campfire_session="))
            }
        }
    }

    func testRequestsBypassTheCacheWhenTheyAskForAFreshResponse() async throws {
        try await withSeededApp { client, cache, _, _ in
            var headers = HTTPFields()
            headers[.cookie] = try await cacheLogin(client)
            _ = try await client.execute(uri: "/users/me/sidebar", method: .get, headers: headers)
            headers[.cacheControl] = "no-cache"
            let before = cache.hits
            _ = try await client.execute(uri: "/users/me/sidebar", method: .get, headers: headers)
            _ = try await client.execute(uri: "/users/me/sidebar", method: .get, headers: headers)
            XCTAssertEqual(cache.hits, before)
        }
    }

    private func withSeededApp(_ body: @escaping @Sendable (TestClientProtocol, ResponseCache, String, Int) async throws -> Void) async throws {
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
        let databasePath = temporary.appending(path: "db/production.sqlite3").path
        let labels = try JSONSerialization.jsonObject(with: Data(contentsOf: temporary.appending(path: "labels.json"))) as! [String: Any]
        let roomID = try XCTUnwrap(labels["rooms.watercooler"] as? Int)
        let database = try SQLiteDatabase(path: databasePath)
        let cache = ResponseCache(database: database, maxBytes: 8 << 20)
        let app = Application(router: makeRouter(database: database, responseCache: cache, avatarFilesPath: temporary.appending(path: "storage").path))
        try await app.test(.router) { client in try await body(client, cache, databasePath, roomID) }
    }

    private var seedDirectory: URL {
        if let configured = ProcessInfo.processInfo.environment["CAMPFIRE_SEED_DIR"] {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "parity/.seed/default", directoryHint: .isDirectory)
    }
}

private func cacheLogin(_ client: TestClientProtocol) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/x-www-form-urlencoded"
    headers[HTTPField.Name("sec-fetch-site")!] = "same-origin"
    let login = try await client.execute(uri: "/session", method: .post, headers: headers,
        body: ByteBuffer(string: "email_address=david%4037signals.com&password=secret123456&authenticity_token="))
    XCTAssertEqual(login.status.code, 302)
    return try XCTUnwrap(login.headers[.setCookie]).components(separatedBy: ";").first!
}

private func foreignExecute(_ path: String, _ sql: String) throws {
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
    defer { sqlite3_close(handle) }
    sqlite3_busy_timeout(handle, 5000)
    XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
}
