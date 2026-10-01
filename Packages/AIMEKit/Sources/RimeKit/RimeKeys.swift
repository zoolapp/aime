/// X11-style keysyms and modifier masks understood by librime, plus the translation
/// from macOS virtual key codes. Written from the public X11 keysym table and Carbon's
/// `Events.h` virtual key constants.
public enum RimeKey {
    // Modifier masks, as librime defines them (rime/key_table.h). Super is librime's
    // own bit (1 << 26), not X11 Mod4 (1 << 6): with the wrong bit every processor
    // treats ⌘V as a plain "v".
    public static let shiftMask: Int32 = 1 << 0
    public static let lockMask: Int32 = 1 << 1
    public static let controlMask: Int32 = 1 << 2
    public static let altMask: Int32 = 1 << 3
    public static let superMask: Int32 = 1 << 26
    public static let releaseMask: Int32 = 1 << 30

    // Keysyms.
    public static let space: Int32 = 0x20
    public static let backSpace: Int32 = 0xff08
    public static let tab: Int32 = 0xff09
    public static let returnKey: Int32 = 0xff0d
    public static let escape: Int32 = 0xff1b
    public static let eisuToggle: Int32 = 0xff30
    public static let kana: Int32 = 0xff27
    public static let home: Int32 = 0xff50
    public static let left: Int32 = 0xff51
    public static let up: Int32 = 0xff52
    public static let right: Int32 = 0xff53
    public static let down: Int32 = 0xff54
    public static let pageUp: Int32 = 0xff55
    public static let pageDown: Int32 = 0xff56
    public static let end: Int32 = 0xff57
    public static let help: Int32 = 0xff6a
    public static let keypadEnter: Int32 = 0xff8d
    public static let f1: Int32 = 0xffbe
    public static let shiftL: Int32 = 0xffe1
    public static let shiftR: Int32 = 0xffe2
    public static let controlL: Int32 = 0xffe3
    public static let controlR: Int32 = 0xffe4
    public static let capsLock: Int32 = 0xffe5
    public static let altL: Int32 = 0xffe9
    public static let altR: Int32 = 0xffea
    public static let superL: Int32 = 0xffeb
    public static let superR: Int32 = 0xffec
    public static let delete: Int32 = 0xffff
    public static let keypad0: Int32 = 0xffb0
    public static let keypadMultiply: Int32 = 0xffaa
    public static let keypadAdd: Int32 = 0xffab
    public static let keypadSubtract: Int32 = 0xffad
    public static let keypadDecimal: Int32 = 0xffae
    public static let keypadDivide: Int32 = 0xffaf
    public static let keypadEqual: Int32 = 0xffbd

    /// macOS virtual key code → keysym for keys whose meaning does not depend on the
    /// keyboard layout.
    public static func keysym(forVirtualKey keyCode: UInt16) -> Int32? {
        switch keyCode {
        case 0x24: returnKey
        case 0x4c: keypadEnter
        case 0x30: tab
        case 0x31: space
        case 0x33: backSpace
        case 0x35: escape
        case 0x75: delete
        case 0x73: home
        case 0x77: end
        case 0x74: pageUp
        case 0x79: pageDown
        case 0x7b: left
        case 0x7c: right
        case 0x7d: down
        case 0x7e: up
        case 0x72: help
        case 0x66: eisuToggle
        case 0x68: kana
        case 0x38: shiftL
        case 0x3c: shiftR
        case 0x3b: controlL
        case 0x3e: controlR
        case 0x3a: altL
        case 0x3d: altR
        case 0x37: superL
        case 0x36: superR
        case 0x39: capsLock
        default: functionKey(keyCode) ?? keypadKey(keyCode)
        }
    }

