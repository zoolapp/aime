import AIMECore
import AppKit
import Charts
import SwiftUI

/// 输入统计: how much, when and where you type, and your most frequent words. Local and
/// opt-in; the counts never leave the Mac.
struct UsageStatsView: View {
    @Environment(SettingsModel.self) private var model
    @State private var trend: Trend = .days
    @State private var wordRange: WordRange = .week
    @State private var confirmClear = false
    @State private var notice: String?

    enum Trend: String, CaseIterable, Identifiable {
        case days, weeks, months
        var id: String { rawValue }
        var title: String {
            switch self {
            case .days: "按日"
            case .weeks: "按周"
            case .months: "按月"
            }
        }
    }

    enum WordRange: Int, CaseIterable, Identifiable {
        case today = 1, week = 7, month = 30
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .today: "今日"
            case .week: "近 7 天"
            case .month: "近 30 天"
            }
        }
    }

    var body: some View {
        let enabled = model.features.usageStats
        let report = model.activityReport()
        ScrollViewReader { proxy in
        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    PaneHeader(title: "输入统计", subtitle: "每天打了多少字、在哪里打、什么时候打，以及最常用的词。", symbol: "chart.bar.xaxis")
                    PrivacyBadge()
                }
                .containerValue(\.isPlain, true)
            }

            if !enabled {
                Section { EnableCard { model.setUsageStats(true) } }
            } else if report.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("还没有数据", systemImage: "chart.bar")
                    } description: {
                        Text("打一会儿字再回来看看。统计每 5 分钟写入一次，离开输入框时也会写入。")
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            if !report.isEmpty {
                Section { Totals(report: report) }
                    .containerValue(\.isPlain, true)

                Section {
                    TrendChart(points: points(report), unit: trend)
                        .frame(height: 170)
                        .padding(.vertical, 4)
                } header: {
                    HStack {
                        Text("趋势")
                        Spacer()
                        Picker("", selection: $trend) { ForEach(Trend.allCases) { Text($0.title).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                    }
                }

                Section("打字日历") { Heatmap(days: report.days) }

                Section("习惯") {
                    HStack(alignment: .top, spacing: 24) {
                        HourChart(hours: report.hours).frame(maxWidth: .infinity)
                        Facts(report: report).frame(width: 230)
                    }
                    .padding(.vertical, 4)
                    .id("habits")
                }

                if !report.apps.isEmpty {
                    Section("近 30 天在哪里打字") { AppList(apps: Array(report.apps.prefix(6)), total: report.characters30) }
                }
            }

            if enabled || !model.statsStore.days().isEmpty { wordsSection }

            Section {
                Toggle(isOn: Binding(get: { enabled }, set: { model.setUsageStats($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("记录输入统计")
                        Text("只保存数字：每天的字数、各时段与各应用的字数，以及 2–8 字中文词的次数；不保存句子与上下文，密码管理器中的输入不计。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("高频词保留 92 天；字数统计保留到你清空为止。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("清空统计…", role: .destructive) { confirmClear = true }
                        .disabled(report.isEmpty && model.statsStore.days().isEmpty)
                }
            } header: {
                Text("记录与隐私")
            }
        }
        .formStyle(.cards)
        .onAppear {
            model.refreshStats()
            // Screenshot automation: `--scroll-to habits|words`.
            if let target = LaunchOptions.argument("--scroll-to") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo(target, anchor: .top) }
            }
        }
        }
        .confirmationDialog("清空所有输入统计？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { model.clearUsageStats(); notice = nil }
        } message: {
            Text("删除本机保存的全部字数与高频词记录，无法恢复。屏蔽列表会保留。")
        }
    }

    @ViewBuilder private var wordsSection: some View {
        let summary = model.usageSummary(days: wordRange.rawValue)
        Section {
            if summary.words.isEmpty {
                Text("这段时间还没有统计到词。").font(.callout).foregroundStyle(.secondary)
            } else {
                let top = Array(summary.words.prefix(20))
                let maxCount = top.first?.count ?? 1
                ForEach(Array(top.enumerated()), id: \.element.id) { index, word in
                    WordRow(rank: index + 1, word: word, fraction: Double(word.count) / Double(maxCount),
                            pinned: model.isPinned(word.text)) {
                        if let code = model.pinUsageWord(word.text) { notice = "已置顶「\(word.text)」，编码 \(code)，正在自动应用" }
                    } block: {
                        model.blockUsageWord(word.text)
                    }
                }
            }
        } header: {
            HStack {
                Text("高频词")
                if let notice { Text(notice).font(.caption).foregroundStyle(Theme.accentText) }
                Spacer()
                Picker("", selection: $wordRange) { ForEach(WordRange.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            }
            .id("words")
        } footer: {
            Text("点图钉把词置顶为候选第一位（写入自定义短语表「\(model.phraseTable.name)」）。").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Bars for the chosen granularity: 30 days, 12 weeks or 12 months.
    private func points(_ report: ActivityReport) -> [ActivityReport.Day] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        switch trend {
        case .days:
            return Array(report.days.suffix(30))
        case .weeks, .months:
            let component: Calendar.Component = trend == .weeks ? .weekOfYear : .month
            var buckets: [Date: Int] = [:]
            for day in report.days {
                guard let start = calendar.dateInterval(of: component, for: day.date)?.start else { continue }
                buckets[start, default: 0] += day.characters
            }
            return buckets.map { ActivityReport.Day(date: $0.key, characters: $0.value) }
                .sorted { $0.date < $1.date }.suffix(12)
        }
    }
}

// MARK: - Pieces

/// "仅本机" chip; the popover explains what is kept and where.
private struct PrivacyBadge: View {
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Label("仅本机", systemImage: "lock.shield")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.success.opacity(0.12), in: Capsule())
                .foregroundStyle(Theme.success)
        }
        .buttonStyle(.plain)
        .help("统计数据只保存在这台 Mac 上")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Label("统计只在本机进行", systemImage: "exclamationmark.shield").font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    bullet("数据保存在 ~/Library/Application Support/AIME/Stats，只有你的账户能读写，不进 Time Machine 备份。")
                    bullet("不上传、不联网、不写日志，也不会交给 AI 助手。")
                    bullet("只记录数字（字数、时段、应用、词的次数），不记录你打的句子。")
                    bullet("随时可以关闭，或在本页底部一键清空。")
                }
                .font(.callout)
            }
            .padding(16)
            .frame(width: 340)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct EnableCard: View {
    let enable: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.accentText)
                .frame(width: 44, height: 44)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("看看自己的打字习惯").font(.body.weight(.semibold))
                Text("开启后，AIME 在本机统计每天的字数、常用的应用与时段，以及你的高频词。默认关闭。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("开启统计", action: enable).buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }
}

/// Four headline numbers.
private struct Totals: View {
    let report: ActivityReport

    var body: some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12),
                       GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        LazyVGrid(columns: columns, spacing: 12) {
            Tile(title: "今天", value: report.today, note: delta)
            Tile(title: "本周", value: report.week, note: "周一起算")
            Tile(title: "本月", value: report.month, note: "\(Calendar.current.component(.month, from: Date())) 月")
            Tile(title: "累计", value: report.lifetime, note: essays)
        }
    }

    private var delta: String {
        guard report.yesterday > 0 else { return report.today > 0 ? "昨天没有记录" : "今天还没开始" }
        let change = Double(report.today - report.yesterday) / Double(report.yesterday)
        return change >= 0 ? "比昨天多 \(Int((change * 100).rounded()))%" : "比昨天少 \(Int((-change * 100).rounded()))%"
    }

    private var essays: String {
        let count = report.lifetime / 800
        return count >= 1 ? "≈ \(count.formatted()) 篇 800 字作文" : "从 \(report.firstDay?.formatted(.dateTime.month().day()) ?? "今天") 开始"
    }

    private struct Tile: View {
        let title: String
        let value: Int
        let note: String

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value.formatted()).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .contentTransition(.numericText())
                    Text("字").font(.caption).foregroundStyle(.secondary)
                }
                Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.cardBorder))
        }
    }
}

