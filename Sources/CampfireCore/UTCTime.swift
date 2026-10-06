import Foundation

/// Proleptic Gregorian UTC arithmetic for the fixed formats used on request paths.
/// Foundation's Calendar and DateFormatter create ICU objects per call, which cost more than
/// rendering a cached message page.
enum UTCTime {
    struct Fields { var year: Int64; var month: Int; var day: Int; var hour: Int; var minute: Int; var second: Int; var weekday: Int }

    /// Whether `Calendar(identifier: .gregorian)` year arithmetic in the current zone equals UTC arithmetic.
    static let currentZoneIsUTC: Bool = {
        let zone = TimeZone.current
        return zone.secondsFromGMT() == 0 && zone.nextDaylightSavingTimeTransition == nil
    }()

    static func nowSeconds() -> Int64 { Int64(Date().timeIntervalSince1970.rounded(.down)) }

    static func fields(_ seconds: Int64) -> Fields {
        let days = floorDivide(seconds, 86_400)
        let secondOfDay = Int(seconds - days * 86_400)
        let (year, month, day) = civil(fromDays: days)
        // 1970-01-01 was a Thursday; weekday 0 is Sunday.
        let weekday = Int(((days % 7) + 11) % 7)
        return Fields(year: year, month: month, day: day, hour: secondOfDay / 3_600, minute: secondOfDay % 3_600 / 60, second: secondOfDay % 60, weekday: weekday)
    }

