import Foundation
internal import CRime

public struct RimeCandidate: Sendable, Hashable {
    public let text: String
    public let comment: String

    public init(text: String, comment: String = "") {
        self.text = text
        self.comment = comment
    }
}

/// Immutable copy of librime's composition + menu, safe to hand to UI code.
public struct RimeContextSnapshot: Sendable, Equatable {
    public struct Composition: Sendable, Equatable {
        public var preedit: String
        /// UTF-8 byte offsets as reported by librime.
        public var cursorPosition: Int
        public var selectionStart: Int
        public var selectionEnd: Int

        public init(preedit: String = "", cursorPosition: Int = 0, selectionStart: Int = 0, selectionEnd: Int = 0) {
            self.preedit = preedit
            self.cursorPosition = cursorPosition
            self.selectionStart = selectionStart
            self.selectionEnd = selectionEnd
        }

        /// Converts a UTF-8 byte offset into a UTF-16 offset for AppKit ranges.
        public func utf16Offset(ofUTF8 offset: Int) -> Int {
            let bytes = Array(preedit.utf8)
            let clamped = max(0, min(offset, bytes.count))
            return String(decoding: bytes[0..<clamped], as: UTF8.self).utf16.count
        }
    }

    public var composition: Composition
    public var candidates: [RimeCandidate]
    public var labels: [String]
    public var highlightedIndex: Int
    public var pageNumber: Int
    public var pageSize: Int
    public var isLastPage: Bool
    public var commitTextPreview: String?
    public var input: String

    public init(
        composition: Composition = .init(),
        candidates: [RimeCandidate] = [],
        labels: [String] = [],
        highlightedIndex: Int = 0,
        pageNumber: Int = 0,
        pageSize: Int = 0,
        isLastPage: Bool = true,
        commitTextPreview: String? = nil,
        input: String = ""
    ) {
        self.composition = composition
        self.candidates = candidates
        self.labels = labels
        self.highlightedIndex = highlightedIndex
        self.pageNumber = pageNumber
        self.pageSize = pageSize
        self.isLastPage = isLastPage
        self.commitTextPreview = commitTextPreview
        self.input = input
    }

    public var isComposing: Bool { !composition.preedit.isEmpty || !candidates.isEmpty }
}

public struct RimeStatusSnapshot: Sendable, Equatable {
    public var schemaID: String
    public var schemaName: String
    public var isDisabled: Bool
    public var isComposing: Bool
    public var isASCIIMode: Bool
    public var isFullShape: Bool
    public var isSimplified: Bool
    public var isTraditional: Bool
    public var isASCIIPunct: Bool
}

/// One librime input session (one per client text field context).
@MainActor
public final class RimeSession {
    public let id: UInt
    private unowned let engine: RimeEngine
    private var api: UnsafeMutablePointer<RimeApi_stdbool> { engine.api }

    /// Set when the engine drops all sessions (cleanup / finalize). librime may reuse
    /// session ids afterwards, so a stale wrapper must never touch its old id again.
    public private(set) var isInvalidated = false

    init(id: RimeSessionId, engine: RimeEngine) {
        self.id = UInt(id)
        self.engine = engine
    }

    isolated deinit {
        if !isInvalidated { _ = api.pointee.destroy_session(RimeSessionId(id)) }
    }

    func invalidate() { isInvalidated = true }

    /// 0 is never a valid librime session, so calls on an invalidated wrapper are no-ops.
    private var sid: RimeSessionId { isInvalidated ? 0 : RimeSessionId(id) }

    public var isAlive: Bool { !isInvalidated && api.pointee.find_session(sid) }

    /// Feeds one key event. Returns true when librime consumed it.
    @discardableResult
    public func processKey(_ keycode: Int32, modifiers: Int32 = 0) -> Bool {
        api.pointee.process_key(sid, keycode, modifiers)
    }

    /// Feeds a key sequence in librime notation, e.g. `"nihao{space}"`.
    @discardableResult
    public func simulate(keySequence: String) -> Bool {
        api.pointee.simulate_key_sequence(sid, keySequence)
    }

