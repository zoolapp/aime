import Carbon
import Foundation

/// `AIME --install`: registers, enables and selects the AIME input source from the
/// input method's own process (what an installer's postinstall step runs).
/// Text Input Sources only lets an input method select its own modes reliably from
/// its own bundle.
enum InputSourceInstaller {
    static let modeID = "app.zool.inputmethod.aime.hans"

    static func property(_ source: TISInputSource, _ key: CFString) -> Any? {
        TISGetInputSourceProperty(source, key).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
    }

    static func sources() -> [TISInputSource] {
        let filter = [kTISPropertyBundleID as String: Bundle.main.bundleIdentifier ?? ""] as CFDictionary
        return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
    }

    /// Returns a process exit code.
    static func install(select: Bool) -> Int32 {
        let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
        print("register: \(status)")
        var enabledAny = false
        for source in sources() {
            let id = property(source, kTISPropertyInputSourceID) as? String ?? ""
            let result = TISEnableInputSource(source)
            print("enable \(id): \(result)")
            enabledAny = enabledAny || result == noErr
        }
        guard select else { return enabledAny ? 0 : 1 }
        guard let mode = sources().first(where: { property($0, kTISPropertyInputSourceID) as? String == modeID }) else {
            print("select: mode not found (log out and back in, then retry)")
            return 1
        }
        let result = TISSelectInputSource(mode)
        print("select \(modeID): \(result)")
        return result == noErr ? 0 : 1
    }
}
