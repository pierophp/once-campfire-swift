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

final class UTCTimeTests: XCTestCase {
    /// The arithmetic parser must agree with the ISO8601DateFormatter oracle for every shape it accepts.
    func testArithmeticParserMatchesFormatterOracle() {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        func oracle(_ value: String) -> Int64 {
            let normalized = value.replacingOccurrences(of: " ", with: "T")
            let input = normalized.hasSuffix("Z") ? normalized : normalized + "Z"
            if let date = fractional.date(from: input) { return Int64((date.timeIntervalSince1970 * 1_000_000).rounded()) }
            if let date = whole.date(from: input) { return Int64(date.timeIntervalSince1970 * 1_000_000) }
            return 0
        }
        var generator = SystemRandomNumberGenerator()
        var checked = 0
        for index in 0..<40_000 {
            let year = index % 10 == 0 ? Int.random(in: 1600...2400, using: &generator) : Int.random(in: 1960...2100, using: &generator)
            let month = Int.random(in: 1...12, using: &generator)
            let day = Int.random(in: 1...31, using: &generator)
            let time = String(format: "%02d:%02d:%02d", Int.random(in: 0...23, using: &generator), Int.random(in: 0...59, using: &generator), Int.random(in: 0...59, using: &generator))
            let digits = Int.random(in: 0...9, using: &generator)
            let fraction = digits == 0 ? "" : "." + String((0..<digits).map { _ in "0123456789".randomElement(using: &generator)! })
            let separator = Bool.random(using: &generator) ? " " : "T"
            let zone = Bool.random(using: &generator) ? "Z" : ""
            let value = String(format: "%04d-%02d-%02d", year, month, day) + separator + time + fraction + zone
            guard let fast = UTCTime.parseMicroseconds(value) else { continue }
            XCTAssertEqual(fast, oracle(value), value)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 30_000)
        for value in ["2024-02-29 23:59:59.999999", "2023-02-29 00:00:00", "2026-13-01 00:00:00", "2026-01-01 24:00:00", "1500-01-01 00:00:00", "2026-01-01 00:00:60"] {
            XCTAssertEqual(timestampMicroseconds(value), oracle(value), value)
        }
    }

    func testFormattersMatchFoundation() {
        let http = DateFormatter()
        http.locale = Locale(identifier: "en_US_POSIX")
        http.timeZone = TimeZone(secondsFromGMT: 0)
        http.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let iso = ISO8601DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var generator = SystemRandomNumberGenerator()
        var samples: [Int64] = [0, -1, 951_782_400, 951_868_799, 4_107_542_399, 1_709_164_800, 1_709_251_199]
        for _ in 0..<20_000 { samples.append(Int64.random(in: -2_000_000_000...7_000_000_000, using: &generator)) }
        for seconds in samples {
            let date = Date(timeIntervalSince1970: TimeInterval(seconds))
            XCTAssertEqual(UTCTime.httpDate(seconds), http.string(from: date), "\(seconds)")
            XCTAssertEqual(UTCTime.iso8601(seconds), iso.string(from: date), "\(seconds)")
            let expected = calendar.date(byAdding: .year, value: 20, to: date)!
            XCTAssertEqual(UTCTime.adding(years: 20, to: seconds), Int64(expected.timeIntervalSince1970), "\(seconds)")
        }
    }
}
