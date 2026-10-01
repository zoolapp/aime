public import Foundation

/// How much was typed on one day: characters (汉字 + English words), commits, and how
/// they spread over the hours and apps. Counts only — never the text. Stored as
/// `Stats/Activity/<day>.json` next to the word counts and kept until the user clears
/// them (a year is a few hundred small files).
public struct DayActivity: Sendable, Codable, Equatable {
    /// Han characters committed.
    public var han = 0
    /// English words (runs of Latin letters) committed.
    public var words = 0
    /// Number of commits (picks from the candidate window).
    public var commits = 0
    /// Characters per hour of the day (0–23).
    public var hours = [Int](repeating: 0, count: 24)
    /// Characters per app bundle identifier.
    public var apps: [String: Int] = [:]

    public init() {}

    /// 字数: every Han character counts one, every English word counts one.
    public var characters: Int { han + words }
    public var isEmpty: Bool { commits == 0 }

    public static func count(_ text: String) -> (han: Int, words: Int) {
        var han = 0, words = 0, inWord = false
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) || (0x20000...0x2EBEF).contains(value) {
                han += 1
                inWord = false
            } else if (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) {
                if !inWord { words += 1 }
                inWord = true
            } else if !(inWord && (value == 0x27 || value == 0x2D || (0x30...0x39).contains(value))) {
                inWord = false // apostrophes, hyphens and digits inside a word keep it one word
            }
        }
        return (han, words)
    }

    mutating func add(han: Int, words: Int, hour: Int, app: String?) {
        self.han += han
        self.words += words
        commits += 1
        let characters = han + words
        if hours.count != 24 { hours = [Int](repeating: 0, count: 24) }
        if (0..<24).contains(hour) { hours[hour] += characters }
        // Bounded: one entry per app, and apps stay few.
        if let app, characters > 0, apps[app] != nil || apps.count < 200 { apps[app, default: 0] += characters }
    }

    mutating func add(_ other: DayActivity) {
        han += other.han
        words += other.words
        commits += other.commits
        if hours.count != 24 { hours = [Int](repeating: 0, count: 24) }
        for (index, value) in other.hours.prefix(24).enumerated() { hours[index] += value }
        for (app, value) in other.apps { apps[app, default: 0] += value }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        han = try container.decodeIfPresent(Int.self, forKey: .han) ?? 0
        words = try container.decodeIfPresent(Int.self, forKey: .words) ?? 0
        commits = try container.decodeIfPresent(Int.self, forKey: .commits) ?? 0
        let hours = try container.decodeIfPresent([Int].self, forKey: .hours) ?? []
        self.hours = hours.count == 24 ? hours : [Int](repeating: 0, count: 24)
        apps = try container.decodeIfPresent([String: Int].self, forKey: .apps) ?? [:]
    }
}

/// Everything the 输入统计 page shows, computed from the activity files.
public struct ActivityReport: Sendable, Equatable {
    public struct Day: Sendable, Equatable, Identifiable {
        public var date: Date
        public var characters: Int
        public var id: Date { date }
        public init(date: Date, characters: Int) {
            self.date = date
            self.characters = characters
        }
    }

    public struct App: Sendable, Equatable, Identifiable {
        public var bundleID: String
        public var characters: Int
        public var id: String { bundleID }
    }

    public var today = 0
    public var yesterday = 0
    public var week = 0
    public var month = 0
    public var lifetime = 0
    /// The last 371 days (53 full weeks) ending today, oldest first.
    public var days: [Day] = []
    /// Characters per hour over the last 30 days.
    public var hours = [Int](repeating: 0, count: 24)
    /// Apps by characters over the last 30 days, most first.
    public var apps: [App] = []
    /// Commits and characters over the last 30 days (average characters per pick).
    public var commits30 = 0
    public var characters30 = 0
    /// Share of Han characters in everything typed.
    public var hanShare = 0.0
    public var activeDays = 0
    /// Days in a row with typing, ending today (or yesterday, if nothing yet today).
    public var streak = 0
    public var longestStreak = 0
    public var peak: Day?
    public var firstDay: Date?

