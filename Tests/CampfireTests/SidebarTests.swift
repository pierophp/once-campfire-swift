import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest
@testable import CampfireCore

final class SidebarTests: XCTestCase {
    func testUnauthenticatedSidebarRedirectsToLogin() async throws {
        try await withSeed { databasePath, _ in
            let app = try makeApplication(databasePath: databasePath)
            try await app.test(.router) { client in
                let response = try await client.execute(uri: "/users/me/sidebar", method: .get)
                XCTAssertEqual(response.status.code, 302)
                XCTAssertEqual(response.headers[.location], "/session/new")
            }
        }
    }

    func testSeededUserSidebarListsRoomsAndHasPrivateRevalidationHeadersWithoutRefreshingRecentSession() async throws {
        try await withSeed { databasePath, _ in
            let database = try SQLiteDatabase(path: databasePath)
            let app = try makeApplication(databasePath: databasePath, database: database)
            try await app.test(.router) { client in
                var loginHeaders = HTTPFields()
                loginHeaders[.contentType] = "application/x-www-form-urlencoded"
                loginHeaders[HTTPField.Name("sec-fetch-site")!] = "same-origin"
                let login = try await client.execute(uri: "/session", method: .post, headers: loginHeaders,
                    body: ByteBuffer(string: "email_address=david%4037signals.com&password=secret123456&authenticity_token="))
                XCTAssertEqual(login.status.code, 302)
                let tokenCookie = try XCTUnwrap(login.headers[HTTPField.Name("set-cookie")!])
                    .components(separatedBy: ";").first!
                let sessionCount = try database.read { try $0.scalarInt("SELECT COUNT(*) FROM sessions") ?? 0 }

                var headers = HTTPFields()
                headers[.cookie] = tokenCookie
                let response = try await client.execute(uri: "/users/me/sidebar", method: .get, headers: headers)
                XCTAssertEqual(response.status.code, 200)
                XCTAssertEqual(response.headers[HTTPField.Name("cache-control")!], "max-age=0, private, must-revalidate")
                XCTAssertNotNil(response.headers[HTTPField.Name("etag")!])
                let html = String(buffer: response.body)
                XCTAssertTrue(html.contains("All Pets"))
                XCTAssertTrue(html.contains("All Talk"))
                XCTAssertTrue(html.contains("direct__new"), "the Rails sidebar includes the new direct-message action")
                XCTAssertTrue(html.contains("id=\"direct_rooms\""), "direct rooms render in the Rails sidebar list")
                XCTAssertTrue(html.contains("id=\"shared_rooms\""), "shared rooms render in the Rails sidebar list")
                XCTAssertTrue(html.contains("My Settings"), "the full application sidebar includes profile controls")
                XCTAssertTrue(html.contains("Account Settings"), "the full application sidebar includes account controls")
                XCTAssertTrue(html.contains("id=\"app-logo\""), "the application layout renders its footer logo")
                XCTAssertLessThan(try XCTUnwrap(html.range(of: "All Pets")).lowerBound, try XCTUnwrap(html.range(of: "All Talk")).lowerBound)
                XCTAssertTrue(html.contains("/assets/"))
                XCTAssertEqual(try database.read { try $0.scalarInt("SELECT COUNT(*) FROM sessions") ?? 0 }, sessionCount)
                XCTAssertNil(response.headers[HTTPField.Name("set-cookie")!], "an ordinary recent read does not write cookies")
                let css = try await client.execute(uri: AssetManifest.stylesheetPath, method: .get)
                XCTAssertEqual(css.status.code, 200)
                XCTAssertEqual(css.headers[.contentType], "text/css; charset=utf-8")
            }
        }
    }

    func testSidebarRefreshesAnOldSessionAndResignsItsCookie() async throws {
        try await withSeed { databasePath, _ in
            let database = try SQLiteDatabase(path: databasePath)
            let app = try makeApplication(databasePath: databasePath, database: database)
            try await app.test(.router) { client in
                var loginHeaders = HTTPFields()
                loginHeaders[.contentType] = "application/x-www-form-urlencoded"
                loginHeaders[HTTPField.Name("sec-fetch-site")!] = "same-origin"
                let login = try await client.execute(uri: "/session", method: .post, headers: loginHeaders,
                    body: ByteBuffer(string: "email_address=david%4037signals.com&password=secret123456&authenticity_token="))
                let cookie = try XCTUnwrap(login.headers[HTTPField.Name("set-cookie")!]).components(separatedBy: ";").first!
                try database.write { connection, _ in
                    try connection.execute("UPDATE sessions SET last_active_at=datetime('now','-2 hours') WHERE token=(SELECT token FROM sessions ORDER BY id DESC LIMIT 1)")
                }
                var headers = HTTPFields(); headers[.cookie] = cookie
                let response = try await client.execute(uri: "/users/me/sidebar", method: .get, headers: headers)
                XCTAssertEqual(response.status.code, 200)
                XCTAssertTrue(try XCTUnwrap(response.headers[HTTPField.Name("set-cookie")!]).contains("session_token="))
                XCTAssertEqual(try database.read { try $0.scalarInt("SELECT COUNT(*) FROM sessions WHERE last_active_at > datetime('now','-1 hour')") ?? 0 }, 1)
            }
        }
    }

    func testReadingFlashConsumesTheEncryptedRailsSessionCookie() async throws {
        try await withSeed { databasePath, _ in
            let database = try SQLiteDatabase(path: databasePath)
            let app = try makeApplication(databasePath: databasePath, database: database)
            let secret = ProcessInfo.processInfo.environment["SECRET_KEY_BASE"] ?? "campfire-swift-development-secret-key-base"
            let key = RailsKeyGenerator(secretKeyBase: secret).generate(salt: "authenticated encrypted cookie", length: 32)
            let json = "{\"flash\":{\"discard\":[],\"flashes\":{\"notice\":\"Welcome back\"}}}"
            let encrypted = try MessageEncryptor(key: key).encryptCookie(serializedValue: json, purpose: "cookie._campfire_session")
            try await app.test(.router) { client in
                var loginHeaders = HTTPFields()
                loginHeaders[.contentType] = "application/x-www-form-urlencoded"
                loginHeaders[HTTPField.Name("sec-fetch-site")!] = "same-origin"
                let login = try await client.execute(uri: "/session", method: .post, headers: loginHeaders,
                    body: ByteBuffer(string: "email_address=david%4037signals.com&password=secret123456&authenticity_token="))
                let token = try XCTUnwrap(login.headers[HTTPField.Name("set-cookie")!]).components(separatedBy: ";").first!
                var headers = HTTPFields(); headers[.cookie] = "\(token); _campfire_session=\(encrypted)"
                let response = try await client.execute(uri: "/users/me/sidebar", method: .get, headers: headers)
                XCTAssertTrue(String(buffer: response.body).contains("Welcome back"))
                XCTAssertTrue(try XCTUnwrap(response.headers[HTTPField.Name("set-cookie")!]).contains("_campfire_session="))
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
