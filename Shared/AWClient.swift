import Foundation

/// ActivityWatch local REST client (aw-server at localhost:5600).
struct AWClient: Sendable {
    var baseURL: URL
    var session: URLSession

    init(host: String = "127.0.0.1", port: Int = 5600, session: URLSession = .shared) {
        self.baseURL = URL(string: "http://\(host):\(port)/api/0")!
        self.session = session
    }

    // MARK: - Public API

    func fetchServerInfo() async throws -> ServerInfo {
        try await get("/info")
    }

    func fetchSettings() async throws -> AWUserSettings {
        let settings: [String: AnyCodableJSON] = try await get("/settings")
        return try AWUserSettings(from: settings)
    }

    func fetchCategoryClasses() async throws -> [AWCategoryClass] {
        try await fetchSettings().classes
    }

    /// Query screentime per category for a time range (AFK-filtered, window events).
    /// Also returns day-boundary settings from the same `/settings` fetch.
    func fetchCategoryDurations(
        timeRange: TimeRange,
        hostname: String? = nil,
        now: Date = Date()
    ) async throws -> (snapshot: CategorySnapshot, daySettings: DaySettings) {
        let info = try await fetchServerInfo()
        let host = hostname ?? info.hostname
        let userSettings = try await fetchSettings()
        let classes = userSettings.classes
        let boundaries = userSettings.daySettings
        let colorByPath: [String: String] = Dictionary(
            uniqueKeysWithValues: classes.compactMap { c in
                guard let hex = c.colorHex else { return nil }
                return (c.name.joined(separator: "/"), hex)
            }
        )

        let period = timeRange.period(now: now, daySettings: boundaries)
        let isoStart = Self.iso8601.string(from: period.start)
        let isoEnd = Self.iso8601.string(from: period.end)
        let timeperiod = "\(isoStart)/\(isoEnd)"

        // categorize() expects list of (name, rule) tuples embedded as Query2 source
        // (not a JSON string value). Only regex fields need the webui-style
        // backslash un-escape so `\w` etc. reach the engine as intended.
        let categoriesLiteral = Self.categoriesQueryLiteral(classes)

        let windowBucket = "aw-watcher-window_\(host)"
        let afkBucket = "aw-watcher-afk_\(host)"

        let queryLines = [
            "events = flood(query_bucket(find_bucket(\"\(windowBucket)\")));",
            "not_afk = flood(query_bucket(find_bucket(\"\(afkBucket)\")));",
            "not_afk = filter_keyvals(not_afk, \"status\", [\"not-afk\"]);",
            "events = filter_period_intersect(events, not_afk);",
            "events = categorize(events, \(categoriesLiteral));",
            "cat_events = merge_events_by_keys(events, [\"$category\"]);",
            "cat_events = sort_by_duration(cat_events);",
            "RETURN = cat_events;",
        ]

        let body: [String: AnyCodableJSON] = [
            "timeperiods": .array([.string(timeperiod)]),
            "query": .array(queryLines.map { .string($0) }),
        ]

        let results: [AnyCodableJSON] = try await post("/query/", body: body)
        guard let first = results.first else {
            let empty = CategorySnapshot(
                fetchedAt: Date(),
                timeRange: timeRange,
                periodStart: period.start,
                periodEnd: period.end,
                totalSeconds: 0,
                categories: [],
                serverHostname: host,
                errorMessage: nil
            )
            return (empty, boundaries)
        }

        let events = try Self.decodeQueryEvents(first)
        let categories: [CategoryDuration] = events.compactMap { event in
            guard let path = event.categoryPath else { return nil }
            let key = path.joined(separator: "/")
            let inherited = Self.inheritedColor(path: path, map: colorByPath)
            return CategoryDuration(
                path: path,
                seconds: event.durationSeconds,
                colorHex: inherited
            )
        }

        let total = categories.reduce(0.0) { $0 + $1.seconds }
        let snap = CategorySnapshot(
            fetchedAt: Date(),
            timeRange: timeRange,
            periodStart: period.start,
            periodEnd: period.end,
            totalSeconds: total,
            categories: categories,
            serverHostname: host,
            errorMessage: nil
        )
        return (snap, boundaries)
    }

