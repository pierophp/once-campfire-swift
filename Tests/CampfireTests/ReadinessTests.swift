import Foundation
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import CampfireCore

final class ReadinessTests: XCTestCase {
    func testReadinessRouteWithParitySeed() async throws {
        let source = seedDirectory
        let databaseURL = source.appending(path: "db/production.sqlite3")
        let labelsURL = source.appending(path: "labels.json")
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              FileManager.default.fileExists(atPath: labelsURL.path) else {
            if ProcessInfo.processInfo.environment["CAMPFIRE_REQUIRE_SEED"] == "1" {
                XCTFail("Parity seed required but db/production.sqlite3 or labels.json was not found at \(source.path)")
                return
            }
            throw XCTSkip("Parity seed db/production.sqlite3 + labels.json not found at \(source.path); set CAMPFIRE_REQUIRE_SEED=1 to require it")
        }

        let temporarySeed = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporarySeed) }
        try FileManager.default.copyItem(at: source, to: temporarySeed)
        let database = temporarySeed.appending(path: "db/production.sqlite3")
        let app = try makeApplication(databasePath: database.path)

        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/up", method: .get)
            XCTAssertTrue((200..<300).contains(response.status.code))
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
