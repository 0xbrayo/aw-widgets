import Foundation
import SwiftUI

// MARK: - Day boundaries (ActivityWatch settings)

/// Mirrors aw-webui settings `startOfDay` / `startOfWeek` (defaults match the web UI).
struct DaySettings: Codable, Sendable, Equatable {
    /// `"HH:mm"` offset from midnight, e.g. `"04:00"`.
    var startOfDay: String
    /// `"Monday"` or `"Sunday"` (anything else treated as Sunday/local week).
    var startOfWeek: String

    static let awDefaults = DaySettings(startOfDay: "04:00", startOfWeek: "Monday")

    var startOfDayComponents: (hour: Int, minute: Int) {
        let parts = startOfDay.split(separator: ":")
        let hour = parts.first.flatMap { Int($0) } ?? 0
        let minute = parts.dropFirst().first.flatMap { Int($0) } ?? 0
        return (max(0, min(23, hour)), max(0, min(59, minute)))
    }

    var startOfDayMinuteOffset: Int {
        let c = startOfDayComponents
        return c.hour * 60 + c.minute
    }

    /// Whether weeks start on Monday (AW `isoWeek`) vs Sunday (`week`).
    var weekStartsOnMonday: Bool {
        startOfWeek.lowercased().hasPrefix("mon")
    }
}

// MARK: - Time range

enum TimeRange: String, CaseIterable, Identifiable, Codable, Sendable {
    case today
    case yesterday
    case week

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .week: return "This Week"
        }
    }

    /// Local period as start...end for the AW query API, using the user's day/week settings.
    ///
    /// Matches aw-webui `get_today_with_offset` / `get_day_start_with_offset`: a non-zero
    /// `startOfDay` (e.g. `04:00`) means hours before that offset still count as the previous day.
    func period(
        now: Date = Date(),
        calendar: Calendar = .current,
        daySettings: DaySettings = SharedStore.daySettings
    ) -> (start: Date, end: Date) {
        let todayStart = Self.currentDayStart(now: now, calendar: calendar, daySettings: daySettings)
        switch self {
        case .today:
            return (todayStart, now)
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
            return (start, todayStart)
        case .week:
            let start = Self.currentWeekStart(now: now, calendar: calendar, daySettings: daySettings)
            return (start, now)
        }
    }

    /// Start of the offset-aware "today" (same idea as aw-webui `get_day_start_with_offset(get_today_with_offset())`).
    static func currentDayStart(
        now: Date = Date(),
        calendar: Calendar = .current,
        daySettings: DaySettings = SharedStore.daySettings
    ) -> Date {
        let offsetMinutes = daySettings.startOfDayMinuteOffset
        let (hour, minute) = daySettings.startOfDayComponents

        // Logical calendar day: subtract offset, then take midnight of that moment.
        let shifted = calendar.date(byAdding: .minute, value: -offsetMinutes, to: now) ?? now
        let logicalMidnight = calendar.startOfDay(for: shifted)
        return calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: logicalMidnight)
            ?? logicalMidnight
    }

    /// Start of the offset-aware week containing "today".
    static func currentWeekStart(
        now: Date = Date(),
        calendar: Calendar = .current,
        daySettings: DaySettings = SharedStore.daySettings
    ) -> Date {
        let todayStart = currentDayStart(now: now, calendar: calendar, daySettings: daySettings)
        // Week membership is based on the logical calendar day (before applying hour offset),
        // matching moment's startOf('isoWeek'/'week') on the offset-aware date.
        let offsetMinutes = daySettings.startOfDayMinuteOffset
        let logicalMidnight = calendar.date(byAdding: .minute, value: -offsetMinutes, to: todayStart)
            ?? calendar.startOfDay(for: todayStart)

        var cal = calendar
        cal.firstWeekday = daySettings.weekStartsOnMonday ? 2 : 1 // 1=Sun, 2=Mon

        let weekday = cal.component(.weekday, from: logicalMidnight)
        let daysFromWeekStart = (weekday - cal.firstWeekday + 7) % 7
        let weekMidnight = cal.date(byAdding: .day, value: -daysFromWeekStart, to: logicalMidnight)
            ?? logicalMidnight

        let (hour, minute) = daySettings.startOfDayComponents
        return cal.date(byAdding: DateComponents(hour: hour, minute: minute), to: weekMidnight)
            ?? weekMidnight
    }
}