private struct TrendChart: View {
    let points: [ActivityReport.Day]
    let unit: UsageStatsView.Trend

    var body: some View {
        let active = points.filter { $0.characters > 0 }
        let average = active.isEmpty ? 0 : active.reduce(0) { $0 + $1.characters } / active.count
        Chart {
            ForEach(points) { point in
                BarMark(x: .value("时间", point.date, unit: component), y: .value("字数", point.characters))
                    .foregroundStyle(Theme.accent.gradient)
                    .cornerRadius(3)
            }
            if average > 0 {
                RuleMark(y: .value("平均", average))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("平均 \(average.formatted())").font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartXAxis {
            switch unit {
            case .days:
                AxisMarks(values: .stride(by: .day, count: 5)) { AxisValueLabel(format: .dateTime.month(.defaultDigits).day()) }
            case .weeks:
                AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { AxisValueLabel(format: .dateTime.month(.defaultDigits).day()) }
            case .months:
                AxisMarks(values: .stride(by: .month)) { AxisValueLabel(format: .dateTime.month(.defaultDigits)) }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) { AxisGridLine(); AxisValueLabel() } }
        .animation(.snappy, value: points)
    }

    private var component: Calendar.Component {
        switch unit {
        case .days: .day
        case .weeks: .weekOfYear
        case .months: .month
        }
    }
}

/// GitHub-style calendar: 53 weeks × 7 days, darker for busier days.
private struct Heatmap: View {
    let days: [ActivityReport.Day]
    private let cell: CGFloat = 10
    private let gap: CGFloat = 3

    var body: some View {
        let levels = thresholds
        let columns = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(columns.indices, id: \.self) { index in
                        VStack(spacing: gap) {
                            ForEach(columns[index]) { day in
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(color(level(day.characters, levels)))
                                    .frame(width: cell, height: cell)
                                    .help("\(day.date.formatted(.dateTime.year().month().day()))：\(day.characters.formatted()) 字")
                            }
                        }
                    }
                }
            }
            .defaultScrollAnchor(.trailing)
            HStack(spacing: 4) {
                Text("近一年").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("少").font(.caption2).foregroundStyle(.secondary)
                ForEach(0..<5) { RoundedRectangle(cornerRadius: 2.5).fill(color($0)).frame(width: cell, height: cell) }
                Text("多").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Quartiles of the active days, so a light typist's calendar is not all pale.
    private var thresholds: [Int] {
        let values = days.map(\.characters).filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return [1, 1, 1] }
        return [0.25, 0.5, 0.75].map { values[min(values.count - 1, Int(Double(values.count) * $0))] }
    }

    private func level(_ value: Int, _ levels: [Int]) -> Int {
        guard value > 0 else { return 0 }
        return 1 + levels.filter { value > $0 }.count
    }

    private func color(_ level: Int) -> Color {
        level == 0 ? Color.primary.opacity(0.07) : Theme.accent.opacity([0, 0.3, 0.52, 0.76, 1][level])
    }
}

private struct HourChart: View {
    let hours: [Int]

