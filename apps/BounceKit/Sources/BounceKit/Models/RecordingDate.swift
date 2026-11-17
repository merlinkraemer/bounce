import Foundation

/// A recording day is a calendar value, not an instant. The wire/store form is
/// always ISO `yyyy-MM-dd`, which keeps it stable across device time zones.
public enum RecordingDate {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    public static func validate(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let date = isoFormatter.date(from: trimmed),
              isoFormatter.string(from: date) == trimmed else { return nil }
        return trimmed
    }

    /// Converts the calendar day into a Date in the caller's calendar/time zone
    /// for UI controls. The stored value remains the canonical date-only string;
    /// using the caller's calendar avoids showing the previous day when a UTC
    /// midnight is rendered in a western time zone.
    public static func date(
        from value: String?,
        calendar sourceCalendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        guard let canonical = validate(value) else { return nil }
        let parts = canonical.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = sourceCalendar
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: parts[0],
            month: parts[1],
            day: parts[2]
        ))
    }

    public static func string(from date: Date, calendar sourceCalendar: Calendar = .autoupdatingCurrent) -> String {
        let components = sourceCalendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Finds a date token in a title using conservative day-first rules. A
    /// candidate is accepted only when every plausible interpretation points to
    /// the same Gregorian day; ambiguous titles intentionally return nil.
    public static func infer(from title: String) -> String? {
        let pattern = #"(?<!\d)(\d{1,4})([.\-/ ])(\d{1,4})\2(\d{1,4})(?!\d)|(?<!\d)(\d{6})(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(title.startIndex..., in: title)
        let matches = regex.matches(in: title, range: range)
        guard !matches.isEmpty else { return nil }

        // Do not let the first date-looking token win when a filename contains
        // two different dates (for example an export date and a recording date).
        // Collect only valid interpretations and accept the title only when all
        // valid tokens converge on one calendar day.
        var candidates = Set<String>()
        for match in matches {
            if match.range(at: 5).location != NSNotFound {
                let raw = (title as NSString).substring(with: match.range(at: 5))
                if let value = resolve(
                    day: String(raw.prefix(2)),
                    month: String(raw.dropFirst(2).prefix(2)),
                    year: String(raw.suffix(2))
                ) {
                    candidates.insert(value)
                }
                continue
            }

            guard match.numberOfRanges >= 4,
                  let first = substring(title, match.range(at: 1)),
                  let second = substring(title, match.range(at: 3)),
                  let third = substring(title, match.range(at: 4)) else { continue }

            if first.count == 4 || third.count == 4 {
                let value = first.count == 4
                    ? resolve(day: third, month: second, year: first)
                    : resolve(day: first, month: second, year: third)
                if let value { candidates.insert(value) }
                continue
            }

            guard first.count <= 2, second.count <= 2, third.count <= 2 else { continue }
            for year in plausibleYears(twoDigit: third) {
                if let value = makeCanonical(day: first, month: second, year: year) { candidates.insert(value) }
                if let value = makeCanonical(day: second, month: first, year: year) { candidates.insert(value) }
            }
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    private static func resolve(day: String, month: String, year: String) -> String? {
        let years = year.count == 2 ? plausibleYears(twoDigit: year) : [Int(year)].compactMap { $0 }
        let candidates = Set(years.compactMap { makeCanonical(day: day, month: month, year: $0) })
        return candidates.count == 1 ? candidates.first : nil
    }

    private static func plausibleYears(twoDigit: String) -> [Int] {
        guard let value = Int(twoDigit), (0...99).contains(value) else { return [] }
        return [value + 2000, value + 1900].filter { (1970...2069).contains($0) }
    }

    private static func makeCanonical(day: String, month: String, year: Int) -> String? {
        // The 1970–2069 window is applied only when expanding two-digit years
        // in `plausibleYears`. Explicit four-digit dates may be any valid
        // Gregorian year representable by the canonical format.
        guard let day = Int(day), let month = Int(month), (1...9999).contains(year),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        let value = String(format: "%04d-%02d-%02d", year, month, day)
        return validate(value)
    }

    private static func substring(_ value: String, _ range: NSRange) -> String? {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return nil }
        return String(value[swiftRange])
    }
}