// MARK: - AW settings category

struct AWCategoryClass: Codable, Sendable, Identifiable {
    let id: Int?
    let name: [String]
    let rule: AWRule
    let data: AWCategoryData?

    var label: String { name.joined(separator: " › ") }
    var colorHex: String? { data?.color }
}

struct AWRule: Codable, Sendable {
    let type: String
    let regex: String?
    let ignore_case: Bool?
}

struct AWCategoryData: Codable, Sendable {
    let color: String?
    let score: AWScore?

    enum AWScore: Codable, Sendable {
        case int(Int)
        case string(String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) {
                self = .int(i)
            } else if let s = try? c.decode(String.self) {
                self = .string(s)
            } else {
                self = .string("")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .int(let i): try c.encode(i)
            case .string(let s): try c.encode(s)
            }
        }
    }
}

// MARK: - Snapshot for widgets / UI

struct CategoryDuration: Codable, Identifiable, Sendable, Hashable {
    var id: String { path.joined(separator: "/") }
    let path: [String]
    let seconds: Double
    let colorHex: String?

    var label: String {
        path.last ?? path.joined(separator: " › ")
    }

    var fullLabel: String {
        path.joined(separator: " › ")
    }

    var color: Color {
        Color(hex: colorHex ?? CategoryPalette.color(for: path))
    }
}

struct CategorySnapshot: Codable, Sendable {
    let fetchedAt: Date
    let timeRange: TimeRange
    let periodStart: Date
    let periodEnd: Date
    let totalSeconds: Double
    let categories: [CategoryDuration]
    let serverHostname: String?
    let errorMessage: String?

    static let empty = CategorySnapshot(
        fetchedAt: .distantPast,
        timeRange: .today,
        periodStart: .distantPast,
        periodEnd: .distantPast,
        totalSeconds: 0,
        categories: [],
        serverHostname: nil,
        errorMessage: nil
    )

    var isStale: Bool {
        Date().timeIntervalSince(fetchedAt) > 30 * 60
    }

    func withError(_ message: String?) -> CategorySnapshot {
        CategorySnapshot(
            fetchedAt: fetchedAt,
            timeRange: timeRange,
            periodStart: periodStart,
            periodEnd: periodEnd,
            totalSeconds: totalSeconds,
            categories: categories,
            serverHostname: serverHostname,
            errorMessage: message
        )
    }
}

// MARK: - Formatting

enum DurationFormat {
    static func short(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 {
            return String(format: "%dh %02dm", h, m)
        }
        return String(format: "%dm", m)
    }

    static func compact(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }
}

// MARK: - Colors

enum CategoryPalette {
    private static let defaults: [String: String] = [
        "Work": "#34C759",
        "Media": "#FF3B30",
        "Comms": "#5AC8FA",
        "Learning": "#7B64FF",
        "Finance": "#AB149E",
        "Uncategorized": "#8E8E93",
    ]

    static func color(for path: [String]) -> String {
        if let root = path.first, let hex = defaults[root] {
            return hex
        }
        // Stable hash-ish color from path
        let hash = path.joined().utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let hues: [String] = ["#FF9500", "#FF2D55", "#5856D6", "#007AFF", "#32ADE6", "#30B0C7", "#34C759"]
        return hues[abs(hash) % hues.count]
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: Double
        switch cleaned.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        default:
            r = 0.5; g = 0.5; b = 0.5
        }
        self.init(red: r, green: g, blue: b)
    }
}
