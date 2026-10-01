# RIME 配置项权威参考（AIME 调研文档）

> 适用对象：AIME（基于 librime 的 macOS 输入法 + 可视化配置 App）。
> 事实来源：本机 `~/Library/Rime/` 真实用户配置（雾凇拼音 rime_ice 2025-11-02 版、小鹤双拼方案）、Squirrel 1.1.2 自带 `SharedSupport/` 配置、Rime 官方 Wiki（Configuration / CustomizationGuide / RimeWithSchemata / SpellingAlgebra）、LEOYoon-Tsaw《Rime_description》、librime-lua Wiki。
> 每节末尾用 `catalog: <id>` 标注本文件与 `config/catalog.json` 的交叉引用；「AIME 可视化」标注该项是否已被可视化目录收录（未收录者走「高级 YAML」直接编辑补丁文件）。

## 文件体系与加载顺序

RIME 的配置文件分布在三个位置：

1. **共享目录（shared）**：macOS 上为 `/Library/Input Methods/Squirrel.app/Contents/SharedSupport/`，存放出厂默认配置（`default.yaml`、`squirrel.yaml`、`key_bindings.yaml`、`punctuation.yaml`、`symbols.yaml`、朙月拼音等预设方案、opencc 词典、语法模型）。**不可修改**，升级输入法会被覆盖。
2. **用户目录（user）**：`~/Library/Rime/`，存放用户配置与个性化方案。同名文件若 `config_version` 更高，则整文件覆盖共享目录版本（例如用户目录 `squirrel.yaml` 的 `config_version: '2025-10-23'` 高于出厂的 `'1.0'`，整份生效）。推荐做法是不整文件复制，而是写 `<同名>.custom.yaml` 补丁。
3. **构建目录（build）**：`~/Library/Rime/build/`，部署（Deploy）时 librime 把所有 YAML 编译合并后的产物，运行时只读这里。修改任何源 YAML 后必须「重新部署」才生效。

加载优先级（同名配置源，后者覆盖前者）：

```
SharedSupport/xxx.yaml  →  ~/Library/Rime/xxx.yaml  →  ~/Library/Rime/xxx.custom.yaml (patch)
```

配置层级分三层，逐层合并：

- **default.yaml**：全局默认（schema_list、menu、switcher、ascii_composer、punctuator、recognizer、key_binder）。
- **schema（`<方案名>.schema.yaml`）**：输入方案本体，引用 default 的预设（`import_preset: default`）并可覆盖任何键。
- **前端（`squirrel.yaml` / AIME 的 `aime.yaml`）**：外观与应用级选项，键结构与 squirrel.yaml 相同。

本机实际生效链举例：`default.custom.yaml` 把 `menu/page_size` 从 5 改成 9、`schema_list` 精简为 `[rime_ice, double_pinyin_flypy]`；`squirrel.custom.yaml` 把配色改为 `mac_light` / `mac_dark`。

AIME 可视化：已收录（加载顺序为只读知识；可视化写入的是 `aime.yaml` 与各 `*.custom.yaml`）。
catalog: menu.page_size, switches.emoji

## 编译内嵌与补丁语法（__include / __patch / __append / __merge）

YAML 编译期支持四种合并指令，写在任意映射节点内：

| 指令 | 语义 | 示例 |
|---|---|---|
| `__include: <文件>:/<路径>` | 把另一 YAML 的指定子树包含进来 | `__include: default:/punctuator` |
| `__patch: <文件>:/<路径>` | 用另一文件的子树作为补丁合并到当前节点 | `__patch: key_bindings:/emacs_editing` |
| `__append` / `__prepend` | 向列表追加 / 前插元素 | `__append: [{when: paging, accept: comma, send: Page_Up}]` |
| `__merge` | 把给定映射合并进当前映射 | 较少用，等价于浅合并 |

真实示例（`rime_ice.schema.yaml`）：

```yaml
punctuator:
  __include: default:/punctuator        # 继承全局标点设置
  full_shape:
    __include: default:/punctuator/full_shape
  symbols:
    __include: symbols_v:/symbols        # v 模式符号表
```

而 `*.custom.yaml` 补丁文件只有两类顶层键：

```yaml
patch:
  menu/page_size: 9                      # 斜杠路径定位深层键
  ascii_composer/switch_key/Caps_Lock: commit_text
  "key_binder/bindings":                 # 含特殊字符的路径需加引号
    - { when: always, accept: "Control+Shift+4", toggle: traditionalization }
```

补丁路径中的高级写法（librime ≥ 1.x 支持）：`/+` 追加列表元素、`/@3` 或 `/@last` 定位列表第 N 项（如 `switches/@3/reset: 1` 修改第 4 个开关的默认值）。注意 `patch` 对**列表整体替换**——`rime_ice.custom.yaml` 重写 `speller/algebra` 时必须把原方案的全部规则复制一遍再增删，不能只写增量。

AIME 可视化：高级 YAML（可视化目录只写扁平键值，多规则场景引导用户编辑 `*.custom.yaml`）。
catalog: switches.emoji, spelling.jianpin

## 部署流程与 installation.yaml / user.yaml

