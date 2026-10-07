import Testing
@testable import AIMECore

struct AsciiStatePolicyTests {
    @Test(arguments: [AsciiStateScope.global, .app])
    func lateDeactivationCannotOverwriteTheActiveFieldsChoice(scope: AsciiStateScope) {
        var policy = AsciiStatePolicy(scope: scope)
        let app = "test.chat"
        for appDefault in [nil, true, false] as [Bool?] {
            policy.record(true, app: app, appDefault: appDefault)
            policy.record(false, app: app, appDefault: appDefault)
            // The old field still holds English when IMK sends its delayed deactivate.
            policy.record(true, app: app, appDefault: appDefault, isActive: false)
            #expect(policy.state(for: app, appDefault: appDefault, newSession: false) == false)
            #expect(policy.state(for: app, appDefault: appDefault, newSession: true) == false)
        }
    }

    @Test func globalScopeSharesStateAcrossOrdinaryApps() {
        var policy = AsciiStatePolicy(scope: .global)
        #expect(policy.state(for: "com.tencent.xinWeChat", appDefault: nil, newSession: true) == false)
        policy.record(true, app: "com.tencent.xinWeChat", appDefault: nil) // Shift → English in WeChat
        #expect(policy.state(for: "com.apple.Safari", appDefault: nil, newSession: true) == true)
        policy.record(false, app: "com.apple.Safari", appDefault: nil)
        #expect(policy.state(for: "com.tencent.xinWeChat", appDefault: nil, newSession: false) == false)
    }

    @Test func englishFirstAppsAreIslandsUnderGlobalScope() {
        var policy = AsciiStatePolicy(scope: .global)
        let term = "com.mitchellh.ghostty"
        #expect(policy.state(for: term, appDefault: true, newSession: true) == true)   // first entry: English
        policy.record(false, app: term, appDefault: true)                              // user switches to 中文 there
        #expect(policy.state(for: "com.apple.Notes", appDefault: nil, newSession: true) == false)
        policy.record(true, app: "com.apple.Notes", appDefault: nil)                 // English in Notes…
        #expect(policy.state(for: term, appDefault: true, newSession: false) == false) // …does not leak into the terminal
        #expect(policy.state(for: "com.apple.Mail", appDefault: nil, newSession: true) == true)
    }

    @Test func appScopeRemembersEachApp() {
        var policy = AsciiStatePolicy(scope: .app)
        policy.record(true, app: "a", appDefault: nil)
        #expect(policy.state(for: "b", appDefault: nil, newSession: true) == false)
        #expect(policy.state(for: "a", appDefault: nil, newSession: false) == true)
    }

    @Test func windowScopeOnlySeedsNewSessions() {
        var policy = AsciiStatePolicy(scope: .window)
        policy.record(true, app: "a", appDefault: nil)
        #expect(policy.state(for: "a", appDefault: nil, newSession: true) == false)
        #expect(policy.state(for: "a", appDefault: true, newSession: true) == true)
        #expect(policy.state(for: "a", appDefault: nil, newSession: false) == nil)
    }

    @Test func chineseFirstAppsKeepTheirOwnState() {
        var policy = AsciiStatePolicy(scope: .global)
        policy.record(true, app: "com.apple.Notes", appDefault: nil)                      // English everywhere else…
        #expect(policy.state(for: "com.tencent.xinWeChat", appDefault: false, newSession: true) == false) // …WeChat still opens in 中文
        policy.record(true, app: "com.tencent.xinWeChat", appDefault: false)
        #expect(policy.state(for: "com.tencent.xinWeChat", appDefault: false, newSession: false) == true) // and remembers its own state
        #expect(policy.state(for: "com.apple.Mail", appDefault: nil, newSession: true) == true)
    }
}
