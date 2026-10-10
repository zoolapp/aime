public import Foundation

/// Detects "hold one modifier key on its own" — the keyboard way to open the quick menu
/// (like holding a key for an action panel). Pure state: the input method feeds it
/// modifier changes and key presses, starts a timer when it arms, and asks it to fire.
///
/// The hold only fires when the chosen modifier is the *only* one down and no other key
/// is pressed meanwhile, so shortcuts like ⌥← or ⌘C are never mistaken for a hold.
///
/// Left and right keys are told apart with the device-dependent bits in the same
/// `modifierFlags` raw value (`NX_DEVICELALTKEYMASK` and friends): the plain
/// `.option`/`.control`/`.command` cases accept either side, `…Left`/`…Right` only one.
public struct ModifierHold: Sendable, Equatable {
    public enum Key: String, Sendable, Codable, CaseIterable {
        case option, optionLeft, optionRight
        case control, controlLeft, controlRight
        case command, commandLeft, commandRight
        case off

        /// `NSEvent.ModifierFlags` raw value of the key (device-independent).
        public var cocoaFlag: UInt? {
            switch self {
            case .option, .optionLeft, .optionRight: 1 << 19
            case .control, .controlLeft, .controlRight: 1 << 18
            case .command, .commandLeft, .commandRight: 1 << 20
            case .off: nil
            }
        }

        /// Device-dependent bit for the required side (`NX_DEVICELALTKEYMASK` etc.).
        /// `nil` means either side counts. Bit layout per IOLLEvent.h:
        /// LControl 1<<0, RControl 1<<13, LShift 1<<1, RShift 1<<2,
        /// LCommand 1<<3, RCommand 1<<4, LAlt 1<<5, RAlt 1<<6.
        /// (1<<7 is `NX_DEVICE_ALPHASHIFT_STATELESS_MASK`, *not* right control.)
        public var sideMask: UInt? {
            switch self {
            case .optionLeft: 1 << 5
            case .optionRight: 1 << 6
            case .controlLeft: 1 << 0
            case .controlRight: 1 << 13
            case .commandLeft: 1 << 3
            case .commandRight: 1 << 4
            default: nil
            }
        }

        /// Device-dependent bits of *both* sides of this key; zero for `off`.
        /// Watched so the opposite side pressing or joining still invalidates a hold.
        var deviceMask: UInt {
            switch self {
            case .option, .optionLeft, .optionRight: (1 << 5) | (1 << 6)
            case .control, .controlLeft, .controlRight: (1 << 0) | (1 << 13)
            case .command, .commandLeft, .commandRight: (1 << 3) | (1 << 4)
            case .off: 0
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

    /// `flags & relevantMask` must satisfy `matches` for the hold to count:
    /// the key's own bits and nothing else. `relevantMask` adds the device bits of the
    /// key's both sides, so the opposite side joining reads as a second key — not a
    /// plain hold — for both sided and unsided keys.
    private var relevantMask: UInt { Self.modifierMask | key.deviceMask }
    /// "The hold key alone is down": generic flag set, and the device bits show either
    /// the required side alone, or (for an unsided key) either side alone — or no side
    /// bit at all when the source hides it (virtual keyboards, remote sessions).
    private func matches(_ down: UInt) -> Bool {
        guard let flag = key.cocoaFlag else { return false }
        guard down & Self.modifierMask == flag else { return false }
        let sides = down & key.deviceMask
        if let side = key.sideMask { return sides == side }
        // Unsided: zero side bits is fine; exactly one side is fine; both is two keys.
        return sides == 0 || sides & (sides - 1) == 0
    }
    /// The key's own target bit pattern (generic flag + required side, if any); used
    /// where "remove the held key from flags" wants one mask, not a predicate.
    private var target: UInt? {
        guard let flag = key.cocoaFlag else { return nil }
        return flag | (key.sideMask ?? 0)
    }

    /// Ends the input context and invalidates any timer from its previous hold.
    public mutating func reset() {
        cancel()
    }

    /// Feed every modifier change with the *unmasked* `modifierFlags` raw value —
    /// sided keys need the device bits the caller strips for librime. Returns a token
    /// when the caller should start the timer (`duration`) and then call `fire(token:)`.
    public mutating func modifiersChanged(_ flags: UInt) -> Int? {
        let down = flags & relevantMask
        guard key.cocoaFlag != nil else { return nil }
        if matches(down), !isArmed, !isFired {
            isArmed = true
            token += 1
            return token
        }
        if !matches(down) {
            // Released, the wrong side, or another modifier joined: not a plain hold.
            if isArmed { isArmed = false; token += 1 }
        }
        return nil
    }

    /// Any key press while armed turns the hold into an ordinary shortcut.
    public mutating func keyPressed() {
        if isArmed { isArmed = false; token += 1 }
    }

    /// Leaving a field invalidates its pending timer without reusing a token.
    public mutating func cancel() {
        token += 1
        isArmed = false
        isFired = false
    }

    /// Called by the timer. True when the hold is still valid: open the menu.
    public mutating func fire(token fired: Int) -> Bool {
        guard isArmed, fired == token else { return false }
        isArmed = false
        isFired = true
        return true
    }

    /// Feed the modifier change that follows a fired hold (same unmasked flags as
    /// `modifiersChanged`). True when it is the hold key's release, which must not
    /// reach librime (a lone modifier tap can switch Chinese/English there).
    public mutating func consumeRelease(_ flags: UInt) -> Bool {
        guard isFired, let target else { return false }
        // The hold key counts as released when its bits are gone: for a sided key the
        // side bit (the generic flag may still be set by the opposite side); for an
        // unsided key the generic flag clears only once the last side is released.
        let releasedBits = key.sideMask ?? key.cocoaFlag ?? 0
        guard flags & releasedBits == 0 else { return false }
        isFired = false
        return true
    }

    /// Modifier flags with the held key removed: digits pressed while it is still down
    /// count as plain digits in the menu. Input is the same unmasked raw value.
    public func withoutHoldKey(_ flags: UInt) -> UInt {
        guard isFired, let target else { return flags }
        var cleared = flags & ~target
        // A sided key's generic bit may still be earned by the opposite side staying
        // down: keep it, or ⌥+digit on that side would read as a plain menu key.
        if key.sideMask != nil, let flag = key.cocoaFlag,
           flags & flag != 0, cleared & flag == 0 {
            cleared |= flag
        }
        return cleared
    }
}
