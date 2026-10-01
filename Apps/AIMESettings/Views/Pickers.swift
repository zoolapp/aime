import AIMECore
import AppKit
import SwiftUI

/// Click, then press a key combination; stored in Rime notation. No typing of key names.
struct KeyRecorder: View {
    let value: String
    var placeholder: String?
    let commit: (String) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "请按下按键…" : (value.isEmpty && placeholder != nil ? placeholder! : HotkeyFormatter.display(value)))
                .font(.body.monospaced())
                .frame(minWidth: 96)
                .padding(.vertical, 2)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .help("点击后直接按下想要的按键组合；按 Esc 取消")
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            defer { stop() }
            if event.keyCode == 0x35, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { return nil }
            var modifiers: HotkeyFormatter.Modifiers = []
            let flags = event.modifierFlags
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.option) { modifiers.insert(.alt) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.command) { modifiers.insert(.command) }
            if let name = HotkeyFormatter.rimeName(keyCode: event.keyCode, character: event.charactersIgnoringModifiers, modifiers: modifiers) {
                commit(name)
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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
