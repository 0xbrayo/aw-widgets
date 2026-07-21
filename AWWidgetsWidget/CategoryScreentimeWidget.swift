import WidgetKit
import SwiftUI
import AppIntents
import AppKit

// MARK: - Configuration

struct CategoryWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Screen Time by Category"
    static var description = IntentDescription("ActivityWatch screen time broken down by your categories.")

    @Parameter(title: "Time Range", default: .today)
    var timeRange: TimeRangeAppEnum
}

enum TimeRangeAppEnum: String, AppEnum {
    case today
    case yesterday
    case week

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Time Range")
    static var caseDisplayRepresentations: [TimeRangeAppEnum: DisplayRepresentation] = [
        .today: "Today",
        .yesterday: "Yesterday",
        .week: "This Week",
    ]

    var timeRange: TimeRange {
        switch self {
        case .today: return .today
        case .yesterday: return .yesterday
        case .week: return .week
        }
    }
}

// MARK: - Timeline

struct CategoryEntry: TimelineEntry {
    let date: Date
    let snapshot: CategorySnapshot
    let configuration: CategoryWidgetConfiguration
}

struct CategoryTimelineProvider: AppIntentTimelineProvider {
    typealias Entry = CategoryEntry
    typealias Intent = CategoryWidgetConfiguration

    private let refreshInterval: TimeInterval = 5 * 60

    func placeholder(in context: Context) -> CategoryEntry {
        CategoryEntry(
            date: Date(),
            snapshot: .placeholder,
            configuration: CategoryWidgetConfiguration()
        )
    }

    func snapshot(for configuration: CategoryWidgetConfiguration, in context: Context) async -> CategoryEntry {
        let range = configuration.timeRange.timeRange
        let snap = SharedStore.load(range: range) ?? .placeholder
        return CategoryEntry(date: Date(), snapshot: snap, configuration: configuration)
    }

    func timeline(for configuration: CategoryWidgetConfiguration, in context: Context) async -> Timeline<CategoryEntry> {
        let range = configuration.timeRange.timeRange
        var snap = SharedStore.load(range: range)
        let now = Date()
        let safeEnd = now.addingTimeInterval(-300)
        let refreshBefore = safeEnd.addingTimeInterval(-refreshInterval)

        // Widget may also refresh from AW if the companion app is not running.
        if snap == nil || (snap?.isStale ?? true) {
            if let fresh = try? await AWClient().fetchCategoryDurations(timeRange: range, to: safeEnd, now: now) {
                SharedStore.save(fresh.snapshot, daySettings: fresh.daySettings, reloadTimelines: false)
                snap = fresh.snapshot
            }
        } else if let cached = snap, cached.fetchedAt < refreshBefore {
            if let delta = try? await AWClient().fetchCategoryDurations(timeRange: range, from: cached.fetchedAt, to: safeEnd, now: now) {
                let merged = cached.merging(with: delta.snapshot, fetchedAt: delta.snapshot.fetchedAt)
                SharedStore.save(merged, daySettings: delta.daySettings, reloadTimelines: false)
                snap = merged
            }
        }

        var displaySnap = snap ?? .emptyWith(range: range)
        if displaySnap.fetchedAt <= safeEnd {
            if let deltaUncached = try? await AWClient().fetchCategoryDurations(timeRange: range, from: safeEnd, to: now, now: now) {
                displaySnap = displaySnap.merging(with: deltaUncached.snapshot, fetchedAt: deltaUncached.snapshot.fetchedAt)
            }
        }

        let entry = CategoryEntry(
            date: now,
            snapshot: displaySnap,
            configuration: configuration
        )
        // Reload on a modest cadence; companion app also triggers reloads.
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: now) ?? now.addingTimeInterval(300)
        return Timeline(entries: [entry], policy: .after(next))
    }
}

// MARK: - Widget

struct CategoryScreentimeWidget: Widget {
    let kind = "CategoryScreentimeWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: CategoryWidgetConfiguration.self,
            provider: CategoryTimelineProvider()
        ) { entry in
            CategoryWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(nsColor: .windowBackgroundColor)
                }
        }
        .configurationDisplayName("AW Categories")
        .description("Screen time per ActivityWatch category.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Views

struct CategoryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CategoryEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallCategoryView(snapshot: entry.snapshot, range: entry.configuration.timeRange.timeRange)
        case .systemMedium:
            MediumCategoryView(snapshot: entry.snapshot, range: entry.configuration.timeRange.timeRange)
        default:
            LargeCategoryView(snapshot: entry.snapshot, range: entry.configuration.timeRange.timeRange)
        }
    }
}