    var body: some View {
        let peak = hours.indices.max { hours[$0] < hours[$1] } ?? 0
        VStack(alignment: .leading, spacing: 8) {
            Text(hours[peak] > 0 ? "最常在 \(peak) 点前后打字" : "时段分布").font(.callout.weight(.medium))
            Chart {
                ForEach(0..<24, id: \.self) { hour in
                    BarMark(x: .value("时", hour), y: .value("字数", hours[hour]))
                        .foregroundStyle(hour == peak ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(Theme.accent.opacity(0.35)))
                        .cornerRadius(2)
                }
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) { AxisValueLabel() } }
            .chartYAxis(.hidden)
            .frame(height: 120)
            Text("近 30 天，按小时").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct Facts: View {
    let report: ActivityReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            fact("flame", "连续打字", "\(report.streak) 天", "最长 \(report.longestStreak) 天")
            fact("calendar", "日均", "\(report.averagePerActiveDay.formatted()) 字", "共 \(report.activeDays) 个活跃日")
            if let peak = report.peak {
                fact("trophy", "最多的一天", "\(peak.characters.formatted()) 字", peak.date.formatted(.dateTime.year().month().day()))
            }
            fact("text.cursor", "每次上屏", String(format: "%.1f 字", report.charactersPerCommit), "近 30 天平均")
            fact("character", "中文占比", "\(Int((report.hanShare * 100).rounded()))%", "其余为英文单词")
        }
    }

    private func fact(_ symbol: String, _ title: String, _ value: String, _ note: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accentText)
                .frame(width: 26, height: 26)
                .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(note).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
    }
}

private struct AppList: View {
    let apps: [ActivityReport.App]
    let total: Int

    var body: some View {
        let maxValue = apps.first?.characters ?? 1
        VStack(spacing: 10) {
            ForEach(apps) { app in
                let info = AppInfo.lookup(app.bundleID)
                HStack(spacing: 10) {
                    Image(nsImage: info.icon).resizable().frame(width: 22, height: 22)
                    Text(info.name).lineLimit(1).frame(width: 140, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule().fill(Theme.accent.opacity(0.18)).frame(height: 6)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Theme.accent).frame(width: max(6, proxy.size.width * Double(app.characters) / Double(maxValue)), height: 6)
                            }
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 16)
                    Text("\(app.characters.formatted()) 字").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .trailing)
                    Text(total > 0 ? "\(Int((Double(app.characters) / Double(total) * 100).rounded()))%" : "")
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// App name and icon for a bundle identifier, looked up once.
@MainActor
enum AppInfo {
    private static var cache: [String: (name: String, icon: NSImage)] = [:]

    static func lookup(_ bundleID: String) -> (name: String, icon: NSImage) {
        if let cached = cache[bundleID] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleID.components(separatedBy: ".").last ?? bundleID
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        cache[bundleID] = (name, icon)
        return (name, icon)
    }
}

private struct WordRow: View {
    let rank: Int
    let word: UsageSummary.Word
    let fraction: Double
    let pinned: Bool
    let pin: () -> Void
    let block: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
            Text(word.text).font(.body.weight(rank <= 3 ? .semibold : .regular)).frame(width: 120, alignment: .leading)
            GeometryReader { proxy in
                Capsule().fill(Theme.accent.opacity(0.75))
                    .frame(width: max(4, proxy.size.width * fraction), height: 6)
                    .frame(maxHeight: .infinity)
            }
            .frame(height: 16)
            Text("\(word.count) 次").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
            if pinned {
                Label("已置顶", systemImage: "pin.fill").labelStyle(.iconOnly).foregroundStyle(Theme.accentText)
                    .help("已在自定义短语中")
                    .frame(width: 24)
            } else {
                Button(action: pin) { Image(systemName: "pin") }
                    .buttonStyle(.borderless).help("置顶为候选第一位")
                    .frame(width: 24)
            }
            Button(action: block) { Image(systemName: "eye.slash") }
                .buttonStyle(.borderless).help("不再统计这个词")
        }
    }
}
