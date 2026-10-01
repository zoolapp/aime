import AIMECore
import AppKit
import SwiftUI

/// Raw YAML editing of the hand-written (imported) layers, validated by a dry-run deploy.
struct AdvancedView: View {
    @Environment(SettingsModel.self) private var model
    @State private var target = "default"
    @State private var text = ""
    @State private var loadedText = ""
    @State private var validation: String?
    @State private var validating = false

    private var targets: [(id: String, title: String)] {
        [("default", "default · 全局")] + model.enabledSchemas.map { ($0, "\($0) · 方案") } + [("aime", "aime · 外观与应用")]
    }

    private var configTarget: ConfigTarget { ConfigTarget(customName: target) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "高级", subtitle: "直接编辑手写补丁层（aime/imported/*.custom.yaml），语法与 RIME 的 custom.yaml 相同。", symbol: "wrench.and.screwdriver")
            HStack {
                Picker("配置", selection: $target) {
                    ForEach(targets, id: \.id) { Text($0.title).tag($0.id) }
                }
                .frame(width: 280)
                Spacer()
                Button { NSWorkspace.shared.open(model.paths.userDataDir) } label: { Label("打开用户目录", systemImage: "folder") }
                Button { NSWorkspace.shared.open(model.paths.logDir) } label: { Label("日志", systemImage: "doc.text.magnifyingglass") }
                RerunOnboardingButton()
            }
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
            HStack(alignment: .top) {
                if let validation {
                    Text(validation).font(.caption.monospaced()).foregroundStyle(validation.hasPrefix("✓") ? .green : .orange)
                        .textSelection(.enabled).lineLimit(4)
                }
                Spacer()
                Button("还原") { text = loadedText }.disabled(text == loadedText)
                Button {
                    Task { await save() }
                } label: {
                    validating ? AnyView(ProgressView().controlSize(.small)) : AnyView(Text("校验并保存"))
                }
                .buttonStyle(.borderedProminent)
                .disabled(text == loadedText || validating)
            }
        }
        .paneColumn()
        .onAppear(perform: load)
        .onChange(of: target) { load() }
    }

    private func load() {
        let url = model.store.layers.importedURL(configTarget)
        loadedText = (try? String(contentsOf: url, encoding: .utf8)) ?? "# \(target).custom.yaml\npatch:\n"
        text = loadedText
        validation = nil
    }

    private func save() async {
        do {
            _ = try ConfigValue.parse(yaml: text)
        } catch {
            validation = "YAML 语法错误：\(error)"
            return
        }
        validating = true
        // Nothing reaches the input method until the dry run has passed.
        model.pauseAutoDeploy()
        defer {
            validating = false
            model.resumeAutoDeploy()
        }
        let backup = loadedText
        let existed = FileManager.default.fileExists(atPath: model.store.layers.importedURL(configTarget).path)
        model.perform { try model.store.layers.writeImported(configTarget, yaml: text) }
        let result = await model.deployer.dryRun()
        if result.ok {
            loadedText = text
            validation = "✓ 校验通过，正在自动应用"
        } else {
            // Roll back so a broken patch never reaches the input method. A layer that did
            // not exist before is removed rather than replaced by the editor placeholder.
            model.perform {
                if existed {
                    try model.store.layers.writeImported(configTarget, yaml: backup)
                } else {
                    try FileManager.default.removeItem(at: model.store.layers.importedURL(configTarget))
                    try model.store.layers.installShim(configTarget)
                }
            }
            validation = "部署校验失败，已回滚：\n" + DeployService.summarize(result.output)
        }
    }
}