struct SmallCategoryView: View {
    let snapshot: CategorySnapshot
    let range: TimeRange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(range.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chart.bar.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(DurationFormat.short(snapshot.totalSeconds))
                .font(.title2.weight(.bold).monospacedDigit())
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            if let top = snapshot.categories.first {
                HStack(spacing: 4) {
                    Circle().fill(top.color).frame(width: 6, height: 6)
                    Text(top.label)
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer()
                    Text(DurationFormat.compact(top.seconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if let err = snapshot.errorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            } else {
                Text("No data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct MediumCategoryView: View {
    let snapshot: CategorySnapshot
    let range: TimeRange

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Screen Time · \(range.displayName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(DurationFormat.short(snapshot.totalSeconds))
                    .font(.caption.weight(.semibold).monospacedDigit())
            }

            if !snapshot.categories.isEmpty {
                WidgetBarStack(categories: Array(snapshot.categories.prefix(6)), total: snapshot.totalSeconds)
                    .frame(height: 8)
                    .clipShape(Capsule())
            }

            VStack(spacing: 4) {
                ForEach(Array(snapshot.categories.prefix(4))) { cat in
                    WidgetCategoryRow(category: cat, total: snapshot.totalSeconds)
                }
            }

            if snapshot.categories.isEmpty {
                emptyOrError
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var emptyOrError: some View {
        if let err = snapshot.errorMessage {
            Text(err)
                .font(.caption2)
                .foregroundStyle(.orange)
        } else {
            Text("No activity yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LargeCategoryView: View {
    let snapshot: CategorySnapshot
    let range: TimeRange

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ActivityWatch")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(range.displayName)
                        .font(.headline)
                }
                Spacer()
                Text(DurationFormat.short(snapshot.totalSeconds))
                    .font(.title2.weight(.bold).monospacedDigit())
            }

            if !snapshot.categories.isEmpty {
                WidgetBarStack(categories: Array(snapshot.categories.prefix(8)), total: snapshot.totalSeconds)
                    .frame(height: 10)
                    .clipShape(Capsule())
            }

            VStack(spacing: 5) {
                ForEach(Array(snapshot.categories.prefix(8))) { cat in
                    WidgetCategoryRow(category: cat, total: snapshot.totalSeconds, showFullLabel: true)
                }
            }

            if snapshot.categories.isEmpty {
                if let err = snapshot.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.orange)
                } else {
                    Text("No activity for this period.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if snapshot.fetchedAt != .distantPast {
                Text("Updated \(snapshot.fetchedAt, style: .time)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct WidgetCategoryRow: View {
    let category: CategoryDuration
    let total: Double
    var showFullLabel: Bool = false

    private var pct: Int {
        guard total > 0 else { return 0 }
        return Int((category.seconds / total * 100).rounded())
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(category.color)
                .frame(width: 7, height: 7)
            Text(showFullLabel ? category.fullLabel : category.label)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(pct)%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .trailing)
            Text(DurationFormat.compact(category.seconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

struct WidgetBarStack: View {
    let categories: [CategoryDuration]
    let total: Double

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(categories) { cat in
                    let w = total > 0 ? geo.size.width * CGFloat(cat.seconds / total) : 0
                    Rectangle()
                        .fill(cat.color)
                        .frame(width: max(w, cat.seconds > 0 ? 2 : 0))
                }
            }
        }
    }
}

// MARK: - Placeholder data

extension CategorySnapshot {
    static let placeholder = CategorySnapshot(
        fetchedAt: Date(),
        timeRange: .today,
        periodStart: Date(),
        periodEnd: Date(),
        totalSeconds: 4 * 3600 + 32 * 60,
        categories: [
            CategoryDuration(path: ["Work", "Programming"], seconds: 2.5 * 3600, colorHex: "#34C759"),
            CategoryDuration(path: ["Media", "Video"], seconds: 0.8 * 3600, colorHex: "#FF3B30"),
            CategoryDuration(path: ["Comms", "IM"], seconds: 0.5 * 3600, colorHex: "#5AC8FA"),
            CategoryDuration(path: ["Learning"], seconds: 0.4 * 3600, colorHex: "#7B64FF"),
            CategoryDuration(path: ["Uncategorized"], seconds: 0.2 * 3600, colorHex: "#8E8E93"),
        ],
        serverHostname: "Mac",
        errorMessage: nil
    )

    static func emptyWith(range: TimeRange) -> CategorySnapshot {
        let period = range.period(daySettings: SharedStore.daySettings)
        return CategorySnapshot(
            fetchedAt: Date(),
            timeRange: range,
            periodStart: period.start,
            periodEnd: period.end,
            totalSeconds: 0,
            categories: [],
            serverHostname: nil,
            errorMessage: SharedStore.lastError
        )
    }
}
