import AIMECore
import AppKit
import SwiftUI

/// One-click import of an existing RIME setup (Squirrel, Weasel/fcitx backups…) with a
/// preview of what will happen. Read-only on the source; phrase tables are merged.
struct ImportSheet: View {
    @Environment(SettingsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var source = AIMEPaths.squirrelUserDir
    @State private var plan: [SquirrelImporter.Action] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.title2).foregroundStyle(Theme.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("导入 RIME 配置").font(.title3.weight(.semibold))
                    Text("方案、词库、自定义短语（全拼 / 双拼）、lua 扩展、配色与词频快照。只读取来源目录，不会修改它。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Text(source.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button("选择文件夹…") { choose() }
            }
            GroupBox {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if plan.isEmpty {
                            Text("该目录里没有可导入的 RIME 配置").foregroundStyle(.secondary)
                        }
                        ForEach(Array(plan.enumerated()), id: \.offset) { _, action in
                            row(action)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                .frame(minHeight: 220, maxHeight: 320)
            } label: {
                Text("导入计划").font(.headline)
            }
            Text("自定义短语表会与 AIME 里已有的词条合并（重复自动跳过）；你在 AIME 设置里改过的选项保持不变；被替换的文件备份到 aime/backup/。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("导入并部署") {
                    let chosen = source
                    dismiss()
                    Task { await model.importSquirrel(from: chosen) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isEmpty || model.deployState == .deploying)
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear { plan = model.importPlan(from: source) }
        .onChange(of: source) { plan = model.importPlan(from: source) }
    }

    @ViewBuilder
    private func row(_ action: SquirrelImporter.Action) -> some View {
        switch action {
        case let .copy(path):
            let isPhrase = path.hasPrefix("custom_phrase")
            Label(isPhrase ? "\(path) · 合并短语" : path, systemImage: isPhrase ? "text.quote" : "doc.on.doc")
                .font(.callout)
        case let .importCustom(path, target):
            Label("\(path) → 手写补丁层（\(target.customName)）", systemImage: "square.stack.3d.up")
                .font(.callout).foregroundStyle(Theme.accentText)
        case let .importSnapshots(path):
            Label("\(path)/ 词频快照 → 部署后合并", systemImage: "chart.bar.doc.horizontal").font(.callout)
        case let .skip(path, reason):
            Label("\(path) — 跳过：\(reason)", systemImage: "minus.circle")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = source
        panel.prompt = "选择"
        panel.message = "选择一个 RIME 用户目录（例如 ~/Library/Rime、小狼毫或 fcitx5 的配置备份）"
        if panel.runModal() == .OK, let url = panel.url { source = url }
    }
}
