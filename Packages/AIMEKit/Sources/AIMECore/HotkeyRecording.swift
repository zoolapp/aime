/// A recording consumes one complete press/release cycle, including repeats.
/// Modifier-only holds remain in capture mode; Rime hotkeys need an ordinary key.
public struct HotkeyRecording: Sendable {
    public enum Event: Sendable { case down, up, modifiers }
    public enum Result: Sendable, Equatable { case waiting, unsupported, retry, cancel, commit(String) }
    private enum Pending: Sendable { case retry, cancel, commit(String) }
    private var pressed: Set<UInt16> = []
    private var modifiers: HotkeyFormatter.Modifiers = []
    private var pending: Pending?
    public private(set) var active = false
    public var waitingForRelease: Bool { pending != nil }

    public init() {}

    public mutating func start(modifiers: HotkeyFormatter.Modifiers = []) {
        stop()
        active = true
        self.modifiers = modifiers
        if !modifiers.isEmpty { pending = .retry }
    }

    public mutating func stop() {
        active = false
        pressed.removeAll(keepingCapacity: false)
        modifiers = []
        pending = nil
    }

    public mutating func handle(_ event: Event, keyCode: UInt16 = 0, character: String? = nil,
                                modifiers: HotkeyFormatter.Modifiers = [], repeatKey: Bool = false) -> Result {
        guard active else { return .waiting }
        self.modifiers = modifiers
        var feedback: Result = .waiting
        switch event {
        case .modifiers: break
        case .up: pressed.remove(keyCode)
        case .down:
            pressed.insert(keyCode)
            guard pressed.count <= 32 else { stop(); return .cancel }
            if keyCode == 0x35, modifiers.isEmpty { pending = .cancel }
            else if pending == nil {
                if repeatKey { pending = .retry }
                else if let name = HotkeyFormatter.rimeName(keyCode: keyCode, character: character, modifiers: modifiers) {
                    pending = .commit(name)
                } else { pending = .retry; feedback = .unsupported }
            }
        }
        guard pressed.isEmpty, modifiers.isEmpty, let pending else { return feedback }
        self.pending = nil
        switch pending {
        case .retry: return .retry
        case .cancel: stop(); return .cancel
        case let .commit(name): stop(); return .commit(name)
        }
    }
}
