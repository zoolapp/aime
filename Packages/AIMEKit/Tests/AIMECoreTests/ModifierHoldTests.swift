import Testing
@testable import AIMECore

struct ModifierHoldTests {
    let option: UInt = 1 << 19, shift: UInt = 1 << 17, command: UInt = 1 << 20

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