「重新部署」= librime 重新编译：解析 default/schema/custom → 应用 `__include`/`__patch`/patch → 编译词典（`.dict.yaml` → build/*.bin）、语法模型、OpenCC → 写入 build/。前端菜单「同步用户数据」则是另一件事（见 userdb 一节）。

`installation.yaml`（每次部署更新）本机实例：

```yaml
distribution_code_name: Squirrel
distribution_name: "鼠鬚管"
distribution_version: 1.1.2
install_time: "Wed Sep 18 15:55:54 2024"
installation_id: "d523dbf9-97a0-4a1f-b6e4-2dbdc72f4e7a"   # 同步目录子目录名
rime_version: 1.16.0
update_time: "Thu Jan 15 09:59:41 2026"
```

- `installation_id`：本机唯一标识，同步时以它为子目录名区分多台设备；可在文件中自定义 `sync_dir`（默认 `~/Library/Rime/sync`）。
- `distribution_*`：发行方信息，写入用户词典快照头部。

`user.yaml`（运行时状态，勿手改）：

```yaml
var:
  last_build_time: 1790578427
  previously_selected_schema: double_pinyin_flypy
  schema_access_time:
    double_pinyin_flypy: 1726647766
```

AIME 可视化：高级 YAML（deployment 由 librime 触发；`sync_dir` 计划放入「高级」页）。
catalog: —（installation.yaml 暂无可视化项）

## Schema 元信息

每个 `*.schema.yaml` 顶部：

```yaml
schema:
  schema_id: rime_ice            # 方案 ID，与文件名、词典名对应
  name: 雾凇拼音                  # 方案选单中显示的名称
  version: "2025-11-02"
  author:
    - Dvel
  description: |
    雾凇拼音
    https://github.com/iDvel/rime-ice
  dependencies:                  # 依赖的其它方案（其词典可被引用）
    - melt_eng                   # 英文输入
    - radical_pinyin             # 部件拆字
```

要点：`schema_id` 决定 build/ 产物文件名与用户词典名（`<schema_id>.userdb`）；`dependencies` 中的方案可以先部署，本方案通过 `table_translator@xxx` + 独立词典引用它们。多方案共库时（小鹤双拼 `dictionary: rime_ice`）必须设 `prism: double_pinyin_flypy` 隔离用户词典。

AIME 可视化：已收录（方案列表读写 `default:/schema_list`）。
catalog: general.schema_list

## switches 开关

方案顶部的可切换选项，出现在「方案选单 / 状态切换菜单」里。雾凇拼音的 6 个开关（rime_ice.schema.yaml:24-38）：

```yaml
switches:
  - name: ascii_mode            # 中西文（内部名）
    states: [ 中, Ａ ]           # 菜单显示名
  - name: ascii_punct
    states: [ ¥, $ ]
  - name: traditionalization
    states: [ 简, 繁 ]
  - name: emoji
    reset: 1                    # 部署后默认值：1=第二个状态（😄 开）
    states: [ 💀, 😄 ]
  - name: full_shape
    states: [ 半角, 全角 ]
  - name: search_single_char
    abbrev: [ 词, 单 ]           # 折叠显示时的缩写
    states: [ 正常, 单字 ]
```

规则：`name` 与 `options`（多选一）二选一——`name` 是二态开关，`options` 是多选（如明月拼音的 `zh_hans/zh_hant/zh_hant_tw`）；`reset` 是部署后的初始状态索引；`states`/`abbrev` 决定菜单显示；`switcher/save_options` 列出的开关会被记忆（见 switcher 节）。opencc 类开关（traditionalization、emoji）由 `simplifier@xxx` 的 `option_name` 关联消费。

AIME 可视化：已收录（常用开关默认值做成 bool）。
catalog: switches.emoji, switches.traditionalization, switches.full_shape, switches.ascii_punct, switches.search_single_char

## engine 总览

`engine:` 定义一条输入处理流水线，四段按序执行（rime_ice.schema.yaml:42-85）：

```yaml
engine:
  processors:     # 按键 → 编辑操作 / 组件调度
    - lua_processor@*select_character
    - ascii_composer
    - recognizer
    - key_binder
    - speller
    - punctuator
    - selector
    - navigator
    - express_editor
  segmentors:     # 输入码 → 分段（tag 标记）
    - ascii_segmentor
    - matcher
    - abc_segmentor
    - affix_segmentor@radical_lookup
    - punct_segmentor
    - fallback_segmentor
  translators:    # 分段 → 候选（按 tag 认领）
    - punct_translator
    - script_translator
    - lua_translator@*date_translator
    - ...
  filters:        # 候选 → 加工（排序/转换/去重）
    - lua_filter@*corrector
    - simplifier@emoji
    - simplifier@traditionalize
    - uniquifier
```

语法要点：`@名字` 挂载具名组件（配置写在顶层同名节点，如 `table_translator@custom_phrase` 读 `custom_phrase:` 节点）；lua 组件用 `lua_xxx@*脚本名`，`*` 表示全局命名空间（所有方案共享，雾凇推荐），`@脚本名@名字空间` 可带独立配置。顺序敏感：processors 中越靠后优先级越低；filters 中越靠前越先看到候选。

AIME 可视化：高级 YAML（流水线结构不开放编辑；翻译器参数见下两节）。
catalog: translator.initial_quality, translator.enable_word_completion

## processors 处理器

按键事件按列表顺序流经各 processor，返回「已消费」即终止。常见组件：

- **ascii_composer**：处理中西文切换键（Shift/CapsLock），决定输入进 ascii 模式还是进拼写区。详见 ascii_composer 节。
- **recognizer**：用 `recognizer/patterns` 正则匹配输入码前缀，命中则打上对应 tag（email、url、punct、reverse_lookup……），后续 segmentor/translator 按 tag 处理。例：`punct: "^v([0-9]|10|[A-Za-z]+)$"` 把 v 开头的输入标记为符号模式。
- **key_binder**：按 `bindings` 把按键翻译成其它按键或动作（翻页、开关切换）。详见 key_binder 节。
- **speller**：把输入码按 `speller/algebra` 规则换算成音节并切分，是拼音类方案的核心。详见 speller 节。
- **punctuator**：在适当时机把标点键转换为标点候选（受 ascii_punct/full_shape 开关控制）。
- **selector**：处理选词键（数字键、空格、alternative_select_keys）。
- **navigator**：光标在拼写区内移动。
- **express_editor / fluid_editor**：编辑已确认的句段。express_editor 直接上屏已确认部分；fluid_editor（旧称）行为不同，雾凇等现代方案统一用 express_editor。
- **lua_processor@\*select_character**：以词定字（按 `[`/`]` 取候选首/尾字）。

AIME 可视化：已收录（以词定字键、翻页键；其余高级 YAML）。
catalog: key_binder.select_first_character, key_binder.select_last_character, keys.paging_minus_equal

## segmentors 分段器

把输入串切成带 tag 的段落，各 translator 只翻译自己 tag 的段：

- **ascii_segmentor**：西文模式整段成 ascii 段。
- **matcher**：匹配 recognizer 打出的前缀模式（url、email 等）。
- **abc_segmentor**：按 speller 切分出的音节边界分段（拼音主体）。
- **affix_segmentor@radical_lookup**：识别反查前缀（如 `uU` 部件拆字）。
- **punct_segmentor**：标点段。
- **fallback_segmentor**：兜底，把剩余输入逐字成段。

一般无需调整；新增「xx 模式」时需在 recognizer、segmentors、translators 三处配套注册。

AIME 可视化：高级 YAML（仅暴露 v 模式前缀）。
catalog: recognizer.punct_prefix

## translators 翻译器

按 tag 认领分段并产出候选。主要类型与本机实例：

- **script_translator**：音节表驱动的主翻译器，读 `<translator>` 节点（dictionary: rime_ice），支持组句、调频、用户词典。
- **table_translator**：码表翻译器（固定编码查表），实例：`table_translator@custom_phrase`（自定义短语，initial_quality: 99 顶到最前）、`table_translator@melt_eng`（英文混输）、`table_translator@cn_en`（汉英词典，db_class: stabledb 只读大库）。
- **reverse_lookup_translator / reverse_lookup_filter**：反查（用另一种编码查主词典，或给候选注音）。雾凇用 `affix_segmentor@radical_lookup` + `table_translator@radical_lookup`（prefix: `"uU"`）+ `reverse_lookup_filter@radical_reverse_lookup` 实现部件拆字反查与注音。
- **punct_translator**：标点/符号候选，读 `punctuator` 配置与 symbols 表。
- **echo_translator**：把输入原样回显为候选（常配 recognizer 的 email/url tag，让网址可直接上屏）。
- **history_translator**：最近上屏内容重复输入。
- **lua_translator@\*…**：Lua 脚本翻译器，本机挂载了 date_translator、lunar、uuid、unicode、number_translator、calc_translator、force_gc（见 Lua 节）。

AIME 可视化：部分已收录（主翻译器参数）。
catalog: translator.enable_word_completion, translator.spelling_hints, translator.always_show_comments, translator.initial_quality, translator.contextual_suggestions

## translators 常用参数

`script_translator` / `table_translator` 支持的常用参数（以雾凇实际配置为例）：

| 参数 | 含义 | 本机值（rime_ice 主翻译器） |
|---|---|---|
| `dictionary` | 主词典名（`<name>.dict.yaml`） | `rime_ice` |
| `prism` | 多方案共库时的用户词典隔离名 | 双拼方案设 `double_pinyin_flypy` |
| `enable_user_dict` | 是否启用用户词典（调频/造词） | 默认 true；melt_eng 设为 false |
| `enable_sentence` | 是否组句（table_translator 应关） | melt_eng/cn_en/custom_phrase 均 false |
| `enable_completion` | 输入中按前缀补全码表词 | cn_en 为 true |
| `enable_word_completion` | 长词自动补全（librime > 1.11.2） | true |
| `initial_quality` | 候选初始权重（决定各翻译器间排序） | 主 1.2 / melt_eng 1.1 / cn_en 0.5 / custom_phrase 99 |
| `spelling_hints` | 候选注释带 N 位拼写提示（corrector 依赖） | 8 |
| `always_show_comments` | 无注释时也显示编码注释 | true |
| `preedit_format` | 输入码显示形态换算（v→u 等） | `xform/([jqxy])v/$1u/` 等 4 条 |
| `comment_format` | 注释显示形态换算 | 加全角方括号 `xform/^/［/`、`xform/$/］/`；melt_eng 用 `xform/.*//` 清空 |
| `contextual_suggestions` | 结合上下文的语言模型建议（octagram） | 双拼方案经 `__include: octagram` 开启 true |
| `max_homophones` / `max_homographs` | 语言模型同音/同形候选上限 | 7 / 7 |

语言模型（octagram grammar）配置（double_pinyin_flypy.schema.yaml 末尾）：

```yaml
__include: octagram            # 引入语言模型预设
octagram/__patch:
  grammar:
    language: wanxiang-lts-zh-hans     # 对应 wanxiang-lts-zh-hans.gram
    collocation_max_length: 5
    collocation_min_length: 2
  translator:
    contextual_suggestions: true