    /// Pops pending committed text, if any.
    public func consumeCommit() -> String? {
        var commit = RimeCommit()
        commit.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout<Int32>.size)
        guard api.pointee.get_commit(sid, &commit) else { return nil }
        defer { _ = api.pointee.free_commit(&commit) }
        return commit.text.map { String(cString: $0) }
    }

    @discardableResult
    public func commitComposition() -> Bool { api.pointee.commit_composition(sid) }

    public func clearComposition() { api.pointee.clear_composition(sid) }

    public var input: String {
        api.pointee.get_input(sid).map { String(cString: $0) } ?? ""
    }

    public func context() -> RimeContextSnapshot {
        var ctx = RimeContext_stdbool()
        ctx.data_size = Int32(MemoryLayout<RimeContext_stdbool>.size - MemoryLayout<Int32>.size)
        guard api.pointee.get_context(sid, &ctx) else { return RimeContextSnapshot() }
        defer { _ = api.pointee.free_context(&ctx) }

        let composition = RimeContextSnapshot.Composition(
            preedit: ctx.composition.preedit.map { String(cString: $0) } ?? "",
            cursorPosition: Int(ctx.composition.cursor_pos),
            selectionStart: Int(ctx.composition.sel_start),
            selectionEnd: Int(ctx.composition.sel_end)
        )
        let menu = ctx.menu
        var candidates: [RimeCandidate] = []
        candidates.reserveCapacity(Int(menu.num_candidates))
        for index in 0..<Int(menu.num_candidates) {
            let candidate = menu.candidates[index]
            candidates.append(RimeCandidate(
                text: candidate.text.map { String(cString: $0) } ?? "",
                comment: candidate.comment.map { String(cString: $0) } ?? ""
            ))
        }

        var labels: [String] = []
        if let selectLabels = ctx.select_labels {
            for index in 0..<Int(menu.page_size) {
                guard let label = selectLabels[index] else { break }
                labels.append(String(cString: label))
            }
        } else if let keys = menu.select_keys {
            labels = String(cString: keys).map { String($0) }
        }
        if labels.count < candidates.count {
            labels += (labels.count..<candidates.count).map { String(($0 + 1) % 10) }
        }

        return RimeContextSnapshot(
            composition: composition,
            candidates: candidates,
            labels: labels,
            highlightedIndex: Int(menu.highlighted_candidate_index),
            pageNumber: Int(menu.page_no),
            pageSize: Int(menu.page_size),
            isLastPage: menu.is_last_page,
            commitTextPreview: ctx.commit_text_preview.map { String(cString: $0) },
            input: input
        )
    }

    public func status() -> RimeStatusSnapshot? {
        var status = RimeStatus_stdbool()
        status.data_size = Int32(MemoryLayout<RimeStatus_stdbool>.size - MemoryLayout<Int32>.size)
        guard api.pointee.get_status(sid, &status) else { return nil }
        defer { _ = api.pointee.free_status(&status) }
        return RimeStatusSnapshot(
            schemaID: status.schema_id.map { String(cString: $0) } ?? "",
            schemaName: status.schema_name.map { String(cString: $0) } ?? "",
            isDisabled: status.is_disabled,
            isComposing: status.is_composing,
            isASCIIMode: status.is_ascii_mode,
            isFullShape: status.is_full_shape,
            isSimplified: status.is_simplified,
            isTraditional: status.is_traditional,
            isASCIIPunct: status.is_ascii_punct
        )
    }

    public func setOption(_ name: String, _ value: Bool) { api.pointee.set_option(sid, name, value) }
    public func option(_ name: String) -> Bool { api.pointee.get_option(sid, name) }

    public func setProperty(_ name: String, _ value: String) { api.pointee.set_property(sid, name, value) }

    @discardableResult
    public func selectCandidate(onCurrentPage index: Int) -> Bool {
        api.pointee.select_candidate_on_current_page(sid, index)
    }

    @discardableResult
    public func highlightCandidate(onCurrentPage index: Int) -> Bool {
        api.pointee.highlight_candidate_on_current_page(sid, index)
    }

    @discardableResult
    public func deleteCandidate(onCurrentPage index: Int) -> Bool {
        api.pointee.delete_candidate_on_current_page(sid, index)
    }

    @discardableResult
    public func changePage(backward: Bool) -> Bool { api.pointee.change_page(sid, backward) }

    public var currentSchema: String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard api.pointee.get_current_schema(sid, &buffer, buffer.count) else { return nil }
        return String(nullTerminated: buffer)
    }

    @discardableResult
    public func selectSchema(_ schemaID: String) -> Bool { api.pointee.select_schema(sid, schemaID) }

    /// Label for an option state (e.g. "中" / "A" for ascii_mode) as defined in the schema's switches.
    public func stateLabel(option: String, state: Bool, abbreviated: Bool) -> String {
        let slice = api.pointee.get_state_label_abbreviated(sid, option, state, abbreviated)
        guard let str = slice.str, slice.length > 0 else { return "" }
        return str.withMemoryRebound(to: UInt8.self, capacity: slice.length) {
            String(decoding: UnsafeBufferPointer(start: $0, count: slice.length), as: UTF8.self)
        }
    }
}
