import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import CZlib
import XCTest
@testable import CampfireCore

final class CompressionTests: XCTestCase {
    func testSeededSidebarCanBeRequestedAsGzipOrIdentity() async throws {
        try await withSeed { databasePath in
            let app = try makeApplication(databasePath: databasePath)
            try await app.test(.router) { client in
                var loginHeaders = HTTPFields()
                loginHeaders[.contentType] = "application/x-www-form-urlencoded"
                loginHeaders[HTTPField.Name("sec-fetch-site")!] = "same-origin"
                let login = try await client.execute(uri: "/session", method: .post, headers: loginHeaders,
                    body: ByteBuffer(string: "email_address=david%4037signals.com&password=secret123456&authenticity_token="))
                let cookie = try XCTUnwrap(login.headers[.setCookie]).components(separatedBy: ";").first!

                var identityHeaders = HTTPFields()
                identityHeaders[.cookie] = cookie
                identityHeaders[HTTPField.Name("accept-encoding")!] = "identity"
                let identity = try await client.execute(uri: "/users/me/sidebar", method: .get, headers: identityHeaders)

                var gzipHeaders = HTTPFields()
                gzipHeaders[.cookie] = cookie
                gzipHeaders[HTTPField.Name("accept-encoding")!] = "gzip"
                let gzip = try await client.execute(uri: "/users/me/sidebar", method: .get, headers: gzipHeaders)

                XCTAssertEqual(identity.status.code, 200)
                XCTAssertEqual(gzip.status.code, 200)
                XCTAssertEqual(identity.headers[.contentEncoding], nil)
                XCTAssertEqual(gzip.headers[.contentEncoding], "gzip")
                XCTAssertEqual(gzip.headers[HTTPField.Name("vary")!], "Accept-Encoding")
                XCTAssertNil(gzip.headers[.contentLength])
                XCTAssertEqual(try Self.gunzip(gzip.body), String(buffer: identity.body))
            }
        }
    }

    func testSeededSidebarRejectsWhenNoAvailableEncodingIsAccepted() async throws {
        try await withSeed { databasePath in
            let app = try makeApplication(databasePath: databasePath)
            try await app.test(.router) { client in
                var loginHeaders = HTTPFields()
                loginHeaders[.contentType] = "application/x-www-form-urlencoded"
                loginHeaders[HTTPField.Name("sec-fetch-site")!] = "same-origin"
                let login = try await client.execute(uri: "/session", method: .post, headers: loginHeaders,
                    body: ByteBuffer(string: "email_address=david%4037signals.com&password=secret123456&authenticity_token="))
                let cookie = try XCTUnwrap(login.headers[.setCookie]).components(separatedBy: ";").first!
                var headers = HTTPFields()
                headers[.cookie] = cookie
                headers[HTTPField.Name("accept-encoding")!] = "gzip;q=0, identity;q=0"
                let response = try await client.execute(uri: "/users/me/sidebar", method: .get, headers: headers)
                XCTAssertEqual(response.status.code, 406)
            }
        }
    }

    private nonisolated static func gunzip(_ body: ByteBuffer) throws -> String {
        var stream = z_stream()
        let initialized = inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        XCTAssertEqual(initialized, Z_OK)
        defer { inflateEnd(&stream) }

        var input = Array(body.readableBytesView)
        var output = [UInt8](repeating: 0, count: 256 * 1024)
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

    private func withSeed(_ body: (String) async throws -> Void) async throws {
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
        try FileManager.default.copyItem(at: source, to: temporary)
        try await body(temporary.appending(path: "db/production.sqlite3").path)
    }
}
