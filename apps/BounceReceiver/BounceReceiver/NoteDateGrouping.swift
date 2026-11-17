import Foundation
import BounceKit

enum NoteDateGrouping {
    static func sectionTitle(for date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        let daysAgo = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if daysAgo > 0 && daysAgo < 7 {
            return weekdayFormatter.string(from: date)
        }

        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return shortDateFormatter.string(from: date)
        }

        return longDateFormatter.string(from: date)
    }

    static func grouped(_ notes: [Note]) -> [NoteDateSection] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: notes) { calendar.startOfDay(for: $0.createdAt) }
        return groups
            .map { day, items in
                NoteDateSection(
                    day: day,
                    notes: items.sorted { $0.createdAt > $1.createdAt }
                )
            }
            .sorted { $0.day > $1.day }
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()
}

struct NoteDateSection: Identifiable {
    let day: Date
    let notes: [Note]
    var id: Date { day }
}
