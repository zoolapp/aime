import Foundation
@testable import RimeKit

/// A tiny self-contained Rime workspace so engine tests never touch the network or
/// the developer's own configuration.
enum Fixtures {
    static let defaultYAML = """
    config_version: "test"
    schema_list:
      - schema: test_pinyin
    menu:
      page_size: 5
    ascii_composer:
      switch_key:
        Shift_L: commit_code
        Shift_R: commit_code
    """

    static let schemaYAML = """
    schema:
      schema_id: test_pinyin
      name: 测试拼音
      version: "1"
    switches:
      - name: ascii_mode
        states: [中, A]
    engine:
      processors:
        - ascii_composer
        - key_binder
        - speller
        - punctuator
        - selector
        - navigator
        - express_editor
      segmentors:
        - ascii_segmentor
        - matcher
        - abc_segmentor
        - punct_segmentor
        - fallback_segmentor
      translators:
        - punct_translator
        - script_translator
    speller:
      alphabet: zyxwvutsrqponmlkjihgfedcba
      delimiter: " '"
    translator:
      dictionary: test_pinyin
      enable_user_dict: false
    punctuator:
      half_shape:
        ",": "，"
        ".": "。"
    key_binder:
      bindings:
        - {when: has_menu, accept: minus, send: Page_Up}
        - {when: has_menu, accept: equal, send: Page_Down}
    """

    static let dictYAML = """
    ---
    name: test_pinyin
    version: "1"
    sort: by_weight
    ...
    你\tni\t100
    好\thao\t100
    你好\tni hao\t1000
    世界\tshi jie\t800
    是\tshi\t500
    界\tjie\t50
    """

    /// Creates shared + user dirs under a fresh temporary directory.
    static func makeWorkspace() throws -> (shared: URL, user: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aime-rimekit-\(UUID().uuidString)")
        let shared = root.appendingPathComponent("shared")
        let user = root.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try defaultYAML.write(to: shared.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        try schemaYAML.write(to: shared.appendingPathComponent("test_pinyin.schema.yaml"), atomically: true, encoding: .utf8)
        try dictYAML.write(to: shared.appendingPathComponent("test_pinyin.dict.yaml"), atomically: true, encoding: .utf8)
        return (shared, user)
    }
}