```

`.gram` 模型文件放用户目录（本机 206MB 的 `wanxiang-lts-zh-hans.gram`），可显著改善长句首选准确率。

AIME 可视化：已收录（主翻译器 4 项 + 语法模型开关）。
catalog: translator.enable_word_completion, translator.spelling_hints, translator.always_show_comments, translator.initial_quality, translator.contextual_suggestions, grammar.language

## filters 过滤器

对候选流做转换/排序/过滤，按列表顺序执行：

- **simplifier@xxx**：OpenCC 简繁/emoji 转换。`simplifier@emoji`（option_name: emoji，opencc_config: emoji.json，inherit_comment: false）把候选经 emoji 映射多一份；`simplifier@traditionalize`（option_name: traditionalization，opencc_config: s2t.json，可选 s2hk/s2tw/s2twp，tips: none，tags 限定作用段）实现繁体输出。
  catalog: traditionalize.opencc_config（设置 › 输入习惯 › 简繁体 › 繁体标准）。「默认输出」简体/繁体不写配置：AIME 在每个新会话上设置 `traditionalization` 开关（`aime/features.json` 的 `traditional`）。
- **uniquifier**：去除完全相同的候选（一般放在 filters 最后）。
- **charset_filter**（librime 内置，需配合 extended_charset 开关）：过滤字符集外汉字，雾凇未用（以 8105 字表词库代替）。
- **single_char_filter**：只留单字候选（雾凇用 `search_single_char` 开关 + search.lua 实现类似能力，未用内置组件）。
- **lua_filter@\*…**：本机挂载——corrector（错音提示）、autocap_filter（英文大写）、v_filter（v 模式符号优先）、pin_cand_filter（置顶候选）、long_word_filter（长词优先）、reduce_english_filter（英文降频）、search@radical_pinyin（辅码过滤）。

AIME 可视化：部分已收录（置顶/长词/英文降频为高级 YAML；emoji、繁体走 switches）。
catalog: switches.emoji, switches.traditionalization

## speller 与拼写运算 algebra

`speller:` 定义拼写规则，拼音类方案核心：

```yaml
speller:
  alphabet: zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA`   # 合法输入字符（含 ` 辅码引导符）
  initials: ...            # 可作为音节开头的字符（比 alphabet 少 `，使单个 ` 直接上屏）
  delimiter: " '"          # 音节分隔符：空格与单引号
  algebra:                 # 拼写运算规则（核心）
    ...