    /// Numeric keypad keys get their own keysyms (so key bindings can tell them apart,
    /// e.g. rime-ice sends KP_1 as a digit instead of selecting a candidate).
    private static func keypadKey(_ keyCode: UInt16) -> Int32? {
        switch keyCode {
        case 0x52: keypad0
        case 0x53...0x59: keypad0 + Int32(keyCode - 0x52)
        case 0x5b: keypad0 + 8
        case 0x5c: keypad0 + 9
        case 0x41: keypadDecimal
        case 0x43: keypadMultiply
        case 0x45: keypadAdd
        case 0x4e: keypadSubtract
        case 0x4b: keypadDivide
        case 0x51: keypadEqual
        default: nil
        }
    }

    private static func functionKey(_ keyCode: UInt16) -> Int32? {
        let order: [UInt16: Int32] = [
            0x7a: 0, 0x78: 1, 0x63: 2, 0x76: 3, 0x60: 4, 0x61: 5, 0x62: 6, 0x64: 7, 0x65: 8,
            0x6d: 9, 0x67: 10, 0x6f: 11, 0x69: 12, 0x6b: 13, 0x71: 14, 0x6a: 15, 0x40: 16,
            0x4f: 17, 0x50: 18, 0x5a: 19,
        ]
        return order[keyCode].map { f1 + $0 }
    }

    /// Keysym for a character produced by the current layout.
    public static func keysym(forCharacter scalar: Unicode.Scalar) -> Int32 {
        let value = scalar.value
        if (0x20...0x7e).contains(value) { return Int32(value) }
        // Latin-1 maps directly; everything else uses the Unicode keysym range.
        if (0xa0...0xff).contains(value) { return Int32(value) }
        return Int32(bitPattern: 0x0100_0000 | value)
    }

    /// Modifier bitfield (NSEvent.ModifierFlags raw values) → librime mask.
    public static func mask(fromCocoaFlags flags: UInt) -> Int32 {
        var mask: Int32 = 0
        if flags & (1 << 16) != 0 { mask |= lockMask }      // capsLock
        if flags & (1 << 17) != 0 { mask |= shiftMask }     // shift
        if flags & (1 << 18) != 0 { mask |= controlMask }   // control
        if flags & (1 << 19) != 0 { mask |= altMask }       // option
        if flags & (1 << 20) != 0 { mask |= superMask }     // command
        return mask
    }

    /// Full translation of a key-down event.
    ///
    /// - Parameters:
    ///   - keyCode: `NSEvent.keyCode`
    ///   - charactersIgnoringModifiers: `NSEvent.charactersIgnoringModifiers`
    ///   - characters: `NSEvent.characters` (what the layout produces with the modifiers)
    ///   - flags: `NSEvent.modifierFlags.rawValue`
    public static func translate(keyCode: UInt16, charactersIgnoringModifiers: String?, characters: String? = nil,
                                 flags: UInt) -> (keysym: Int32, mask: Int32)? {
        let mask = mask(fromCocoaFlags: flags)
        if let keysym = keysym(forVirtualKey: keyCode) {
            return (keysym, mask)
        }
        guard var scalar = charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        // X11 convention: the keysym is the symbol actually typed, Shift stays in the mask
        // (Shift+/ is "question", not "slash"). `charactersIgnoringModifiers` does not
        // apply Shift to symbol keys, so with Shift alone take the layout's output.
        // Ctrl / Option / ⌘ combinations keep the unmodified key for bindings.
        if mask & (controlMask | altMask | superMask) == 0, mask & shiftMask != 0,
           let typed = characters?.unicodeScalars.first, (0x21...0x7e).contains(typed.value),
           !(("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)) {
            scalar = typed
        }
        var effective = scalar
        // Letters follow the conventions of other Rime frontends: the keysym carries the
        // visible case (Shift XOR Caps Lock) and the modifier mask is kept, so bindings
        // like Shift+A still match and librime decides what Caps Lock means.
        let isLetter = ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
        if isLetter {
            let upper = (mask & shiftMask != 0) != (mask & lockMask != 0)
            let lower = Character(scalar).lowercased().unicodeScalars.first!
            effective = upper ? Character(lower).uppercased().unicodeScalars.first! : lower
        }
        return (keysym(forCharacter: effective), mask)
    }
}
