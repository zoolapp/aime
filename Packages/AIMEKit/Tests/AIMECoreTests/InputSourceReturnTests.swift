import Testing
@testable import AIMECore

struct InputSourceReturnTests {
    @Test func recognizesOnlyAIMESources() {
        #expect(InputSourceReturn.isAIME("app.zool.inputmethod.aime.hans"))
        #expect(InputSourceReturn.isAIME("app.zool.inputmethod.aime"))
        #expect(!InputSourceReturn.isAIME("com.apple.keylayout.ABC"))
        #expect(!InputSourceReturn.isAIME("im.rime.inputmethod.Squirrel.Hans"))
        #expect(!InputSourceReturn.isAIME("app.zool.inputmethod.aimex"))
    }

    /// The reset is written through the policy so the next app inherits Chinese too.
    @Test func resetRecordsChineseForSharedAndOwnState() {
        var policy = AsciiStatePolicy(scope: .global)
        policy.record(true, app: "com.apple.TextEdit", appDefault: nil)
        policy.record(false, app: "com.apple.TextEdit", appDefault: nil)
        #expect(policy.state(for: "com.apple.Notes", appDefault: nil, newSession: false) == false)

        var perApp = AsciiStatePolicy(scope: .app)
        perApp.record(true, app: "com.apple.TextEdit", appDefault: nil)
        perApp.record(false, app: "com.apple.TextEdit", appDefault: nil)
        #expect(perApp.state(for: "com.apple.TextEdit", appDefault: nil, newSession: false) == false)
    }
}