    // MARK: - Networking

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        // /settings is not under a path component join cleanly when path has leading slash
        let resolved = baseURL.absoluteString + path
        let requestURL = URL(string: resolved) ?? url
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        try Self.throwIfNeeded(response: response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, body: [String: AnyCodableJSON]) async throws -> T {
        let resolved = baseURL.absoluteString + path
        guard let requestURL = URL(string: resolved) else {
            throw AWClientError.invalidURL
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try Self.throwIfNeeded(response: response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func throwIfNeeded(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AWClientError.http(http.statusCode, message)
        }
    }

    /// Build `[[name, rule], …]` as a Query2 literal for embedding in query source.
    ///
    /// Names and non-regex rule fields use normal JSON encoding. Regex strings
    /// are JSON-encoded then have `\\` → `\` applied **only on that field**,
    /// matching aw-webui’s `JSON.stringify(...).replace(/\\\\/g, '\\')` intent
    /// without mangling backslashes that appear in category names.
    private static func categoriesQueryLiteral(_ classes: [AWCategoryClass]) -> String {
        let items = classes.map { c -> String in
            let nameJSON = jsonEncoded(c.name) ?? "[]"
            let ruleJSON = ruleQueryLiteral(c.rule)
            return "[\(nameJSON), \(ruleJSON)]"
        }
        return "[\(items.joined(separator: ", "))]"
    }

    private static func ruleQueryLiteral(_ rule: AWRule) -> String {
        var parts: [String] = ["\"type\": \(jsonEncoded(rule.type) ?? "\"none\"")"]
        if let regex = rule.regex {
            // Field-scoped unescape: only the regex string value, not the whole array.
            let encoded = jsonEncoded(regex) ?? "\"\""
            let forQuery = encoded.replacingOccurrences(of: "\\\\", with: "\\")
            parts.append("\"regex\": \(forQuery)")
        }
        if let ignore = rule.ignore_case {
            parts.append("\"ignore_case\": \(ignore ? "true" : "false")")
        }
        return "{\(parts.joined(separator: ", "))}"
    }

    private static func jsonEncoded<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func inheritedColor(path: [String], map: [String: String]) -> String? {
        // Prefer most specific path color, then walk up to root.
        var parts = path
        while !parts.isEmpty {
            let key = parts.joined(separator: "/")
            if let hex = map[key] { return hex }
            parts.removeLast()
        }
        return nil
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func decodeQueryEvents(_ value: AnyCodableJSON) throws -> [QueryEvent] {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode([QueryEvent].self, from: data)
    }
}

// MARK: - Response models

struct ServerInfo: Codable, Sendable {
    let hostname: String
    let version: String
    let testing: Bool?
}

/// Subset of AW `/settings` used by the widget (categories + day boundaries).
struct AWUserSettings: Sendable {
    let classes: [AWCategoryClass]
    let daySettings: DaySettings

    init(from settings: [String: AnyCodableJSON]) throws {
        if let classesValue = settings["classes"] {
            let data = try JSONEncoder().encode(classesValue)
            classes = try JSONDecoder().decode([AWCategoryClass].self, from: data)
        } else {
            classes = []
        }

        let startOfDay: String
        if case .string(let s) = settings["startOfDay"] {
            startOfDay = s
        } else {
            startOfDay = DaySettings.awDefaults.startOfDay
        }

        let startOfWeek: String
        if case .string(let s) = settings["startOfWeek"] {
            startOfWeek = s
        } else {
            startOfWeek = DaySettings.awDefaults.startOfWeek
        }

        daySettings = DaySettings(startOfDay: startOfDay, startOfWeek: startOfWeek)
    }
}

struct QueryEvent: Codable, Sendable {
    let duration: DurationValue
    let data: QueryEventData
    let timestamp: String?

    var durationSeconds: Double { duration.seconds }
    var categoryPath: [String]? { data.category }
}

struct QueryEventData: Codable, Sendable {
    let category: [String]?

    enum CodingKeys: String, CodingKey {
        case category = "$category"
    }
}

enum DurationValue: Codable, Sendable {
    case seconds(Double)

    var seconds: Double {
        switch self {
        case .seconds(let s): return s
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            self = .seconds(d)
        } else if let i = try? c.decode(Int.self) {
            self = .seconds(Double(i))
        } else if let s = try? c.decode(String.self), let d = Double(s) {
            self = .seconds(d)
        } else {
            self = .seconds(0)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(seconds)
    }
}

enum AWClientError: LocalizedError {
    case invalidURL
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid ActivityWatch URL"
        case .http(let code, let body): return "ActivityWatch HTTP \(code): \(body)"
        case .decoding(let msg): return "Decode error: \(msg)"
        }
    }
}

// MARK: - Lightweight JSON type

enum AnyCodableJSON: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyCodableJSON])
    case array([AnyCodableJSON])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .number(Double(i))
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let o = try? c.decode([String: AnyCodableJSON].self) {
            self = .object(o)
        } else if let a = try? c.decode([AnyCodableJSON].self) {
            self = .array(a)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> AnyCodableJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}
