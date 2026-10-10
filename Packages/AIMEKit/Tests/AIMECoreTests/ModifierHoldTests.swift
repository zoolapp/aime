import Testing
@testable import AIMECore

struct ModifierHoldTests {
    let option: UInt = 1 << 19, shift: UInt = 1 << 17, command: UInt = 1 << 20
    // Device-dependent bits per IOLLEvent.h: L⌃ 1<<0, R⌃ 1<<13, L⌥ 1<<5, R⌥ 1<<6.
    // (1<<7 is NX_DEVICE_ALPHASHIFT_STATELESS_MASK — a real right ⌃ is bit 13.)
    let lOption: UInt = (1 << 19) | (1 << 5), rOption: UInt = (1 << 19) | (1 << 6)
    let lControl: UInt = (1 << 18) | (1 << 0), rControl: UInt = (1 << 18) | (1 << 13)

    @Test func holdingTheKeyAloneFiresOnce() {
        var hold = ModifierHold(key: .option)
        let token = hold.modifiersChanged(option)
        #expect(token != nil)
        #expect(hold.isArmed)
        let repeated = hold.modifiersChanged(option)            // repeated event (Catalyst) does not re-arm
        #expect(repeated == nil)
        let fired = hold.fire(token: token ?? -1)
        let firedAgain = hold.fire(token: token ?? -1)
        #expect(fired && !firedAgain)                           // only once
        #expect(hold.isFired)
        // Digits typed while the key is still down are plain digits for the menu.
        #expect(hold.withoutHoldKey(option) == 0)
        let swallowed = hold.consumeRelease(0)                  // the release never reaches librime
        let swallowedAgain = hold.consumeRelease(0)
        #expect(swallowed && !swallowedAgain)
        #expect(!hold.isFired)
    }

    @Test func shortcutsAndQuickTapsDoNotFire() {
        var hold = ModifierHold(key: .option)
        var token = hold.modifiersChanged(option) ?? -1
        hold.keyPressed()                                       // ⌥← : a shortcut, not a hold
        let afterShortcut = hold.fire(token: token)
        #expect(!afterShortcut)

        _ = hold.modifiersChanged(0)
        token = hold.modifiersChanged(option) ?? -1
        _ = hold.modifiersChanged(0)                            // released before the timer
        let afterTap = hold.fire(token: token)
        #expect(!afterTap)

        token = hold.modifiersChanged(option) ?? -1
        _ = hold.modifiersChanged(option | shift)               // another modifier joined
        let afterCombo = hold.fire(token: token)
        #expect(!afterCombo)
        _ = hold.modifiersChanged(0)
        let otherKey = hold.modifiersChanged(command)           // a different key never arms
        #expect(otherKey == nil)
    }

    @Test func offNeverArms() {
        var hold = ModifierHold(key: .off)
        let token = hold.modifiersChanged(option)
        #expect(token == nil)
        #expect(!hold.isArmed)
    }

    @Test func leavingAFieldInvalidatesItsTimerWithoutReusingTokens() {
        var hold = ModifierHold()
        let old = hold.modifiersChanged(option) ?? -1
        hold.cancel()
        let next = hold.modifiersChanged(option) ?? -1
        #expect(next > old)
        let staleFired = hold.fire(token: old)
        #expect(!staleFired)
        let fired = hold.fire(token: next)
        #expect(fired)
        hold.cancel()
        #expect(!hold.isFired)
        #expect(hold.withoutHoldKey(option) == option)
    }

    @Test func resetInvalidatesPendingTimerEvenAfterRearming() throws {
        var hold = ModifierHold(key: .option)
        let armedToken = hold.modifiersChanged(option)
        let oldToken = try #require(armedToken)
        hold.reset()
        #expect(!hold.isArmed && !hold.isFired)
        #expect(hold.token == oldToken + 1)
        let staleFire = hold.fire(token: oldToken)
        #expect(!staleFire)

        let rearmedToken = hold.modifiersChanged(option)
        let newToken = try #require(rearmedToken)
        let staleFireAfterRearming = hold.fire(token: oldToken)
        #expect(!staleFireAfterRearming && hold.isArmed)
        let freshFire = hold.fire(token: newToken)
        #expect(freshFire)
    }

    @Test func sidedKeyOnlyArmsOnItsOwnSide() {
        var hold = ModifierHold(key: .optionLeft)
        var token = hold.modifiersChanged(lOption)
        #expect(token != nil)                                   // left ⌥ arms
        hold.cancel()
        token = hold.modifiersChanged(rOption)
        #expect(token == nil)                                   // right ⌥ does not
        #expect(!hold.isArmed)
        token = hold.modifiersChanged(option)
        #expect(token == nil)                                   // side-less press (virtual kbd)

        hold.key = .optionRight
        token = hold.modifiersChanged(rOption)
        #expect(token != nil)
        hold.cancel()
        token = hold.modifiersChanged(lOption)
        #expect(token == nil)

        hold.key = .controlLeft
        token = hold.modifiersChanged(lControl)
        #expect(token != nil)
        hold.cancel()
        token = hold.modifiersChanged(rControl)
        #expect(token == nil)

        hold.key = .controlRight                                  // right ⌃: bit 13, not 7
        token = hold.modifiersChanged(rControl)
        #expect(token != nil)
        hold.cancel()
        token = hold.modifiersChanged(lControl)
        #expect(token == nil)
        token = hold.modifiersChanged((1 << 18) | (1 << 7))       // alphashift-stateless is not ⌃
        #expect(token == nil)
    }

