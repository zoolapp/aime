import Testing
@testable import AIMECore

struct DoublePinyinTests {
    let flypy = DoublePinyin.flypy

    @Test func convertsSyllablesToFlypy() {
        let cases: [String: String] = [
            "ni": "ni", "hao": "hc", "zhi": "vi", "neng": "ng", "ti": "ti", "shi": "ui", "jie": "jp",
            "chuang": "il", "xue": "xt", "lv": "lv", "lve": "lt", "ju": "jv", "qu": "qv", "yu": "yv",
            "a": "aa", "e": "ee", "ai": "ai", "an": "an", "ang": "ah", "eng": "eg", "er": "er", "ou": "ou",
            "xiong": "xs", "guang": "gl", "zhuang": "vl", "sheng": "ug", "yuan": "yr", "yun": "yy",
        ]
        for (pinyin, code) in cases {
            #expect(flypy.code(forSyllable: pinyin) == code, "\(pinyin)")
        }
    }

    @Test func convertsPhrases() {
        #expect(flypy.code(forPinyin: "zhi neng ti") == "vingti")
        #expect(flypy.code(forPinyin: "ti shi ci") == "tiuici")
        #expect(flypy.code(forPinyin: "not a syllable xq") == nil)
        #expect(DoublePinyin.layout(forSchema: "double_pinyin_flypy") == .flypy)
    }

    @Test func convertsSyllablesToZiranma() {
        let ziranma = DoublePinyin.ziranma
        let cases: [String: String] = [
            "ni": "ni", "hao": "hk", "jie": "jx", "chuang": "id", "xue": "xt",
            "lv": "lv", "lve": "lt", "ju": "ju", "qu": "qu", "xu": "xu", "yu": "yu",
            "a": "aa", "e": "ee", "ai": "ai", "an": "an", "ang": "ah", "eng": "eg", "er": "er", "ou": "ou",
            "xiong": "xs", "guang": "gd", "zhuang": "vd", "sheng": "ug", "yuan": "yr", "yun": "yp",
            "bin": "bn", "liu": "lq", "shuang": "ud", "jiao": "jc", "gou": "gb", "ying": "yy"
        ]
        for (pinyin, code) in cases {
            #expect(ziranma.code(forSyllable: pinyin) == code, "\(pinyin)")
        }
        #expect(ziranma.code(forPinyin: "xiang liang shu ju ku") == "xdlduujuku")
        #expect(ziranma.code(forPinyin: "ju shen zhi neng") == "juufving")
        #expect(flypy.code(forPinyin: "ju shen zhi neng") == "jvufving")
    }

    @Test func recognizesOnlyKnownDoublePinyinSchemas() {
        #expect(DoublePinyin.layout(forSchema: "double_pinyin") == .ziranma)
        #expect(DoublePinyin.layout(forSchema: "double_pinyin_flypy") == .flypy)
        #expect(DoublePinyin.layout(forSchema: "double_pinyin_custom") == nil)
        #expect(DoublePinyin.layout(forSchema: "double_pinyin_mspy") == nil)
        #expect(DoublePinyin.layout(forSchema: "rime_ice") == nil)
    }
}