```

**拼写运算（Spelling Algebra）** 六种算子，把词典中的标准拼音换算成用户实际击键序列：

| 算子 | 语义 | 示例 |
|---|---|---|
| `xlit/A/B/` | 字符一一转写 | `xlit/āḃçď…/ABCD…/` |
| `xform/re/repl/` | 正则替换（不可逆） | 双拼 `xform/iu$/Ⓠ/` |
| `derive/re/repl/` | 派生（原式与新式并存） | `derive/^([zcs])h/$1/` 模糊音 |
| `abbrev/re/repl/` | 略写（参与简拼、低权重） | `abbrev/^([a-z]).+$/$1/` 超级简拼 |
| `erase/re/` | 该拼写不出词 | `erase/^xx$/` |
| `fuzz/re/repl/` | 模糊匹配（可跨音节） | 较少用，效果近似 derive 但更宽 |

典型应用（全部取自本机真实配置）：

- **模糊音**（rime_ice.custom.yaml 启用）：`derive/^([zcs])h/$1/`（zh/ch/sh→z/c/s）、`derive/^([zcs])([^h])/$1h$2/`（反向）、`derive/^n/l/`、`derive/^l/n/`、`derive/^f/h/`、`derive/^h/f/`。
- **超级简拼**：`erase/^hm$/`（屏蔽特例）+ `abbrev/^([a-z]).+$/$1/` + `abbrev/^([zcs]h).+$/$1/`（各音节取首字母）。
- **v/u 容错**：`derive/^([jqxy])v/$1u/`、`derive/^([nl])ue$/$1ve/` 等 4 条。
- **自动纠错**：`derive/^([wghk])ai$/$1ia/`（wia→wai）、`derive/([wrtypsdfghklzcbnm])ang$/$1nag/` 等数十条（rime_ice.schema.yaml:296-440）。
- **双拼映射**（小鹤）：`xform/^sh/Ⓤ/`、`xform/iu$/Ⓠ/` 等把韵母映射到带圈占位符，最后 `xlit/ⓆⓌⓇ…/qwrtyui…/` 转写到实际键位；`derive/^([aoe])([ioun])$/$1$1$2/` 处理零声母双写。

注意：custom patch 替换 `algebra` 是整个列表替换；改动后必须重新部署（词典需按新拼写重编译）。

AIME 可视化：已收录（常用模糊音/简拼做成 bool 开关，自动注入 algebra 规则）。
catalog: spelling.fuzzy.zh_z, spelling.fuzzy.z_zh, spelling.fuzzy.n_l, spelling.fuzzy.l_n, spelling.fuzzy.f_h, spelling.fuzzy.h_f, spelling.fuzzy.en_eng, spelling.fuzzy.in_ing, spelling.jianpin, spelling.uv_compat, spelling.auto_correct

## punctuator 与 symbols 符号表

`punctuator:` 控制标点输出，三套映射：`full_shape`（全角）、`half_shape`（半角，中文标点习惯）、`ascii_style`（西文标点，预设文件中）。条目三种形式：

```yaml
full_shape:
  '.' : { commit: 。 }            # commit：直接上屏
  '<' : [ 《, 〈, «, ‹ ]           # 列表：给候选
  "'" : { pair: [ '‘', '’' ] }     # pair：成对符号自动交替
