import Foundation

/// Timestamp strings are immutable version identifiers. SQLite's canonical shapes are parsed
/// arithmetically; anything else keeps the ISO8601DateFormatter interpretation, memoized.
final class SQLiteTimestampCache: @unchecked Sendable {
    static let shared = SQLiteTimestampCache()
    private let lock = NSLock()
    private let fractional = ISO8601DateFormatter()
    private let wholeSeconds = ISO8601DateFormatter()
    private var values: [String: Int64] = [:]
    private var order: [String] = []
    private var evictionIndex = 0

    private init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        wholeSeconds.formatOptions = [.withInternetDateTime]
    }

    func microseconds(_ value: String) -> Int64 {
        if let parsed = UTCTime.parseMicroseconds(value) { return parsed }
        return formatterMicroseconds(value)
    }

    private func formatterMicroseconds(_ value: String) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        if let cached = values[value] { return cached }
        let normalized = value.replacingOccurrences(of: " ", with: "T")
        let input = normalized.hasSuffix("Z") ? normalized : normalized + "Z"
        let result: Int64
        if let date = fractional.date(from: input) {
            result = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        } else if let date = wholeSeconds.date(from: input) {
            result = Int64(date.timeIntervalSince1970 * 1_000_000)
        } else {
            result = 0
        }
        if order.count == 4_096 {
            values.removeValue(forKey: order[evictionIndex])
            order[evictionIndex] = value
            evictionIndex = (evictionIndex + 1) % order.count
        } else {
            order.append(value)
        }
        values[value] = result
        return result
    }
}
