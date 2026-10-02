public import Foundation

/// Detects "hold one modifier key on its own" — the keyboard way to open the quick menu
/// (like holding a key for an action panel). Pure state: the input method feeds it
/// modifier changes and key presses, starts a timer when it arms, and asks it to fire.
///
/// The hold only fires when the chosen modifier is the *only* one down and no other key
/// is pressed meanwhile, so shortcuts like ⌥← or ⌘C are never mistaken for a hold.
public struct ModifierHold: Sendable, Equatable {
    public enum Key: String, Sendable, Codable, CaseIterable {
        case option, control, command, off

        /// `NSEvent.ModifierFlags` raw value of the key.
        public var cocoaFlag: UInt? {
            switch self {
            case .option: 1 << 19
            case .control: 1 << 18
            case .command: 1 << 20
            case .off: nil
            }
        }
    }

    /// Long enough not to trigger on ordinary shortcuts, short enough to feel instant.
    public static let duration: TimeInterval = 0.35
    /// The four modifier bits that matter (shift, control, option, command).
    static let modifierMask: UInt = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)

    public var key: Key
    /// Bumped whenever a pending hold becomes invalid; a timer carries the value it saw.
    public private(set) var token = 0
    public private(set) var isArmed = false
    /// The hold fired and its key is still down.
    public private(set) var isFired = false

    public init(key: Key = .option) { self.key = key }

    /// Ends the input context and invalidates any timer from its previous hold.
    public mutating func reset() {
        isArmed = false
        isFired = false
        token += 1
    }

    /// Feed every modifier change. Returns a token when the caller should start the
    /// timer (`duration`) and then call `fire(token:)`.
    public mutating func modifiersChanged(_ flags: UInt) -> Int? {
        let down = flags & Self.modifierMask
        guard let flag = key.cocoaFlag else { return nil }
        if down == flag, !isArmed, !isFired {
            isArmed = true
            token += 1
            return token
        }
        if down != flag {
            // Released, or another modifier joined: not a plain hold any more.
            if isArmed { isArmed = false; token += 1 }
        }
        return nil
    }

    /// Any key press while armed turns the hold into an ordinary shortcut.
    public mutating func keyPressed() {
        if isArmed { isArmed = false; token += 1 }
    }

    /// Called by the timer. True when the hold is still valid: open the menu.
    public mutating func fire(token fired: Int) -> Bool {
        guard isArmed, fired == token else { return false }
        isArmed = false
        isFired = true
        return true
    }

    /// Feed the modifier change that follows a fired hold. True when it is the hold
    /// key's release, which must not reach librime (a lone modifier tap can switch
    /// Chinese/English there).
    public mutating func consumeRelease(_ flags: UInt) -> Bool {
        guard isFired, let flag = key.cocoaFlag, flags & flag == 0 else { return false }
        isFired = false
        return true
    }

    /// Modifier flags with the held key removed: digits pressed while it is still down
    /// count as plain digits in the menu.
    public func withoutHoldKey(_ flags: UInt) -> UInt {
        guard isFired, let flag = key.cocoaFlag else { return flags }
        return flags & ~flag
    }
}
