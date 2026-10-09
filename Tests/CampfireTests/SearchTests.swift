import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest
@testable import CampfireCore

final class SearchTests: XCTestCase {
    func testCoffeeSearchShowsReachableMessagesInIDOrderAndRecentSearches() async throws {
        try await withSeed { databasePath, _ in
            let app = try makeApplication(databasePath: databasePath)
            try await app.test(.router) { client in
                let cookie = try await searchLogin(client)
                var headers = HTTPFields(); headers[.cookie] = cookie
                let response = try await client.execute(uri: "/searches?q=coffee", method: .get, headers: headers)

                XCTAssertEqual(response.status.code, 200)
                let html = String(buffer: response.body)
                let ids = html.matches(for: #"data-message-id="(\d+)""#).compactMap(Int64.init)
                // The newest 100 matches by message id, oldest first, as the Rust port and the shared
                // verification contract read them off the full-text index.
                XCTAssertEqual(ids, [933434483, 933434510, 933434520, 933434530, 933434540, 933434550, 933434560, 933434570, 933434580, 933434590, 933434600, 933434610, 933434620])
                XCTAssertTrue(html.contains("Coffee first, then the launch plan."))
                XCTAssertTrue(html.contains("searches__query"))
                XCTAssertTrue(html.contains("“cuckoo”"))
                XCTAssertTrue(html.contains("“Borgias”"))
                XCTAssertTrue(html.contains("“pizza”"))
            }
        }
    }

    func testSearchTreatsFTSOperatorsAsLiteralWords() async throws {
        try await withSeed { databasePath, _ in
            let app = try makeApplication(databasePath: databasePath)
            try await app.test(.router) { client in
                let cookie = try await searchLogin(client)
                var headers = HTTPFields(); headers[.cookie] = cookie
                for (term, expectedID) in [("NOT", 136976342), ("OR", 684468941), ("NEAR", Int64?.none)] as [(String, Int64?)] {
                    let response = try await client.execute(uri: "/searches?q=\(term)", method: .get, headers: headers)
                    XCTAssertEqual(response.status.code, 200, "\(term) should be matched as a literal FTS term")
                    let html = String(buffer: response.body)
                    if let expectedID {
                        XCTAssertTrue(html.contains("data-message-id=\"\(expectedID)\""), "\(term) should return its indexed message")
                    } else {
                        XCTAssertTrue(html.contains("“NEAR”"))
                        XCTAssertFalse(html.contains(#"data-message-id="#))
                    }
                }
            }
        }
    }

    func testSearchQueryKeepsOnigmoWordCharactersAndReplacesPunctuation() async throws {
        try await withSeed { databasePath, _ in
            let app = try makeApplication(databasePath: databasePath)
            try await app.test(.router) { client in
                var headers = HTTPFields(); headers[.cookie] = try await searchLogin(client)
                let response = try await client.execute(uri: "/searches?q=%E2%85%AB%20%E2%80%BF%20a-b", method: .get, headers: headers)
                XCTAssertEqual(response.status.code, 200)
                let html = String(buffer: response.body)
                XCTAssertTrue(html.contains("“Ⅻ ‿ a b”"))
                XCTAssertTrue(html.contains(#"value="Ⅻ ‿ a-b""#))
            }
        }
    }

    func testSearchExcludesRoomsTheSignedInUserCannotReach() async throws {
        try await withSeed { databasePath, _ in
            let app = try makeApplication(databasePath: databasePath)
            try await app.test(.router) { client in
                var headers = HTTPFields(); headers[.cookie] = try await searchLogin(client, email: "lou@37signals.com")
                let response = try await client.execute(uri: "/searches?q=coffee", method: .get, headers: headers)
                XCTAssertEqual(response.status.code, 200)
                XCTAssertFalse(String(buffer: response.body).contains("data-message-id="))
            }
        }
    }

    func testBlankSearchShowsNoResultsAndAnUnauthenticatedRequestRedirects() async throws {
        try await withSeed { databasePath, _ in
            let app = try makeApplication(databasePath: databasePath)
            try await app.test(.router) { client in
                let blank = try await client.execute(uri: "/searches?q=%20%20", method: .get)
                XCTAssertEqual(blank.status.code, 302)
                XCTAssertEqual(blank.headers[.location], "/session/new")

                var headers = HTTPFields(); headers[.cookie] = try await searchLogin(client)
                let response = try await client.execute(uri: "/searches?q=%20%20", method: .get, headers: headers)
                XCTAssertEqual(response.status.code, 200)
                let html = String(buffer: response.body)
                XCTAssertFalse(html.contains(#"data-message-id="#))
                XCTAssertFalse(html.contains("searches__query"))
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

private func searchLogin(_ client: TestClientProtocol, email: String = "david@37signals.com") async throws -> String {
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