```

- `punctuator/digit_separators: ",.:"`：数字中间的这些符号不转标点（输入 3.14 直接得 3.14）。
- **symbols 表**：v 模式符号。雾凇 `punctuator/symbols: __include: symbols_v:/symbols`，条目形如 `'vsz': [ ⚀⚁⚂⚃⚄⚅ ]`、`'va': [ā, á, ǎ, à]`；配合 `recognizer/patterns/punct: "^v([0-9]|10|[A-Za-z]+)$"`（把默认 `/` 前缀改为 v；双拼方案用 symbols_caps_v.yaml 的大写 V 避免与编码冲突）。
- 全局 default.yaml 内联了完整 full/half_shape（如 `,`→`，`、`[`→`[ 「, 【, 〔, ［ ]`、`'`→pair 引号）；Squirrel 出厂版则 `__include: punctuation:/full_shape`。

AIME 可视化：部分已收录（digit_separators；符号表本体为高级 YAML）。
catalog: punctuator.digit_separators

## key_binder 按键绑定

```yaml
key_binder:
  import_preset: default
  bindings:
    - { when: composing, accept: Tab, send: Shift+Right }       # 键映射：按 Tab 当作 Shift+Right
    - { when: paging, accept: minus, send: Page_Up }            # 翻页
    - { when: has_menu, accept: equal, send: Page_Down }
    - { when: always, accept: "Control+Shift+4", toggle: traditionalization }  # 切换开关
    - { when: always, accept: "Control+Shift+1", select: .next }               # 选下一个方案
```

- **when 条件**：`composing`（有输入码）、`has_menu`（有候选）、`paging`（翻过多页）、`always`（任意时刻）。
- **动作**：`accept: 按键名`（捕获的键）、`send: 按键名`（改发其它键）、`toggle: 开关名`（切换 switches 中的开关）、`select: 方案ID或.next`（切换输入方案）。
- **editor/bindings**（schema 内）：编辑键，如 `space: confirm`、`Return: commit_raw_input`、`Control+BackSpace: back_syllable`、`Escape: cancel`。
- **以词定字**：`key_binder/select_first_character: bracketleft`、`select_last_character: grave`（本机 custom 把尾字键从 `]` 改成了 `` ` ``），由 lua_processor@select_character 消费。
- 出厂预设集中在 `key_bindings.yaml`：emacs_editing、paging_with_minus_equal、paging_with_comma_period、paging_with_brackets、numbered_mode_switch、windows_compatible_mode_switch 等，用 `bindings/__patch: key_bindings:/xxx` 引入。

AIME 可视化：已收录（翻页方式、以词定字、开关切换热键）。
catalog: key_binder.select_first_character, key_binder.select_last_character, keys.paging_minus_equal, keys.paging_comma_period, keys.paging_brackets, keys.toggle_ascii_punct, keys.toggle_traditionalization, keys.tab_move_by_word

## ascii_composer 中西文切换

```yaml
ascii_composer:
  good_old_caps_lock: true       # true=CapsLock 直接切西文；false=CapsLock 作为「大写临时西文+回车上屏」
  switch_key:
    Caps_Lock: commit_code       # 本机 custom 值；出厂为 clear
    Shift_L: commit_code         # 左 Shift：上屏输入码并切西文
    Shift_R: noop
    Control_L: noop
    Control_R: noop
    Eisu_toggle: clear           # 日文键盘英数键
```

`switch_key` 各键取值含义：

| 值 | 行为 |
|---|---|
| `inline_ascii` | 进入临时西文（编辑区内联），回车上屏后回中文 |
| `commit_text` | 上屏已组好的文字并切西文 |
| `commit_code` | 上屏原始输入码并切西文 |
| `noop` | 该键不处理（交还给系统） |
| `clear` | 清除输入并切西文 |

`good_old_caps_lock: true` 时 CapsLock 表现为老式大写锁（按下即西文）；false 时 CapsLock 进入「首字母大写模式」，回车上屏后自动回中文。

AIME 可视化：已收录。
catalog: ascii_composer.good_old_caps_lock, ascii_composer.caps_lock, ascii_composer.shift_l, ascii_composer.shift_r, ascii_composer.control_l, ascii_composer.control_r

## switcher 方案选单

`default.yaml` / `default.custom.yaml` 中：

```yaml
switcher:
  caption: 「方案选单」
  hotkeys:
    - Control+Shift+grave        # 本机只留这一个；出厂还有 F4、Control+grave
  save_options:                  # 切换方案后要「记忆」的开关
    - full_shape
    - ascii_punct
    - traditionalization
    - emoji
  fold_options: true             # 开关多时在选单中折叠
  abbreviate_options: true       # 用 switches 的 abbrev 缩写显示
  option_list_separator: ' / '
```

- `hotkeys`：唤出方案选单的热键列表。
- `save_options`：列出的开关状态会被记忆到用户词典，重启/切方案后保持；不在列表中的开关每次回到 `reset` 值。
- `fold_options` / `abbreviate_options`：控制选单中开关的折叠与缩写显示。

AIME 可视化：已收录。
catalog: switcher.hotkeys, switcher.save_options, switcher.fold_options, switcher.caption

## menu 候选菜单

```yaml
menu:
  page_size: 9                                # 每页候选数（1–10，默认 5，本机 custom 改 9）
  # alternative_select_labels: [①②③…]         # 自定义候选序号标签
  # alternative_select_keys: ASDFGHJKL         # 自定义选词键
```

- `page_size`：最常用项，决定每页候选个数与数字键数量。
- `alternative_select_keys`：除数字外的第二组选词键（stringList 逐字符）。
- `alternative_select_labels`：候选前的序号显示字符。

AIME 可视化：已收录。
catalog: menu.page_size, menu.alternative_select_keys

## recognizer 模式识别

`recognizer/patterns:` 用正则把输入码打 tag，供 segmentor/translator 分流：

default.yaml（全局）：
```yaml
recognizer:
  patterns:
    email: "^[A-Za-z][-_.0-9A-Za-z]*@.*$"
    url: "^(www[.]|https?:|ftp[.:]|mailto:|file:).*$|^[a-z]+[.].+$"
    underscore: "^[A-Za-z]+_.*"
    # uppercase: "[A-Z][-_+.'0-9A-Za-z]*$"   # 出厂有，大写开头临时英文
```

rime_ice.schema.yaml（方案级，先 `import_preset: default` 再补充）：
```yaml
recognizer:
  patterns:
    punct: "^v([0-9]|10|[A-Za-z]+)$"        # v 模式符号
    radical_lookup: "^uU[a-z]+$"            # 部件拆字
    unicode: "^U[a-f0-9]+"                  # Unicode 输出
    number: "^R[0-9]+[.]?[0-9]*"            # 数字大写
    calculator: "^cC.+"                     # 计算器
    gregorian_to_lunar: "^N[0-9]{1,8}"      # 公历转农历
```

每个模式通常三件套：pattern（打 tag）→ affix/matcher segmentor（分段）→ 对应 translator（产出候选）。双拼方案把 punct 改为大写 `^V…$` 避开编码。

AIME 可视化：高级 YAML（punct 前缀为计划项）。
catalog: recognizer.punct_prefix

## 词典 dict.yaml 与 custom_phrase

`rime_ice.dict.yaml` 头部（词典定义文件）：

```yaml
# Rime dictionary
---
name: rime_ice                  # 词典名，translator/dictionary 引用它
version: "2024-11-27"
import_tables:                  # 引入其它码表（重复词条最上面的权重生效）
  - cn_dicts/8105               # 通用规范汉字表
  - cn_dicts/base
  - cn_dicts/ext
  - cn_dicts/tencent            # 腾讯词向量大词库
  - cn_dicts/others
  - cn_dicts/zhwiki
  - luolei_dicts/luolei         # 本机用户自定义词库
...
```

dict.yaml 支持的头部键：`name`、`version`、`sort`（by_weight / original）、`use_preset_vocabulary`（引入八股文预设词频）、`import_tables`（合并码表）、`columns`（码表列定义，默认 `text/code/weight`）、`encoder`（形码造词规则）。正文为 Tab 分隔的 `词条 编码 [权重]`，一词多码重复多行。

`custom_phrase.txt`（自定义短语，table_translator 直读，不走编译）：

```
#@/db_name custom_phrase.txt
#@/db_type tabledb
噷	hm
有	u	3
Amazon	amazon
```

格式 `词汇<Tab>编码<Tab>权重`（权重可省）。配置侧：`table_translator@custom_phrase` 设 `user_dict: custom_phrase`、`db_class: stabledb`（只读、不调频；改 tabledb 可调频）、`initial_quality: 99`（压过一切候选）。双拼方案改用 `custom_phrase_double.txt`。

AIME 可视化：部分已收录（custom_phrase 计划做编辑器；词库管理为高级 YAML）。
catalog: advanced.custom_phrase_path

## userdb 用户词典与同步

- **用户词典**：`<schema_id>.userdb/` 目录，LevelDB 格式（`*.ldb` 数据文件、`MANIFEST-*`、`CURRENT`、`LOG`），记录用户造词与动态调频。schema 设 `prism` 后目录名为 `<prism>.userdb`。
- **同步**：前端菜单「同步用户数据」把用户词典导出为文本快照（`sync/<installation_id>/rime_ice.userdb.txt`，809KB）并合并其它设备快照。`installation.yaml` 可设：
  - `sync_dir: "/path/to/dir"`：同步根目录（可指向 iCloud/Dropbox/NAS 做多端同步），默认 `~/Library/Rime/sync`。
  - `installation_id: "我的Mac"`：本机标识，快照按它分子目录。
- 同步是「快照合并」而非实时同步：词频按设备合并取最新/最高，删除不传播（librime 同步语义）。
- 本机 `sync/d523dbf9-…/` 内除 userdb 快照外还备份了 schema/custom_phrase 等配置文件。

AIME 可视化：高级 YAML（sync_dir 写入 installation.yaml，不属 default/schema/frontend 三类，故不入目录）。
catalog: —（installation.yaml 暂无可视化项）

## 前端 squirrel.yaml：style 外观

AIME 的前端配置文件为 `aime.yaml`，键结构与 `squirrel.yaml` 完全相同（本节以 squirrel 为准）。顶层键：`config_version`（须高于出厂版本才生效）、`keyboard_layout: last`（last/default/布局 ID）、`chord_duration: 0.1`（和弦秒数）、`show_notifications_when: appropriate`（always/never/appropriate）、`style`、`preset_color_schemes`、`app_options`。

`style:` 全字段（出厂默认 + 实际用法）：

| 字段 | 默认 | 说明 |
|---|---|---|
| `color_scheme` / `color_scheme_dark` | native | 浅色/深色模式配色方案名（对应 preset_color_schemes 键名） |
| `candidate_list_layout` | stacked | 候选排列：`stacked` 竖排 / `linear` 横排（`horizontal` 键自 1.0.1 移除） |
| `text_orientation` | horizontal | 文字方向 horizontal / vertical |
| `inline_preedit` | true | 输入码内联在编辑区 |
| `inline_candidate` | false | 首选候选内联预上屏 |
| `memorize_size` | true | 记住候选窗大小 |
| `mutual_exclusive` | false | 各外观选项互斥（高度由内容决定） |
| `translucency` | false | 半透明毛玻璃 |
| `show_paging` | false | 显示翻页指示 |
| `corner_radius` | 7 | 候选窗圆角（配色方案里的同名键优先） |
| `aime/max_width` | 640 | **AIME 扩展**：候选窗最大宽度（点）。只约束长候选：单个候选超出时以省略号截断，含长候选的一页超出时换行；普通候选（每个不超过该值的 1/3）一页始终一行，仅受屏幕宽度 90% 限制；0 表示单个候选仅受屏幕宽度 60% 限制（参考 Weasel `max_width`） |
| `aime/corner_radius` | 10 | **AIME 扩展**：优先于配色方案的圆角；设置 App 的「候选窗圆角」写这里，0 为直角。未设置时圆角不低于 8pt（高亮不低于 5pt） |
| `hilited_corner_radius` | 0 | 高亮候选圆角 |
| `aime/hilited_corner_radius` | 6 | **AIME 扩展**：优先于配色方案的高亮圆角 |
| `surrounding_extra_expansion` | 0 | 高亮块四周额外扩张 |
| `border_height` / `border_width` | -2 | 边框高/宽（负值为内缩） |
| `line_spacing` | 5 | 候选行距 |
| `spacing` | 8 | 候选间距 |
| `base_offset` | 0 | 文字基线微调 |
| `shadow_size` | 0 | 阴影大小 |
| `alpha` | 1 | 整体不透明度 0–1（用户自定义方案中常见） |
| `font_face` / `font_point` | 'Avenir' / 16 | 候选字体与字号 |
| `label_font_face` / `label_font_point` | 同上 | 序号标签字体 |
| `comment_font_face` / `comment_font_point` | 同上 | 注释字体 |
| `candidate_format` | `'[label]. [candidate] [comment]'` | 候选格式串；现代写法 `"%c\u2005%@\u2005"`（%c=候选 %@=注释） |

AIME 可视化：已收录（appearance 组全部 style 字段）。
catalog: appearance.color_scheme, appearance.color_scheme_dark, appearance.candidate_list_layout, appearance.text_orientation, appearance.inline_preedit, appearance.inline_candidate, appearance.corner_radius, appearance.hilited_corner_radius, appearance.max_width, appearance.border_height, appearance.border_width, appearance.line_spacing, appearance.spacing, appearance.base_offset, appearance.shadow_size, appearance.alpha, appearance.translucency, appearance.mutual_exclusive, appearance.memorize_size, appearance.show_paging, appearance.font_face, appearance.font_point, appearance.label_font_face, appearance.label_font_point, appearance.comment_font_face, appearance.comment_font_point, appearance.candidate_format

## preset_color_schemes 配色方案

`preset_color_schemes:` 下每个键是一套方案，内置 21 套（native、aqua、azure、luna、ink、lost_temple、dark_temple、psionics、purity_of_form、purity_of_essence、starcraft、google、solarized_rock、clean_white、apathy、dust、mojave_dark、solarized_light、solarized_dark、retro_green、retro_orange）。本机用户新增/覆盖 16 套（mac_light、mac_dark、macos_light、macos_dark、wechat_light/dark、mac_green/orange/blue、win10、milan、purity、nord_light/dark、google、apathy 等）。

单套方案全部颜色键（以 solarized_light 为例，squirrel.yaml:317-334）：

```yaml
solarized_light:
  name: 曬經・日／Solarized Light
  author: 雪齋 <lyc20041@gmail.com>
  color_space: display_p3              # srgb | display_p3（macOS 10.12+）
  back_color: 0xF0E5F6FB               # 窗口背景
  border_color: 0xEDFFFF               # 边框
  preedit_back_color: 0x403516         # 内联预编辑区背景
  text_color: 0xA1A095                 # 预编辑输入码文字
  hilited_text_color: 0x2C8BAE         # 已选中文字（内联部分）
  hilited_back_color: 0x4C4022         # 已选中文字背景
  candidate_text_color: 0x595E00       # 候选文字
  candidate_back_color: 0xFFFFFF       # 候选背景（可省略）
  label_color: 0xA36407                # 候选序号
  comment_text_color: 0x005947         # 注释文字
  hilited_candidate_text_color: 0x3942CB   # 高亮候选文字
  hilited_candidate_back_color: 0xD7E8ED   # 高亮候选背景
  hilited_candidate_label_color: 0x2566C6  # 高亮候选序号
  hilited_comment_text_color: 0x8144C2     # 高亮候选注释
```

**颜色格式（重要）**：`0x` 前缀十六进制，**顺序为 BGR**——24 位 `0xBBGGRR`，32 位 `0xAABBGGRR`（A=alpha）。即文件注释所称「BGR顺序」，与常见 RGB 相反；写可视化取色器时必须做通道转换。（部分第三方主题沿用 weasel 键名 horizontal/margin_x 等，Squirrel 不识别。）

AIME 可视化：已收录（自定义方案 aime_custom 的核心颜色键）。
catalog: appearance.custom.back_color, appearance.custom.border_color, appearance.custom.text_color, appearance.custom.candidate_text_color, appearance.custom.label_color, appearance.custom.comment_text_color, appearance.custom.hilited_candidate_back_color, appearance.custom.hilited_candidate_text_color, appearance.custom.hilited_candidate_label_color, appearance.custom.hilited_comment_text_color

## app_options 应用级选项

按 App 的 Bundle ID 覆盖行为（default/custom 中均支持 patch）：

```yaml
app_options:
  com.microsoft.VSCode:
    ascii_mode: true        # 进入该 App 默认西文
    vim_mode: true          # 跟随 vim 模式自动切中英（需 App 支持）
  com.apple.Terminal:
    ascii_mode: true
    no_inline: true         # 禁用内联预编辑（终端兼容）
  com.google.Chrome:
    inline: true            # 强制内联（规避 squirrel#435 双上屏）
```

可用键：`ascii_mode`、`ascii_punct`、`inline` / `no_inline`（互斥）、`vim_mode`。

AIME 可视化：部分已收录（计划做 App 列表编辑器）。
catalog: advanced.app_options

## Lua 扩展机制与雾凇常用脚本

librime-lua 允许在 engine 中以 `lua_processor@*name` / `lua_translator@*name` / `lua_filter@*name` / `lua_segmentor@*name` 挂载 `lua/name.lua`；`*` 前缀表示全局命名空间，方案间共享。脚本内可用完整 RIME API（Candidate、Preedit、CommitHistory 等）。

本机 lua/ 目录脚本一览（挂载情况以 rime_ice.schema.yaml 为准）：

| 脚本 | 挂载 | 功能 |
|---|---|---|
| select_character.lua | lua_processor | 以词定字，读 key_binder/select_first/last_character |
| date_translator.lua | lua_translator | rq/sj/xq/dt/ts → 日期时间星期时间戳（双拼用 date/time/week/datetime/timestamp） |
| lunar.lua | lua_translator | `nl` 农历查询；`^N[0-9]{1,8}` 公历转农历 |
| uuid.lua | lua_translator | `uuid` 生成 UUID v4 |
| unicode.lua | lua_translator | `U62fc` 输出 Unicode 字符 |
| number_translator.lua | lua_translator | `R123.45` 数字/金额大写 |
| calc_translator.lua | lua_translator | `cC…` 计算器（内置 sin/pi/random 等），cand.quality=99999 |
| force_gc.lua | lua_translator | 每次翻译 collectgarbage("step") 防内存膨胀 |
| corrector.lua | lua_filter | 错音错字提示（依赖 spelling_hints 注释） |
| pin_cand_filter.lua | lua_filter | 置顶候选，配置 `pin_cand_filter: ["d\t的"]` |
| long_word_filter.lua | lua_filter | 长词优先（count=2, idx=4） |
| reduce_english_filter.lua | lua_filter | 英文候选降频（mode: custom, idx: 2, words 列表） |
| autocap_filter.lua | lua_filter | 英文候选自动首字母大写/全大写 |
| v_filter.lua | lua_filter | v 模式符号候选压过英文单词 |
| search.lua | lua_filter（带命名空间） | 部件拆字辅码查词（` 引导），配合 search_single_char 开关 |
| cold_word_drop/ | processor+filter 套件 | 隐藏/降频词条（Control+j 降频、Control+d 删词），当前方案未挂载 |
| cn_en_spacer / en_spacer / is_in_user_dict / t9_preedit / debuger | 未挂载 | 中英加空格 / 英文补空格 / 用户词标记 / T9 显示 / 调试 |

AIME 可视化：高级 YAML（开关由 switches 组暴露 emoji/traditionalization 等即可）。
catalog: switches.emoji, switches.traditionalization

## catalog.json 字段说明与收录总表

`config/catalog.json` 是 AIME 可视化配置 App 的机器可读目录：

- `groups[]`：分组（general 输入习惯 / switching 中英切换 / spelling 模糊音与拼写 / keys 快捷键 / appearance 外观 / switches 开关默认值 / advanced 高级）。
- `settings[]`：每项含 `id`（点号路径）、`group`、`title`、`description`、`file`（default=default.custom.yaml，schema=当前方案 .custom.yaml，frontend=aime.yaml）、`keypath`（RIME 补丁斜杠路径）、`type`（bool/int/double/string/enum/color/font/hotkey/stringList）、`default`、可选 `min`/`max`/`options`/`doc`（本文档锚点）。
- spelling 组 bool 项附 `algebra: [...]`：开启时向 `speller/algebra` 注入的规则列表。
- keys 组部分 bool 项附 `bindings: [...]`：开启时向 `key_binder/bindings` 追加的绑定。
- 前端项的 keypath 与 squirrel.yaml 相同，写入 aime.yaml。
- color 类型值为 Squirrel 的 `0xAABBGGRR` 格式。

收录总表即 catalog.json 本身；本文各节末尾的 `catalog:` 行为反向索引。

catalog: menu.page_size


---

> **AIME 候选窗当前未实现的 squirrel.yaml 前端选项**（已从可视化目录移除，写入不会生效）：
> `style/text_orientation: vertical`（竖排）、`style/shadow_size`、`style/show_paging`、`style/memorize_size`、
> `style/mutual_exclusive`、`keyboard_layout`、`show_notifications_when`。列入 Roadmap，实现后再加回目录。

## ascii_state（AIME 扩展，aime.yaml）

| 键 | 默认 | 说明 |
|---|---|---|
| `ascii_state/scope` | `global` | 中英状态共享范围：`global` 所有应用共享（参考 Weasel `global_ascii`、fcitx5 ShareInputState=All）；`app` 每个应用分别记忆（ShareInputState=Program）；`window` 每个输入框独立（librime 默认行为） |

`app_options/<bundle id>/ascii_mode: true` 的应用在任何范围下都单独记忆：首次进入为英文，之后保持用户在该应用中的选择，且不影响其他应用。

catalog: ascii_state.scope

