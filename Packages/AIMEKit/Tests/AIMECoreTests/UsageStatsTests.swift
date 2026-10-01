import Foundation
import Testing
@testable import AIMECore

@MainActor
struct UsageStatsTests {
    let store: UsageStatsStore

    init() {
        store = UsageStatsStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("aime-stats-\(UUID().uuidString)"))
    }

    @Test func countsOnlyShortChineseWords() {
        #expect(UsageStatsStore.isCountable("智能体"))
        #expect(!UsageStatsStore.isCountable("我"))
        #expect(!UsageStatsStore.isCountable("hello"))
        #expect(!UsageStatsStore.isCountable("你好，"))
        #expect(!UsageStatsStore.isCountable("一二三四五六七八九"))
    }

    @Test func recorderIsOffByDefaultAndSkipsPasswordManagers() {
        let recorder = UsageRecorder(store: store)
        recorder.record("智能体", app: "com.apple.TextEdit")
        #expect(recorder.pending.isEmpty)
        recorder.isEnabled = true
        recorder.record("智能体", app: "com.1password.1password")
        recorder.record("智能体", app: "com.apple.TextEdit")
        recorder.record("智能体", app: nil)
        #expect(recorder.pending == ["智能体": 2])
    }

    @Test func flushMergesIntoTodayAndSummarizes() async throws {
        let recorder = UsageRecorder(store: store)
        recorder.isEnabled = true
        for _ in 0..<3 { recorder.record("智能体", app: nil) }
        recorder.record("提示词", app: nil)
        await recorder.flush()?.value
        recorder.record("智能体", app: nil)
        await recorder.flush()?.value
        let summary = store.summary(days: 7)
        #expect(summary.words.first == .init(text: "智能体", count: 4))
        #expect(summary.total == 5 && summary.daily.count == 7)

        try store.block("智能体")
        #expect(store.summary(days: 1).words.map(\.text) == ["提示词"])
        recorder.record("智能体", app: nil)
        await recorder.flush()?.value
        #expect(store.summary(days: 1).words.map(\.text) == ["提示词"])

        store.clear()
        #expect(store.summary(days: 30).total == 0)
    }

    @Test func discardedBufferIsNeverWritten() async {
        let recorder = UsageRecorder(store: store)
        recorder.isEnabled = true
        recorder.record("智能体", app: nil)
        let task = recorder.flush()
        recorder.discard()
        await task?.value
        #expect(store.summary(days: 1).total == 0)
    }

    @Test func prunesOldDays() throws {
        let old = Calendar.current.date(byAdding: .day, value: -100, to: Date())!
        try store.merge(["旧词": 1], into: UsageStatsStore.dayKey(old))
        try store.merge(["新词": 1], into: UsageStatsStore.dayKey(Date()))
        store.prune()
        #expect(store.days() == [UsageStatsStore.dayKey(Date())])
    }

    @Test func filesArePrivate() throws {
        try store.merge(["智能体": 1], into: "2026-09-29")
        let dir = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        let file = try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent("2026-09-29.json").path)
        #expect((dir[.posixPermissions] as? Int) == 0o700)
        #expect((file[.posixPermissions] as? Int) == 0o600)
    }

    /// Recording runs on the key path; it must stay in the microsecond range.
    @Test func recordingIsCheap() {
        let recorder = UsageRecorder(store: store)
        recorder.isEnabled = true
        let words = ["智能体", "提示词", "你好", "世界", "氛围编程"]
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for index in 0..<20_000 { recorder.record(words[index % words.count], app: "com.apple.TextEdit") }
        }
        #expect(elapsed < .milliseconds(200)) // < 10 µs per commit, even in debug builds
        #expect(recorder.pending["智能体"] == 4000)
    }
}

extension UsageStatsTests {
    @Test func countsHanCharactersAndEnglishWords() {
        #expect(DayActivity.count("你好世界") == (4, 0))
        #expect(DayActivity.count("用 Claude Code 写代码") == (4, 2))
        #expect(DayActivity.count("don't re-run GPT-5，") == (0, 3))
        #expect(DayActivity.count("，。！123") == (0, 0))
    }

    @Test func activityIsRecordedForEveryCommitAndReported() async throws {
        let recorder = UsageRecorder(store: store)
        recorder.isEnabled = true
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 21))! // a Wednesday
        recorder.record("今天天气不错", app: "com.tencent.xinWeChat", now: now)   // not a countable word, still typed
        recorder.record("Agent", app: "com.apple.Safari", now: now)
        recorder.record("，", app: "com.apple.Safari", now: now)                 // punctuation is not typing
        recorder.record("密码", app: "com.1password.1password", now: now)
        #expect(recorder.pendingActivity.characters == 7 && recorder.pendingActivity.commits == 2)
        await recorder.flush()?.value

        // Earlier days: Monday of this week, last month, and a gap that breaks the streak.
        for (offset, text) in [(-1, "昨天"), (-2, "前天"), (-5, "上周五的字"), (-40, "很久以前")] {
            recorder.record(text, app: "com.apple.TextEdit", now: calendar.date(byAdding: .day, value: offset, to: now)!)
            await recorder.flush()?.value
        }
        let report = store.report(now: now, calendar: calendar)
        #expect(report.today == 7 && report.yesterday == 2)
        #expect(report.week == 7 + 2 + 2)                  // Mon–Wed
        #expect(report.month == 7 + 2 + 2 + 5)             // Oct 1–7
        #expect(report.lifetime == 7 + 2 + 2 + 5 + 4)
        #expect(report.streak == 3 && report.longestStreak == 3 && report.activeDays == 5)
        #expect(report.hours[21] == 7 + 2 + 2 + 5)         // everything in the last 30 days was typed at 21:00
        #expect(report.apps.map(\.bundleID) == ["com.apple.TextEdit", "com.tencent.xinWeChat", "com.apple.Safari"])
        #expect(!report.apps.contains { $0.bundleID == "com.1password.1password" })
        #expect(report.peak?.characters == 7 && report.days.count == ActivityReport.historyDays)

        store.clear()
        #expect(store.report(now: now, calendar: calendar).isEmpty)
    }
}
