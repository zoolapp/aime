/// Telling AIME's own input source apart from the others, for
/// `ascii_state/reset_on_return` (#25).
public enum InputSourceReturn {
    /// AIME's bundle and its input modes (`app.zool.inputmethod.aime.hans`).
    public static let bundleID = "app.zool.inputmethod.aime"

    public static func isAIME(_ inputSourceID: String) -> Bool {
        inputSourceID == bundleID || inputSourceID.hasPrefix(bundleID + ".")
    }
}