    public var averagePerActiveDay: Int { activeDays == 0 ? 0 : lifetime / activeDays }
    public var charactersPerCommit: Double { commits30 == 0 ? 0 : Double(characters30) / Double(commits30) }
    public var isEmpty: Bool { lifetime == 0 }
    public static let historyDays = 371
}

extension UsageStatsStore {
    var activityDirectory: URL { directory.appendingPathComponent("Activity", isDirectory: true) }
    func activityURL(_ day: String) -> URL { activityDirectory.appendingPathComponent("\(day).json") }

    public func activity(day: String) -> DayActivity {
        guard let data = try? Data(contentsOf: activityURL(day)) else { return DayActivity() }
        return (try? JSONDecoder().decode(DayActivity.self, from: data)) ?? DayActivity()
    }

    public func mergeActivity(_ delta: DayActivity, into day: String) throws {
        guard !delta.isEmpty else { return }
        try prepareDirectory()
        let fm = FileManager.default
        if !fm.fileExists(atPath: activityDirectory.path) {
            try fm.createDirectory(at: activityDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var current = activity(day: day)
        current.add(delta)
        try write(current, to: activityURL(day))
    }

    public func activityDays() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: activityDirectory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// Totals for today / this week (from Monday) / this month / all time, plus the
    /// series and breakdowns the charts use.
    public func report(now: Date = Date(), calendar base: Calendar = .current) -> ActivityReport {
        var calendar = base
        calendar.firstWeekday = 2
        var all: [String: DayActivity] = [:]
        for day in activityDays() { all[day] = activity(day: day) }
        var report = ActivityReport()
        guard !all.isEmpty else { return report }

        let today = calendar.startOfDay(for: now)
        let todayKey = Self.dayKey(today, calendar: calendar)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let monthStart = calendar.dateInterval(of: .month, for: today)?.start ?? today
        let recentStart = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        var han = 0
        var apps: [String: Int] = [:]
        for (key, activity) in all {
            report.lifetime += activity.characters
            han += activity.han
            guard activity.characters > 0, let date = Self.date(key, calendar: calendar) else { continue }
            report.activeDays += 1
            if report.firstDay.map({ date < $0 }) ?? true { report.firstDay = date }
            if report.peak.map({ activity.characters > $0.characters }) ?? true { report.peak = .init(date: date, characters: activity.characters) }
            if key == todayKey { report.today = activity.characters }
            if date >= weekStart, date <= today { report.week += activity.characters }
            if date >= monthStart, date <= today { report.month += activity.characters }
            if date >= recentStart, date <= today {
                report.commits30 += activity.commits
                report.characters30 += activity.characters
                for (index, value) in activity.hours.enumerated() where index < 24 { report.hours[index] += value }
                for (app, value) in activity.apps { apps[app, default: 0] += value }
            }
        }
        report.hanShare = report.lifetime == 0 ? 0 : Double(han) / Double(report.lifetime)
        report.apps = apps.map { ActivityReport.App(bundleID: $0.key, characters: $0.value) }
            .sorted { $0.characters != $1.characters ? $0.characters > $1.characters : $0.bundleID < $1.bundleID }

        for offset in stride(from: ActivityReport.historyDays - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            report.days.append(.init(date: date, characters: all[Self.dayKey(date, calendar: calendar)]?.characters ?? 0))
        }
        report.yesterday = report.days.dropLast().last?.characters ?? 0

        // Streaks over the whole history, walking day by day from the first active day.
        if let first = report.firstDay {
            var run = 0
            var date = first
            while date <= today {
                if (all[Self.dayKey(date, calendar: calendar)]?.characters ?? 0) > 0 {
                    run += 1
                    report.longestStreak = max(report.longestStreak, run)
                } else if date < today {
                    run = 0
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
                date = next
            }
            report.streak = run
        }
        return report
    }

    static func date(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
