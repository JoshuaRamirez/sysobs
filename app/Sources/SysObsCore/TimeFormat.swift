import Foundation

/// sysobs stamps: `2026-10-22T07:32:14Z` in the tables, `2026-10-22T07:37:13.842Z` in the light samples and the spool.
/// And the short phrases the menu shows: "3 min ago", "07:32".
public enum TimeFormat {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        withFraction.date(from: s) ?? plain.date(from: s)
    }

    /// Local wall-clock "HH:mm".
    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = clockFormatter.copy() as! DateFormatter
        f.timeZone = timeZone
        return f.string(from: date)
    }

    /// "just now", "3 min ago", "2 h ago", "3 d ago"; a date in the future reads "in 2 min".
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        let past = seconds >= 0
        let s = abs(seconds)
        let phrase: String
        if s < 60 { return past ? "just now" : "in under a minute" }
        else if s < 3600 { phrase = "\(Int(s / 60)) min" }
        else if s < 86400 { phrase = "\(Int(s / 3600)) h" }
        else { phrase = "\(Int(s / 86400)) d" }
        return past ? "\(phrase) ago" : "in \(phrase)"
    }

    /// A refresh interval: "30 s", "90 s", "5 min". Whole minutes from two minutes up read in minutes.
    public static func interval(seconds: Int) -> String {
        if seconds >= 120, seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds) s"
    }

    /// A process lifetime from milliseconds: "150 ms", "2.3 s", "4 min", "3 h".
    public static func duration(ms: Int) -> String {
        if ms < 1000 { return "\(ms) ms" }
        let s = Double(ms) / 1000
        if s < 60 { return String(format: "%.1f s", s) }
        if s < 3600 { return "\(Int(s / 60)) min" }
        if s < 86400 { return "\(Int(s / 3600)) h" }
        return "\(Int(s / 86400)) d"
    }
}
