import Crypto
import CZlib
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest
@testable import CampfireCore

final class AvatarAssetTests: XCTestCase {
    func testJasonAvatarTokenServesSeededWebPBytesAndRailsCacheHeaders() async throws {
        try await withSeed { databasePath, filesPath, labels in
            let app = try makeApplication(databasePath: databasePath, avatarFilesPath: filesPath)
            try await app.test(.router) { client in
                var loginHeaders = HTTPFields()
                loginHeaders[.contentType] = "application/x-www-form-urlencoded"
                loginHeaders[HTTPField.Name("sec-fetch-site")!] = "same-origin"
                let login = try await client.execute(uri: "/session", method: .post, headers: loginHeaders,
                    body: ByteBuffer(string: "email_address=david%4037signals.com&password=secret123456&authenticity_token="))
                let cookie = try XCTUnwrap(login.headers[.setCookie]).components(separatedBy: ";").first!
                var headers = HTTPFields()
                headers[.cookie] = cookie
                headers[.acceptEncoding] = "identity"
                let response = try await client.execute(uri: "/users/\(labels["avatar_tokens.jason"]!)/avatar", method: .get, headers: headers)

                XCTAssertEqual(response.status.code, 200)
                XCTAssertEqual(response.headers[.contentType], "image/webp")
                XCTAssertEqual(response.headers[.cacheControl], "max-age=1800, public, stale-while-revalidate=604800")
                XCTAssertEqual(response.headers[.contentDisposition], "inline; filename=\"moon.webp\"; filename*=UTF-8''moon.webp")
                XCTAssertGreaterThan(response.body.readableBytes, 0)
                XCTAssertEqual(Self.sha256(response.body), "03511ce37fe4c163e6af2b64238248fbfc7461241cb125c73f708ea1f4d170de")
            }
        }
    }

    func testInvalidAvatarTokenReturnsNotFound() async throws {
        try await withSeed { databasePath, filesPath, _ in
            let app = try makeApplication(databasePath: databasePath, avatarFilesPath: filesPath)
            try await app.test(.router) { client in
                var loginHeaders = HTTPFields()
                loginHeaders[.contentType] = "application/x-www-form-urlencoded"
                loginHeaders[HTTPField.Name("sec-fetch-site")!] = "same-origin"
                let login = try await client.execute(uri: "/session", method: .post, headers: loginHeaders,
                    body: ByteBuffer(string: "email_address=david%4037signals.com&password=secret123456&authenticity_token="))
                let cookie = try XCTUnwrap(login.headers[.setCookie]).components(separatedBy: ";").first!
                var headers = HTTPFields(); headers[.cookie] = cookie
                let response = try await client.execute(uri: "/users/invalid/avatar", method: .get, headers: headers)
                XCTAssertEqual(response.status.code, 404)
                XCTAssertEqual(response.body.readableBytes, 0)
            }
        }
    }

    func testDigestedStylesheetIsServedFromMemoryWithPublicCachingAndGzip() async throws {
      try await withSeed { databasePath, _, _ in
        let app = try makeApplication(databasePath: databasePath)
        try await app.test(.router) { client in
            var identityHeaders = HTTPFields(); identityHeaders[.acceptEncoding] = "identity"
            let identity = try await client.execute(uri: AssetManifest.stylesheetPath, method: .get, headers: identityHeaders)
            var gzipHeaders = HTTPFields(); gzipHeaders[.acceptEncoding] = "gzip"
            let gzip = try await client.execute(uri: AssetManifest.stylesheetPath, method: .get, headers: gzipHeaders)

            XCTAssertEqual(identity.status.code, 200)
            XCTAssertEqual(identity.headers[.contentType], "text/css; charset=utf-8")
            XCTAssertEqual(identity.headers[.cacheControl], "public, max-age=2592000")
            XCTAssertEqual(Self.sha256(identity.body), "7f1c5a81ffd7cabad2bf71200a48a3317e6897bab8c755c641656ede62635d23")
            XCTAssertEqual(gzip.status.code, 200)
            XCTAssertEqual(gzip.headers[.contentEncoding], "gzip")
            XCTAssertEqual(gzip.headers[.vary], "Accept-Encoding")
            XCTAssertEqual(try Self.gunzip(gzip.body), String(buffer: identity.body))
        }
      }
    }

    private nonisolated static func gunzip(_ body: ByteBuffer) throws -> String {
        var stream = z_stream()
        let initialized = inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        XCTAssertEqual(initialized, Z_OK)
        defer { inflateEnd(&stream) }
        var input = Array(body.readableBytesView)
        var output = [UInt8](repeating: 0, count: 64 * 1024)
        let inputCount = input.count
        let outputCount = output.count
        let result = input.withUnsafeMutableBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                stream.next_in = inputBytes.baseAddress?.assumingMemoryBound(to: Bytef.self)
                stream.avail_in = uInt(inputCount)
                stream.next_out = outputBytes.baseAddress?.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(outputCount)
                return inflate(&stream, Z_FINISH)
            }
        }
        XCTAssertEqual(result, Z_STREAM_END)
        return String(decoding: output.prefix(Int(stream.total_out)), as: UTF8.self)
    }

    private nonisolated static func sha256(_ body: ByteBuffer) -> String {
        Data(SHA256.hash(data: Data(body.readableBytesView))).map { String(format: "%02x", $0) }.joined()
    }

    private func withSeed(_ body: (String, String, [String: String]) async throws -> Void) async throws {
        let source = ProcessInfo.processInfo.environment["CAMPFIRE_SEED_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "parity/.seed/default", directoryHint: .isDirectory)
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
        try FileManager.default.createDirectory(at: temporary.appending(path: "db"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source.appending(path: "db/production.sqlite3"), to: temporary.appending(path: "db/production.sqlite3"))
        try FileManager.default.copyItem(at: source.appending(path: "storage"), to: temporary.appending(path: "files"))
        let labelsData = try Data(contentsOf: source.appending(path: "labels.json"))
        let labels = try XCTUnwrap(JSONSerialization.jsonObject(with: labelsData) as? [String: Any])
            .compactMapValues { $0 as? String }
        try await body(temporary.appending(path: "db/production.sqlite3").path, temporary.appending(path: "files").path, labels)
    }
}