    static func seconds(year: Int64, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Int64 {
        days(fromCivil: year, month, day) * 86_400 + Int64(hour * 3_600 + minute * 60 + second)
    }

    /// `Calendar.date(byAdding: .year, value:)` in UTC: same wall time, Feb 29 clamps to Feb 28.
    static func adding(years: Int, to seconds: Int64) -> Int64 {
        let f = fields(seconds)
        let year = f.year + Int64(years)
        let day = f.month == 2 && f.day == 29 && !isLeap(year) ? 28 : f.day
        return Self.seconds(year: year, month: f.month, day: day, hour: f.hour, minute: f.minute, second: f.second)
    }

    /// Seconds twenty years from now, with the same rules as the previous Calendar call.
    static func twentyYearsFromNow() -> Int64 {
        if currentZoneIsUTC { return adding(years: 20, to: nowSeconds()) }
        let expiry = Calendar(identifier: .gregorian).date(byAdding: .year, value: 20, to: Date()) ?? Date()
        return Int64(expiry.timeIntervalSince1970.rounded(.down))
    }

    /// `yyyy-MM-dd'T'HH:mm:ss'Z'`
    static func iso8601(_ seconds: Int64) -> String {
        let f = fields(seconds)
        var out: [UInt8] = []; out.reserveCapacity(20)
        pad(f.year, 4, &out); out.append(45); pad(f.month, 2, &out); out.append(45); pad(f.day, 2, &out)
        out.append(84); pad(f.hour, 2, &out); out.append(58); pad(f.minute, 2, &out); out.append(58); pad(f.second, 2, &out); out.append(90)
        return String(decoding: out, as: UTF8.self)
    }

    /// `EEE, dd MMM yyyy HH:mm:ss 'GMT'`
    static func httpDate(_ seconds: Int64) -> String {
        let f = fields(seconds)
        var out: [UInt8] = []; out.reserveCapacity(29)
        out.append(contentsOf: weekdays[f.weekday]); out.append(contentsOf: [44, 32]); pad(f.day, 2, &out); out.append(32)
        out.append(contentsOf: months[f.month - 1]); out.append(32); pad(f.year, 4, &out); out.append(32)
        pad(f.hour, 2, &out); out.append(58); pad(f.minute, 2, &out); out.append(58); pad(f.second, 2, &out)
        out.append(contentsOf: [32, 71, 77, 84])
        return String(decoding: out, as: UTF8.self)
    }

    /// `yyyy-MM-dd HH:mm:ss.SSSSSS` for the current instant, truncating to microseconds.
    static func sqliteNow() -> String {
        let now = Date().timeIntervalSince1970
        let whole = now.rounded(.down)
        let micros = Int((now - whole) * 1_000_000)
        let f = fields(Int64(whole))
        var out: [UInt8] = []; out.reserveCapacity(26)
        pad(f.year, 4, &out); out.append(45); pad(f.month, 2, &out); out.append(45); pad(f.day, 2, &out)
        out.append(32); pad(f.hour, 2, &out); out.append(58); pad(f.minute, 2, &out); out.append(58); pad(f.second, 2, &out)
        out.append(46); pad(micros, 6, &out)
        return String(decoding: out, as: UTF8.self)
    }

    /// Parses `yyyy-MM-dd[ T]HH:mm:ss[.fraction][Z]` with valid field ranges. Returns nil for any
    /// other shape (or a year before 1600, where ICU switches to the Julian calendar) so callers
    /// can defer to the general parser. Fractions keep milliseconds,
    /// truncating extra digits like ICU's fractional-second field.
    static func parseMicroseconds(_ value: String) -> Int64? {
        var value = value
        return value.withUTF8 { b -> Int64? in
            var n = b.count
            if n > 0 && b[n - 1] == 90 { n -= 1 }
            guard n >= 19, b[4] == 45, b[7] == 45, b[10] == 32 || b[10] == 84, b[13] == 58, b[16] == 58 else { return nil }
            func digits(_ start: Int, _ count: Int) -> Int? {
                var result = 0
                for i in start..<(start + count) {
                    let d = Int(b[i]) - 48
                    guard d >= 0 && d <= 9 else { return nil }
                    result = result * 10 + d
                }
                return result
            }
            guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
                  let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
                  year >= 1600, (1...12).contains(month), day >= 1, day <= daysInMonth(Int64(year), month),
                  hour <= 23, minute <= 59, second <= 59 else { return nil }
            var millis = 0
            if n > 19 {
                let fractionDigits = n - 20
                guard b[19] == 46, (1...9).contains(fractionDigits), let fraction = digits(20, fractionDigits) else { return nil }
                var scaled = fraction, count = fractionDigits
                while count < 3 { scaled *= 10; count += 1 }
                while count > 3 { scaled /= 10; count -= 1 }
                millis = scaled
            }
            let whole = seconds(year: Int64(year), month: month, day: day, hour: hour, minute: minute, second: second)
            // Repeat the formatter's floating-point path exactly: ICU's millisecond UDate becomes an
            // absolute time, then a Unix time, then rounded microseconds. Far from 1970 that path
            // can differ by 1µs from integer arithmetic, and validators must not change.
            let referenceOffset = 978_307_200.0
            let unix = (Double(whole * 1_000 + Int64(millis)) / 1_000.0 - referenceOffset) + referenceOffset
            return Int64((unix * 1_000_000).rounded())
        }
    }

    /// SQLite's `CAST(strftime('%s', t) AS INTEGER) * 1000 + CAST(substr(t || '.000', 21, 3) AS INTEGER)`
    /// for Rails' `yyyy-MM-dd HH:mm:ss[.fff…]` with at least three fraction digits, years 1970–9999.
    /// SQLite caps the fraction below a second, so `%s` is the whole seconds, and `substr` takes the
    /// first three fraction digits. Other shapes return nil; callers evaluate the SQL instead.
    static func sqliteEpochMilliseconds(_ value: String) -> Int64? {
        var value = value
        return value.withUTF8 { b -> Int64? in
            let n = b.count
            guard n == 19 || n >= 23, b[4] == 45, b[7] == 45, b[10] == 32, b[13] == 58, b[16] == 58 else { return nil }
            func digits(_ start: Int, _ count: Int) -> Int? {
                var result = 0
                for i in start..<(start + count) {
                    let d = Int(b[i]) - 48
                    guard d >= 0 && d <= 9 else { return nil }
                    result = result * 10 + d
                }
                return result
            }
            guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
                  let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
                  year >= 1970, (1...12).contains(month), day >= 1, day <= daysInMonth(Int64(year), month),
                  hour <= 23, minute <= 59, second <= 59 else { return nil }
            var millis = 0
            if n > 19 {
                guard b[19] == 46, let fraction = digits(20, 3), digits(23, n - 23) != nil || n == 23 else { return nil }
                millis = fraction
            }
            return seconds(year: Int64(year), month: month, day: day, hour: hour, minute: minute, second: second) * 1_000 + Int64(millis)
        }
    }

    static func isLeap(_ year: Int64) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }

    private static func daysInMonth(_ year: Int64, _ month: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].map { Array($0.utf8) }
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].map { Array($0.utf8) }

    private static func pad<T: BinaryInteger>(_ value: T, _ width: Int, _ out: inout [UInt8]) {
        var digits: [UInt8] = []
        var v = Int64(value)
        let negative = v < 0
        if negative { v = -v }
        repeat { digits.append(UInt8(48 + v % 10)); v /= 10 } while v > 0
        if negative { out.append(45) }
        for _ in digits.count..<max(width, digits.count) { out.append(48) }
        out.append(contentsOf: digits.reversed())
    }

    private static func floorDivide(_ a: Int64, _ b: Int64) -> Int64 { a >= 0 ? a / b : -((-a + b - 1) / b) }

    // Howard Hinnant's days_from_civil / civil_from_days.
    private static func days(fromCivil year: Int64, _ month: Int, _ day: Int) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = floorDivide(y, 400)
        let yoe = y - era * 400
        let m = Int64(month)
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + Int64(day) - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civil(fromDays z: Int64) -> (Int64, Int, Int) {
        let shifted = z + 719_468
        let era = floorDivide(shifted, 146_097)
        let doe = shifted - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = Int(doy - (153 * mp + 2) / 5 + 1)
        let month = Int(mp < 10 ? mp + 3 : mp - 9)
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}
