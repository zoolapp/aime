import AIMECore
import AppKit
import SwiftUI

/// Click, then press a key combination; stored in Rime notation. No typing of key names.
struct KeyRecorder: NSViewRepresentable {
    let value: String
    var placeholder: String?
    let commit: (String) -> Void
    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.idleTitle = value.isEmpty ? (placeholder ?? "未设置") : HotkeyFormatter.display(value)
        button.commit = commit
        button.isEnabled = context.environment.isEnabled
        if !button.isEnabled { button.stop() }
        button.refreshTitle()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecorderButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.stop() }
}

/// A dedicated responder keeps recording events out of the active input method.
@MainActor final class RecorderButton: NSButton {
    var idleTitle = "未设置"
    var commit: (String) -> Void = { _ in }
    private var recording = HotkeyRecording()
    private var monitor: Any?
    private var observers: [any NSObjectProtocol] = []
    private var deadline: Task<Void, Never>?
    private var generation: UInt64 = 0
    override var acceptsFirstResponder: Bool { true }
    override var inputContext: NSTextInputContext? { nil }
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: max(96, size.width), height: max(28, size.height))
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        target = self
        action = #selector(toggleRecording)
        toolTip = "点击后按下组合键，全部松开后保存；Esc 取消。单独长按修饰键请在「快捷键 → 快捷菜单」设置。"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggleRecording() {
        if recording.active { stop(); return }
        guard let window, window.makeFirstResponder(self) else { NSSound.beep(); return }
        stop()
        recording.start(modifiers: Self.modifiers(NSEvent.modifierFlags))
        refreshTitle()
        let token = generation
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self, weak window] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.generation == token, self.recording.active,
                      let window, window.isKeyWindow, event.window == nil || event.window === window else { return false }
                let kind: HotkeyRecording.Event = event.type == .keyDown ? .down : (event.type == .keyUp ? .up : .modifiers)
                let result = self.recording.handle(kind, keyCode: event.keyCode,
                                                  character: event.type == .keyDown ? event.charactersIgnoringModifiers : nil,
                                                  modifiers: Self.modifiers(event.modifierFlags), repeatKey: event.type == .keyDown && event.isARepeat)
                switch result {
                case let .commit(name): self.stop(); self.commit(name)
                case .cancel: self.stop()
                case .unsupported: NSSound.beep(); self.refreshTitle()
                case .waiting, .retry: self.refreshTitle()
                }
                return true
            }
            return consumed ? nil : event
        }
        for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject),
                               (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.generation == token { self?.stop() } }
            })
        }
        deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, self?.generation == token else { return }
            self?.stop()
        }
    }

    func stop() {
        generation &+= 1
        recording.stop()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        deadline?.cancel()
        deadline = nil
        refreshTitle()
    }
    override func resignFirstResponder() -> Bool { stop(); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { stop() }; super.viewWillMove(toWindow: newWindow) }
    func refreshTitle() {
        title = recording.active ? (recording.waitingForRelease ? "请松开按键…" : "请按组合键…") : idleTitle
        contentTintColor = recording.active ? .controlAccentColor : nil
        invalidateIntrinsicContentSize()
    }
    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> HotkeyFormatter.Modifiers {
        var result: HotkeyFormatter.Modifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.alt) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }
}

/// Several hotkeys shown as removable chips, with a recorder to add one.
struct HotkeyListControl: View {
    let values: [String]
    let commit: ([String]) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.self) { value in
                HStack(spacing: 4) {
                    Text(HotkeyFormatter.display(value)).font(.callout.monospaced())
                    Button {
                        commit(values.filter { $0 != value })
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            }
            KeyRecorderAdd { new in
                if !values.contains(new) { commit(values + [new]) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct KeyRecorderAdd: View {
    let add: (String) -> Void
    var body: some View {
        KeyRecorder(value: "", placeholder: "＋ 添加") { add($0) }
            .help("添加一个快捷键：点击后按下组合键")
    }
}

/// Multi-select of the primary schema's switches (e.g. which options to remember).
struct SwitchListControl: View {
    let selected: [String]
    let available: [(name: String, title: String)]
    let commit: ([String]) -> Void

    var body: some View {
        Menu {
            ForEach(available, id: \.name) { item in
                Toggle(isOn: Binding(
                    get: { selected.contains(item.name) },
                    set: { on in
                        commit(on ? selected + [item.name] : selected.filter { $0 != item.name })
                    }
                )) { Text(item.title) }
            }
        } label: {
            let titles = available.filter { selected.contains($0.name) }.map(\.title)
            Text(titles.isEmpty ? "未选择" : titles.joined(separator: "、")).lineLimit(1)
        }
        .fixedSize()
        .frame(maxWidth: 300, alignment: .trailing)
    }
}

/// System font families, common CJK faces first; no typing of font names.
struct FontPicker: View {
    let value: String
    let commit: (String) -> Void

    static let preferred = ["PingFang SC", "Hiragino Sans GB", "Songti SC", "Kaiti SC", "LXGW WenKai", "Source Han Sans SC",
                            "Noto Sans CJK SC", "Sarasa Gothic SC", "SF Pro Rounded", "Helvetica Neue", "Avenir", "Menlo"]
    static let families: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Menu {
            Section("常用") {
                ForEach(Self.preferred.filter { Self.families.contains($0) || $0.hasPrefix("SF Pro") }, id: \.self) { name in
                    Button { commit(name) } label: { Text(name).font(.custom(name, size: 13)) }
                }
            }
            Menu("全部字体") {
                ForEach(Self.families, id: \.self) { name in
                    Button(name) { commit(name) }
                }
            }
            if !value.isEmpty {
                Divider()
                Button("跟随配色 / 默认") { commit("") }
            }
        } label: {
            Text(value.isEmpty ? "默认" : value).font(value.isEmpty ? .body : .custom(value, size: 13)).lineLimit(1)
        }
        .fixedSize()
    }
}
