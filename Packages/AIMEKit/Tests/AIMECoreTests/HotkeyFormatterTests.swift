import Testing
@testable import AIMECore

struct HotkeyFormatterTests {
    @Test func convertsKeyPressesToRimeNotation() {
        #expect(HotkeyFormatter.rimeName(keyCode: 0x32, character: "`", modifiers: [.control, .shift]) == "Control+Shift+grave")
        #expect(HotkeyFormatter.rimeName(keyCode: 0x00, character: "A", modifiers: [.control]) == "Control+a")
        #expect(HotkeyFormatter.rimeName(keyCode: 0x15, character: "4", modifiers: [.control, .shift]) == "Control+Shift+4")
        #expect(HotkeyFormatter.rimeName(keyCode: 0x21, character: "[", modifiers: []) == "bracketleft")
        #expect(HotkeyFormatter.rimeName(keyCode: 0x76, character: nil, modifiers: []) == "F4")
        #expect(HotkeyFormatter.rimeName(keyCode: 0x0a, character: "§", modifiers: []) == nil)
    }

    @Test func rendersForDisplay() {
        #expect(HotkeyFormatter.display("Control+Shift+grave") == "⌃⇧`")
        #expect(HotkeyFormatter.display("bracketleft") == "[")
        #expect(HotkeyFormatter.display("F4") == "F4")
        #expect(HotkeyFormatter.display("Control+a") == "⌃A")
        #expect(HotkeyFormatter.display("") == "未设置")
    }
}
