import Foundation
import Testing
@testable import RimeKit


@MainActor
@Suite(.serialized)
struct RimeKitTests {
    static let workspace: (shared: URL, user: URL) = {
        let workspace = try! Fixtures.makeWorkspace()
        let engine = RimeEngine.shared
        engine.initialize(RimeTraits(sharedDataDir: workspace.shared, userDataDir: workspace.user, minLogLevel: 2))
        engine.deployAndWait()
        return workspace
    }()

    init() {
        let workspace = Self.workspace
        RimeEngine.shared.ensureInitialized(RimeTraits(sharedDataDir: workspace.shared, userDataDir: workspace.user, minLogLevel: 2))
    }

    @Test func reportsVersion() {
        #expect(RimeEngine.shared.version.hasPrefix("1."))
    }

    @Test func deploysSchemaIntoStagingDir() throws {
        let built = Self.workspace.user.appendingPathComponent("build/test_pinyin.schema.yaml")
        #expect(FileManager.default.fileExists(atPath: built.path))
        #expect(RimeEngine.shared.schemaList().map(\.id) == ["test_pinyin"])
    }

    @Test func producesCandidatesAndCommits() throws {
        let session = try RimeEngine.shared.createSession()
        for key in "nihao".unicodeScalars {
            session.processKey(RimeKey.keysym(forCharacter: key))
        }
        let context = session.context()
        #expect(context.candidates.first?.text == "你好")
        #expect(context.composition.preedit.isEmpty == false)
        #expect(context.pageSize == 5)
        #expect(session.input == "nihao")

        #expect(session.processKey(RimeKey.space))
        #expect(session.consumeCommit() == "你好")
        #expect(session.context().isComposing == false)
    }

    /// The frontend forwards every key with its real modifiers and returns librime's
    /// verdict. ⌘ shortcuts are then left to the app by librime itself (all built-in
    /// processors skip Super), while bindings from the deployed config still apply.
    @Test func commandShortcutsAreLeftToTheApp() throws {
        let session = try RimeEngine.shared.createSession()
        defer { session.clearComposition() }
        #expect(RimeKey.mask(fromCocoaFlags: 1 << 20) == 1 << 26) // librime kSuperMask
        #expect(session.processKey(RimeKey.keysym(forCharacter: "v"), modifiers: RimeKey.superMask) == false)
        #expect(session.input.isEmpty)
        // While composing too: the composition stays, the shortcut goes to the app.
        for key in "ni".unicodeScalars { session.processKey(RimeKey.keysym(forCharacter: key)) }
        #expect(session.processKey(RimeKey.keysym(forCharacter: "c"), modifiers: RimeKey.superMask) == false)
        #expect(session.processKey(RimeKey.keysym(forCharacter: "a"), modifiers: RimeKey.controlMask) == false)
        #expect(session.processKey(RimeKey.keysym(forCharacter: "e"), modifiers: RimeKey.altMask) == false)
        #expect(session.input == "ni")
    }

    /// Shift+symbol keys send the symbol actually typed ("?" for Shift+/), keeping Shift
    /// in the mask; letters keep their case rule; Ctrl/⌘ combos keep the plain key.
    @Test func shiftedSymbolsUseTheTypedCharacter() {
        let shift: UInt = 1 << 17, control: UInt = 1 << 18
        let slash: UInt16 = 0x2c
        #expect(RimeKey.translate(keyCode: slash, charactersIgnoringModifiers: "/", characters: "?", flags: shift)?.keysym == Int32(UInt8(ascii: "?")))
        #expect(RimeKey.translate(keyCode: slash, charactersIgnoringModifiers: "/", characters: "?", flags: shift)?.mask == RimeKey.shiftMask)
        #expect(RimeKey.translate(keyCode: 0x12, charactersIgnoringModifiers: "1", characters: "!", flags: shift)?.keysym == Int32(UInt8(ascii: "!")))
        #expect(RimeKey.translate(keyCode: slash, charactersIgnoringModifiers: "/", characters: "/", flags: 0)?.keysym == Int32(UInt8(ascii: "/")))
        #expect(RimeKey.translate(keyCode: slash, charactersIgnoringModifiers: "/", characters: "\u{1f}", flags: shift | control)?.keysym == Int32(UInt8(ascii: "/")))
        #expect(RimeKey.translate(keyCode: 0x00, charactersIgnoringModifiers: "a", characters: "A", flags: shift)?.keysym == Int32(UInt8(ascii: "A")))
        // Real NSEvent values for ⌃⇧3 / ⌃⇧4 / ⌃⇧/: Shift stays applied in
        // charactersIgnoringModifiers, `characters` holds the unshifted key (#10).
        #expect(RimeKey.translate(keyCode: 0x14, charactersIgnoringModifiers: "#", characters: "3", flags: shift | control)?.keysym == Int32(UInt8(ascii: "3")))
        #expect(RimeKey.translate(keyCode: 0x15, charactersIgnoringModifiers: "$", characters: "4", flags: shift | control)?.keysym == Int32(UInt8(ascii: "4")))
        #expect(RimeKey.translate(keyCode: slash, charactersIgnoringModifiers: "?", characters: "/", flags: shift | control)?.keysym == Int32(UInt8(ascii: "/")))
        #expect(RimeKey.translate(keyCode: 0x14, charactersIgnoringModifiers: "#", characters: "3", flags: shift | control)?.mask == RimeKey.shiftMask | RimeKey.controlMask)
    }

