import Foundation
import XCTest
@testable import CampfireCore

final class TimestampParsingTests: XCTestCase {
    func testCachedTimestampsPreserveValidatorPrecisionAndNormalization() {
        let values = [
            "2026-01-01 00:00:00", "2026-01-01T00:00:00Z",
            "2026-01-01 00:00:00.1", "2026-01-01 00:00:00.123456",
            "2026-01-01 00:00:00.123457", "2026-01-01T00:00:00.999999Z",
            "2024-02-29 23:59:59.000001", "1969-12-31 23:59:59",
            "", "not a date", "2026-01-01T00:00:00+02:00",
        ]
        for _ in 0..<2 {
            for value in values.reversed() {
                XCTAssertEqual(timestampMicroseconds(value), originalParser(value), value)
            }
        }
    }

    /// The pre-optimization parser is the oracle for response validators already in use.
    private func originalParser(_ value: String) -> Int64 {
        let normalized = value.replacingOccurrences(of: " ", with: "T")
        let input = normalized.hasSuffix("Z") ? normalized : normalized + "Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: input) {
            return Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: input) {
            return Int64(date.timeIntervalSince1970 * 1_000_000)
        }
        return 0
    }
}
