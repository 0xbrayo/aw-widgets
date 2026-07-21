import Foundation
import WidgetKit

/// Cache used by the WidgetKit extension.
/// Uses the extension's Application Support container.
enum SharedStore {
    static let appGroupID = "group.com.0xbrayo.aw-widgets" // reserved for future App Group use
    static let selectedRangeKey = "selectedTimeRange"
    static let lastErrorKey = "lastError"

    private static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("aw-widgets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func snapshotURL(for range: TimeRange) -> URL {
        supportDir.appendingPathComponent("snapshot-\(range.rawValue).json")
    }

    private static var metaURL: URL {
        supportDir.appendingPathComponent("meta.json")
    }

    private struct Meta: Codable {
        var selectedRange: String
        var lastError: String?
        var startOfDay: String?
        var startOfWeek: String?
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func save(_ snapshot: CategorySnapshot, daySettings: DaySettings? = nil, reloadTimelines: Bool = true) {
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: snapshotURL(for: snapshot.timeRange), options: .atomic)
            writeMeta(
                selected: snapshot.timeRange,
                error: snapshot.errorMessage,
                daySettings: daySettings ?? self.daySettings
            )
            if reloadTimelines {
                WidgetCenter.shared.reloadAllTimelines()
            }
        } catch {
            writeMeta(
                selected: snapshot.timeRange,
                error: error.localizedDescription,
                daySettings: daySettings ?? self.daySettings
            )
        }
    }

    static func load(range: TimeRange) -> CategorySnapshot? {
        let url = snapshotURL(for: range)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(CategorySnapshot.self, from: data)
    }

    static var selectedRange: TimeRange {
        get {
            guard let meta = readMeta(),
                  let range = TimeRange(rawValue: meta.selectedRange)
            else { return .today }
            return range
        }
        set {
            writeMeta(selected: newValue, error: lastError, daySettings: daySettings)
        }
    }

    static var lastError: String? {
        readMeta()?.lastError
    }

    /// Cached AW day boundaries (defaults match aw-webui until first successful settings fetch).
    static var daySettings: DaySettings {
        get {
            guard let meta = readMeta() else { return .awDefaults }
            return DaySettings(
                startOfDay: meta.startOfDay ?? DaySettings.awDefaults.startOfDay,
                startOfWeek: meta.startOfWeek ?? DaySettings.awDefaults.startOfWeek
            )
        }
        set {
            writeMeta(selected: selectedRange, error: lastError, daySettings: newValue)
        }
    }

    private static func readMeta() -> Meta? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    private static func writeMeta(selected: TimeRange, error: String?, daySettings: DaySettings) {
        let meta = Meta(
            selectedRange: selected.rawValue,
            lastError: error,
            startOfDay: daySettings.startOfDay,
            startOfWeek: daySettings.startOfWeek
        )
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }
}