    @Test func selectsByLabelAndPages() throws {
        let session = try RimeEngine.shared.createSession()
        session.simulate(keySequence: "shi")
        let texts = session.context().candidates.map(\.text)
        #expect(texts.contains("是"))
        let index = try #require(texts.firstIndex(of: "是"))
        #expect(session.selectCandidate(onCurrentPage: index))
        #expect(session.consumeCommit() == "是")
    }

    @Test func togglesAsciiModeOption() throws {
        let session = try RimeEngine.shared.createSession()
        session.setOption("ascii_mode", true)
        #expect(session.status()?.isASCIIMode == true)
        #expect(session.processKey(RimeKey.keysym(forCharacter: "a")) == false)
        session.setOption("ascii_mode", false)
        #expect(session.stateLabel(option: "ascii_mode", state: false, abbreviated: false) == "中")
    }

    @Test func frontendConsumedShortcutDoesNotBecomeAShiftTap() throws {
        let session = try RimeEngine.shared.createSession()
        session.setOption("ascii_mode", false)
        // Reproduce the old menu path: RIME sees only Shift press/release.
        session.processKey(RimeKey.shiftL)
        session.processKey(RimeKey.shiftL, modifiers: RimeKey.shiftMask | RimeKey.releaseMask)
        #expect(session.option("ascii_mode"))
        session.setOption("ascii_mode", false)
        session.simulate(keySequence: "nihao")
        let before = session.context()
        session.processKey(RimeKey.shiftL)
        session.cancelModifierTap() // menu consumes Shift+letter
        session.processKey(RimeKey.shiftL, modifiers: RimeKey.shiftMask | RimeKey.releaseMask)
        #expect(!session.option("ascii_mode"))
        #expect(session.context() == before)
        #expect(session.consumeCommit() == nil)
        // A real lone Shift tap still works afterwards.
        session.clearComposition()
        session.processKey(RimeKey.shiftL)
        session.processKey(RimeKey.shiftL, modifiers: RimeKey.shiftMask | RimeKey.releaseMask)
        #expect(session.option("ascii_mode"))
    }

    /// Caps Lock goes to English and back, like Squirrel (#11). The frontend sees the
    /// lock state after the toggle and must hand librime the state before it.
    @Test func capsLockTogglesAsciiModeBothWays() throws {
        let capsOn: UInt = 1 << 16
        #expect(RimeKey.capsLockMask(fromCocoaFlags: capsOn) == 0)
        #expect(RimeKey.capsLockMask(fromCocoaFlags: 0) == RimeKey.lockMask)
        #expect(RimeKey.capsLockMask(fromCocoaFlags: capsOn | 1 << 17) == RimeKey.shiftMask)

        let session = try RimeEngine.shared.createSession()
        session.setOption("ascii_mode", false)
        func pressCapsLock(flagsAfterToggle flags: UInt) {
            let mask = RimeKey.capsLockMask(fromCocoaFlags: flags)
            session.processKey(RimeKey.capsLock, modifiers: mask)
            session.processKey(RimeKey.capsLock, modifiers: mask | RimeKey.releaseMask)
        }
        pressCapsLock(flagsAfterToggle: capsOn)
        #expect(session.option("ascii_mode"))
        pressCapsLock(flagsAfterToggle: 0)
        #expect(!session.option("ascii_mode"))
        pressCapsLock(flagsAfterToggle: capsOn)
        #expect(session.option("ascii_mode"))
        pressCapsLock(flagsAfterToggle: 0)
        #expect(!session.option("ascii_mode"))
    }

    @Test func readsMergedConfig() throws {
        let config = try RimeEngine.shared.openConfig("default")
        #expect(config.int("menu/page_size") == 5)
        #expect(config.listSize("schema_list") == 1)
        #expect(config.string("schema_list/@0/schema") == "test_pinyin")
    }