    @Test func unsidedKeyAcceptsEitherSideButNotBoth() {
        var hold = ModifierHold(key: .option)
        var token = hold.modifiersChanged(lOption)
        #expect(token != nil)
        hold.cancel()
        token = hold.modifiersChanged(rOption)
        #expect(token != nil)
        hold.cancel()
        token = hold.modifiersChanged(option)
        #expect(token != nil)                                   // no side info still works
        hold.cancel()
        // Both ⌥ keys down = two keys, never a plain hold, whatever the configured side.
        token = hold.modifiersChanged(lOption | rOption)
        #expect(token == nil)
        hold.key = .optionLeft
        token = hold.modifiersChanged(lOption | rOption)
        #expect(token == nil)
    }

    @Test func oppositeSideJoiningCancelsASidedHold() {
        var hold = ModifierHold(key: .optionLeft)
        let token = hold.modifiersChanged(lOption) ?? -1
        _ = hold.modifiersChanged(lOption | rOption)            // right ⌥ joins the hold
        let fired = hold.fire(token: token)
        #expect(!fired)
        // Releasing the joined side still leaves the hold key down, but the hold is over.
        // The event stream re-arms on the still-held key — same as ⇧+⌥ → release ⇧ today —
        // so the timer just restarts; asserting no *stale* token fires is what matters.
        let rearmed = hold.modifiersChanged(lOption)
        #expect(rearmed != nil)
        #expect(hold.isArmed)
    }

    @Test func sidedReleaseIsOnlyConsumedWhenThatSideLeaves() {
        var hold = ModifierHold(key: .optionLeft)
        var token = hold.modifiersChanged(lOption) ?? -1
        var fired = hold.fire(token: token)
        #expect(fired)
        // Right ⌥ still held while left leaves: generic ⌥ flag remains, the side bit is proof.
        var consumed = hold.consumeRelease(rOption)
        #expect(consumed)
        #expect(!hold.isFired)

        hold.cancel()
        hold.key = .optionRight
        token = hold.modifiersChanged(rOption) ?? -1
        fired = hold.fire(token: token)
        #expect(fired)
        // Left ⌥ joins while the fired key stays down: its bit is still set → not a release.
        consumed = hold.consumeRelease(lOption | rOption)
        #expect(!consumed)
        #expect(hold.isFired)
        consumed = hold.consumeRelease(lOption)                 // right side leaves, left stays
        #expect(consumed)
        #expect(!hold.isFired)

        // Unsided key fires while both sides are down is impossible, but a plain
        // release check still holds: either side's flags keep the generic bit set.
        hold.cancel()
        hold.key = .option
        token = hold.modifiersChanged(lOption) ?? -1
        fired = hold.fire(token: token)
        #expect(fired)
        consumed = hold.consumeRelease(0)
        #expect(consumed)
    }

    @Test func withoutHoldKeyKeepsGenericFlagWhileOppositeSideIsDown() {
        var hold = ModifierHold(key: .optionLeft)
        let token = hold.modifiersChanged(lOption) ?? -1
        let fired = hold.fire(token: token)
        #expect(fired)
        // Right ⌥ joins while the menu is up: ⌥+2 on that side must not read as plain "2".
        let both = lOption | rOption
        #expect(hold.withoutHoldKey(both) & option == option)
        // The held side's device bit is still stripped; released left, right still down.
        #expect(hold.withoutHoldKey(rOption) & option == option)
        // Nothing held: everything stripped.
        #expect(hold.withoutHoldKey(0) == 0)
    }

    @Test func sidedKeysKeepDistinctRawValues() {
        // features.json stores rawValues; legacy "option" must stay "any side".
        #expect(ModifierHold.Key(rawValue: "option") == .option)
        #expect(ModifierHold.Key.optionLeft.rawValue == "optionLeft")
        #expect(ModifierHold.Key.optionRight.rawValue == "optionRight")
        #expect(ModifierHold.Key.allCases.count == 10)
    }

    @Test func resetClearsFiredStateWithoutConsumingNextRelease() throws {
        var hold = ModifierHold(key: .option)
        let armedToken = hold.modifiersChanged(option)
        let token = try #require(armedToken)
        let fired = hold.fire(token: token)
        #expect(fired)
        hold.reset()
        #expect(!hold.isFired && !hold.isArmed)
        #expect(hold.key == .option)
        #expect(hold.withoutHoldKey(option) == option)
        let consumed = hold.consumeRelease(0)
        #expect(!consumed)
        let newToken = hold.modifiersChanged(option)
        #expect(newToken != nil)
    }
}
