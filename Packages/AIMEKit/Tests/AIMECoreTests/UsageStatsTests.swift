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

    /// Older features.json files lack the punctuation default; it starts Chinese (#10).
    @Test func punctuationDefaultDecodesAndDefaultsToChinese() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(AIMEFeatures.self, from: Data(#"{"usageStats":true}"#.utf8)).asciiPunct == false)
        #expect(try decoder.decode(AIMEFeatures.self, from: Data(#"{"asciiPunct":true}"#.utf8)).asciiPunct == true)
        var features = AIMEFeatures()
        features.asciiPunct = true
        #expect(try decoder.decode(AIMEFeatures.self, from: JSONEncoder().encode(features)).asciiPunct == true)
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

    @Test func concurrentFlushesPreserveBothCounters() async throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let recorder = UsageRecorder(store: store)
        recorder.isEnabled = true
        let now = Date()
        let day = UsageStatsStore.dayKey(now)
        var writes: [Task<Void, Never>] = []
        // Enqueue all 64 without awaiting any, just as in the F07 reproducer.
        for _ in 0..<64 {
            recorder.record("智能体", app: "com.apple.TextEdit", now: now)
            writes.append(try #require(recorder.flush()))
        }
        for write in writes { await write.value }
        #expect(store.counts(day: day) == ["智能体": 64])
        let activity = store.activity(day: day)
        #expect(activity.commits == 64)
        #expect(activity.han == 192)
        #expect(activity.hours.reduce(0, +) == 192)
        #expect(activity.apps == ["com.apple.TextEdit": 192])
    }

    @Test func discardInvalidatesQueuedWritesInsideTheSequence() async {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let recorder = UsageRecorder(store: store)
        recorder.isEnabled = true
        let gate = StatsWriteGate()
        recorder.enqueueWrite { gate.block() }
        await gate.waitUntilBlocked()
        defer { gate.open() }
        let now = Date()
        let day = UsageStatsStore.dayKey(now)
        recorder.record("旧词", app: nil, now: now)
        let oldWrite = recorder.flush()
        recorder.discard()
        recorder.record("新词", app: nil, now: now)
        let newWrite = recorder.flush()
        gate.open()
        await oldWrite?.value
        await newWrite?.value
        #expect(store.counts(day: day) == ["新词": 1])
        #expect(store.activity(day: day).commits == 1)
    }

    @Test func clearOrdersInFlightAndQueuedWritesBeforeNewCounts() async {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let recorder = UsageRecorder(store: store)
        recorder.isEnabled = true
        let gate = StatsWriteGate()
        let store = store
        let now = Date()
        let day = UsageStatsStore.dayKey(now)
        var activity = DayActivity()
        activity.add(han: 2, words: 0, hour: 12, app: nil)
        let oldActivity = activity
        // Pause an in-flight mutation between the two real disk writes. Clear
        // must wait for it, even though it can no longer be invalidated.
        recorder.enqueueWrite {
            try? store.merge(["旧词": 1], into: day)
            gate.block()
            try? store.mergeActivity(oldActivity, into: day)
        }
        await gate.waitUntilBlocked()
        defer { gate.open() }
        for _ in 0..<64 {
            recorder.record("旧词", app: nil, now: now)
            recorder.flush()
        }
        recorder.record("未写", app: nil, now: now)
        let cleared = recorder.clear()
        #expect(recorder.pending.isEmpty && recorder.pendingActivity.isEmpty)
        // A late event carrying the old epoch must also be rejected, even when
        // it enters the queue after clear.
        recorder.enqueueWrite(generation: 0) {
            try? store.merge(["迟到": 1], into: day)
            try? store.mergeActivity(oldActivity, into: day)
        }
        recorder.record("新词", app: nil, now: now)
        let newWrite = recorder.flush()
        gate.open()
        await cleared.value
        await newWrite?.value
        #expect(store.counts(day: day) == ["新词": 1])
        #expect(store.activity(day: day).commits == 1)
        #expect(store.activity(day: day).han == 2)
    }

    @Test func flushAndClearReturnWhileBackgroundWriterIsBlocked() async throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let recorder = UsageRecorder(store: store)
        recorder.isEnabled = true
        let gate = StatsWriteGate()
        recorder.enqueueWrite { gate.block() }
        await gate.waitUntilBlocked()
        defer { gate.open() }
        recorder.record("智能体", app: nil)
        let clock = ContinuousClock()
        let start = clock.now
        let flushed = try #require(recorder.flush())
        let cleared = recorder.clear()
        #expect(start.duration(to: clock.now) < .seconds(1))
        #expect(recorder.pending.isEmpty && recorder.pendingActivity.isEmpty)
        gate.open()
        await flushed.value
        await cleared.value
        #expect(store.days().isEmpty)
        #expect(store.activityDays().isEmpty)
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

/// A bounded stand-in for slow disk I/O on the recorder's real write sequence.
private final class StatsWriteGate: Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func block() {
        #expect(!Thread.isMainThread)
        entered.signal()
        #expect(released.wait(timeout: .now() + 10) == .success)
    }

    func waitUntilBlocked() async {
        let started = await Task.detached { self.didEnter() }.value
        #expect(started)
    }

    private func didEnter() -> Bool { entered.wait(timeout: .now() + 10) == .success }

    func open() { released.signal() }
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