    @Test func mapsMacKeyCodes() {
        #expect(RimeKey.keysym(forVirtualKey: 0x24) == RimeKey.returnKey)
        #expect(RimeKey.keysym(forVirtualKey: 0x7a) == RimeKey.f1)
        #expect(RimeKey.keysym(forVirtualKey: 0x5a) == RimeKey.f1 + 19)
        let shifted = RimeKey.translate(keyCode: 0x00, charactersIgnoringModifiers: "A", flags: 1 << 17)
        #expect(shifted?.keysym == 0x41)
        #expect(shifted?.mask == RimeKey.shiftMask)
        let caps = RimeKey.translate(keyCode: 0x00, charactersIgnoringModifiers: "a", flags: 1 << 16)
        #expect(caps?.keysym == 0x41)
        #expect(caps?.mask == RimeKey.lockMask)
        let capsShift = RimeKey.translate(keyCode: 0x00, charactersIgnoringModifiers: "A", flags: (1 << 16) | (1 << 17))
        #expect(capsShift?.keysym == 0x61)
        #expect(RimeKey.keysym(forVirtualKey: 0x53) == RimeKey.keypad0 + 1)
        #expect(RimeKey.keysym(forVirtualKey: 0x5c) == RimeKey.keypad0 + 9)
        #expect(RimeKey.keysym(forVirtualKey: 0x41) == RimeKey.keypadDecimal)
        let control = RimeKey.translate(keyCode: 0x00, charactersIgnoringModifiers: "a", flags: 1 << 18)
        #expect(control?.mask == RimeKey.controlMask)
    }
}

extension RimeKitTests {
    @Test func cleanupInvalidatesWrappersSoReusedIdsAreSafe() throws {
        let old = try RimeEngine.shared.createSession()
        RimeEngine.shared.cleanupAllSessions()
        #expect(old.isInvalidated && !old.isAlive)
        let fresh = try RimeEngine.shared.createSession()
        // Using or releasing the stale wrapper must not affect the new session.
        old.simulate(keySequence: "ni")
        #expect(fresh.input.isEmpty)
        fresh.simulate(keySequence: "ni")
        #expect(fresh.input == "ni")
    }
}

extension RimeKitTests {
    /// Regression: deploying a frontend config right after `initialize` (before any
    /// maintenance run) used to fail with "unknown deployment task: config_file_update".
    @Test func deploysFrontendConfigWithoutPriorMaintenance() throws {
        let workspace = Self.workspace
        try "config_version: \"1\"\nstyle:\n  font_point: 18\n".write(
            to: workspace.shared.appendingPathComponent("aime.yaml"), atomically: true, encoding: .utf8)
        let engine = RimeEngine.shared
        engine.finalize()
        engine.initialize(RimeTraits(sharedDataDir: workspace.shared, userDataDir: workspace.user, minLogLevel: 2))
        #expect(engine.deployConfigFile("aime.yaml"))
        #expect(try engine.openConfig("aime").int("style/font_point") == 18)
    }
}

extension RimeKitTests {
    /// Regression: notifications must never be delivered synchronously from inside a
    /// librime call — a handler calling back into the client app from there deadlocked
    /// InputMethodKit (activateServer → set_option → notification → client query).
    @Test func notificationsAreDeliveredAsynchronously() async throws {
        let session = try RimeEngine.shared.createSession()
        var delivered = false
        RimeEngine.shared.notificationHandler = { _ in delivered = true }
        defer { RimeEngine.shared.notificationHandler = nil }
        session.setOption("ascii_mode", !session.option("ascii_mode"))
        #expect(delivered == false, "handler ran synchronously inside set_option")
        for _ in 0..<50 where !delivered { try await Task.sleep(for: .milliseconds(10)) }
        #expect(delivered)
    }
}

extension RimeKitTests {
    /// Regression: sync used to fail with "unknown deployment task: user_dict_sync"
    /// because the deployer module was not loaded.
    @Test func syncUserDataRunsAndWritesSnapshotFolder() throws {
        let workspace = Self.workspace
        let engine = RimeEngine.shared
        engine.finalize()
        engine.initialize(RimeTraits(sharedDataDir: workspace.shared, userDataDir: workspace.user, minLogLevel: 2))
        #expect(engine.syncUserData())
        engine.joinMaintenance()
        let sync = workspace.user.appendingPathComponent("sync")
        #expect(FileManager.default.fileExists(atPath: sync.path))
    }
}
