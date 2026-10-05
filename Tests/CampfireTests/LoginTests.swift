import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest
@testable import CampfireCore

final class LoginTests: XCTestCase {
    func testLoginPageIsServedOverHTTP() async throws {
        let source = seedDirectory
        let databaseURL = source.appending(path: "db/production.sqlite3")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            if ProcessInfo.processInfo.environment["CAMPFIRE_REQUIRE_SEED"] == "1" {
                XCTFail("Parity seed db/production.sqlite3 was not found at \(databaseURL.path)")
                return
            }
            throw XCTSkip("Parity seed not found at \(databaseURL.path); set CAMPFIRE_REQUIRE_SEED=1 to require it")
        }

        let temporarySeed = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporarySeed) }
        try FileManager.default.copyItem(at: source, to: temporarySeed)
        let app = try makeApplication(databasePath: temporarySeed.appending(path: "db/production.sqlite3").path)

        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/session/new", method: .get)
            XCTAssertEqual(response.status.code, 200)
            XCTAssertTrue(String(buffer: response.body).contains("email_address"))
            XCTAssertTrue(String(buffer: response.body).contains("password"))
        }
    }

    func testSeededUserCanSignInAndRejectedAttemptsDoNotSetSessionCookie() async throws {
        let source = seedDirectory
        guard FileManager.default.fileExists(atPath: source.appending(path: "db/production.sqlite3").path) else {
            if ProcessInfo.processInfo.environment["CAMPFIRE_REQUIRE_SEED"] == "1" {
                XCTFail("Parity seed db/production.sqlite3 was not found at \(source.path)")
                return
            }
            throw XCTSkip("Parity seed missing; set CAMPFIRE_REQUIRE_SEED=1 to require it")
        }
        let temporarySeed = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporarySeed) }
        try FileManager.default.copyItem(at: source, to: temporarySeed)
        let database = try SQLiteDatabase(path: temporarySeed.appending(path: "db/production.sqlite3").path)
        let app = try makeApplication(databasePath: temporarySeed.appending(path: "db/production.sqlite3").path, database: database)
        let hasRoomPagingIndex = try database.read {
            try $0.firstRow("SELECT 1 FROM sqlite_master WHERE type='index' AND name='index_messages_on_room_id_and_created_at'") != nil
        }
        XCTAssertTrue(hasRoomPagingIndex)

        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/x-www-form-urlencoded"
            headers[HTTPField.Name("sec-fetch-site")!] = "same-origin"
            let success = try await client.execute(
                uri: "/session", method: .post, headers: headers,
                body: ByteBuffer(string: "email_address=david%4037signals.com&password=secret123456&authenticity_token=")
            )
            XCTAssertEqual(success.status.code, 302)
            let sessionCookie = try XCTUnwrap(success.headers[HTTPField.Name("set-cookie")!])
            XCTAssertTrue(sessionCookie.contains("session_token="))
            XCTAssertTrue(sessionCookie.contains("path=/"))
            XCTAssertTrue(sessionCookie.contains("httponly"))
            XCTAssertTrue(sessionCookie.contains("samesite=lax"))

            let beforeRejectedAttempts = try database.read { try $0.scalarInt("SELECT COUNT(*) FROM sessions") ?? 0 }
            var bannedIPHeaders = headers
            bannedIPHeaders[HTTPField.Name("x-forwarded-for")!] = "203.0.113.9"
            let bannedIP = try await client.execute(
                uri: "/session", method: .post, headers: bannedIPHeaders,
                body: ByteBuffer(string: "email_address=david%4037signals.com&password=secret123456&authenticity_token=")
            )
            XCTAssertEqual(bannedIP.status.code, 401)
            XCTAssertNil(bannedIP.headers[HTTPField.Name("set-cookie")!])

            let wrongPassword = try await client.execute(
                uri: "/session", method: .post, headers: headers,
                body: ByteBuffer(string: "email_address=david%4037signals.com&password=wrong&authenticity_token=")
            )
            XCTAssertEqual(wrongPassword.status.code, 401)
            XCTAssertNil(wrongPassword.headers[HTTPField.Name("set-cookie")!])

            let unknownEmail = try await client.execute(
                uri: "/session", method: .post, headers: headers,
                body: ByteBuffer(string: "email_address=missing%40example.com&password=secret123456&authenticity_token=")
            )
            XCTAssertEqual(unknownEmail.status.code, 401)
            XCTAssertNil(unknownEmail.headers[HTTPField.Name("set-cookie")!])

            var crossSiteHeaders = HTTPFields()
            crossSiteHeaders[.contentType] = "application/x-www-form-urlencoded"
            crossSiteHeaders[HTTPField.Name("sec-fetch-site")!] = "cross-site"
            let crossSite = try await client.execute(
                uri: "/session", method: .post, headers: crossSiteHeaders,
                body: ByteBuffer(string: "email_address=david%4037signals.com&password=secret123456&authenticity_token=")
            )
            XCTAssertEqual(crossSite.status.code, 422)
            XCTAssertNil(crossSite.headers[HTTPField.Name("set-cookie")!])
            let afterRejectedAttempts = try database.read { try $0.scalarInt("SELECT COUNT(*) FROM sessions") ?? 0 }
            XCTAssertEqual(afterRejectedAttempts, beforeRejectedAttempts)
        }
    }

    private var seedDirectory: URL {
        if let configured = ProcessInfo.processInfo.environment["CAMPFIRE_SEED_DIR"] {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "parity/.seed/default", directoryHint: .isDirectory)
    }
}
