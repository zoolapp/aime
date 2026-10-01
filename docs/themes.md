# 主题包与 `aime-ime://` 一键导入

官网 [aime.zool.app/themes/](https://aime.zool.app/themes/) 展示内置主题、提供在线编辑器；每个主题都能生成一个
`aime-ime://theme` 链接，点击后由「AIME 设置」弹出确认，用户同意后写入本机配置并自动部署。本文是两端（App 与官网）共用的合约。

## 主题包（aime-theme v2）

```json
{
  "format": "aime-theme",
  "version": 2,
  "id": "sakura",
  "name": "樱花",
  "author": "AIME",
  "colors": {
    "back_color": "0xF7FFF6F8",
    "border_color": "0x1FC2185B",
    "…": "共 13 个键，见下表"
  }
}
```

| 字段 | 规则 |
|---|---|
| `format` | 必须为 `aime-theme` |
| `version` | `1`（只有颜色）或 `2`（颜色 + 布局）；更高版本提示更新 AIME |
| `id` | `^[a-z][a-z0-9_]{1,31}$`；`aime_custom`（设置里的「我的配色」）保留，拒绝导入 |
| `name` / `author` | 去掉控制字符后 1–40 个字符；`author` 可省略 |
| `colors` | 下列 13 个键**全部必填**，值为 `0xAARRGGBB`（等同 RIME 的 `color_format: argb`），大小写不限，写入时统一为大写 |

颜色键（与鼠须管 / RIME `preset_color_schemes` 同名）：
`back_color` `border_color` `preedit_back_color` `text_color` `hilited_text_color` `hilited_back_color`
`candidate_text_color` `comment_text_color` `label_color` `hilited_candidate_back_color`
`hilited_candidate_text_color` `hilited_comment_text_color` `hilited_candidate_label_color`。

不在表中的键一律丢弃，确认页会提示被忽略的键。

### 布局（v2 `layout`，可选键，单位 pt）

| 键 | 范围 | 含义 |
|---|---|---|
| `corner_radius` / `hilited_corner_radius` | 0–30 | 候选窗圆角 / 高亮圆角（高亮可为 0） |
| `border_width` / `border_height` | 0–30 | 候选窗左右 / 上下内边距；两者都 ≤ 2 时为「填满」高亮，否则为「悬浮」高亮 |
| `spacing` / `line_spacing` | 0–40 | 候选间距 / 行距 |
| `font_point` / `label_font_point` / `comment_font_point` | 10–40 / 8–40 / 8–40 | 候选、序号、注释字号 |

超出范围的值整包拒绝；数值取到 0.5 pt。字体名称、横排 / 竖排、透明度仍由用户决定，主题不包含。

高亮形态（App 与官网预览共用同一规则）：
- **填满**：高亮延伸到候选窗边缘，贴边的角由候选窗圆角裁切，内侧角用 `hilited_corner_radius`；竖排时高亮占满整行。
- **悬浮**：高亮与边缘保持间距；间距小于候选窗圆角一半时与外框同心（`corner_radius − 间距`，最小 2），否则用 `hilited_corner_radius`。

## `aime-ime://` 链接

scheme 用 `aime-ime`（AIME 输入法），而不是常见词 `aime`：多个 App 注册同一 scheme 时 macOS 打开哪个是不确定的。

```
aime-ime://theme?v=2&d=<base64url(规范 JSON)>
```

- `d` 是主题包的**规范 JSON**（键按字典序排序、无空白、UTF-8、`/` 不转义）做 base64url（`-_`，无 `=` 填充）。
  解码端接受任何合法 JSON；规范形式只用于让两端生成的链接逐字一致、便于测试。
- 解码后的 JSON 不超过 4096 字节；`v` 与包内 `version` 一致（1 或 2）。
- 链接是**自包含**的：不含任何需要联网获取的地址，导入过程完全离线。
- 官网分享编辑器状态用 `https://aime.zool.app/themes/editor/#d=<同一 d>`，放在 hash 里，不进服务器日志。

## 导入行为（AIME 设置）

1. 「AIME 设置」注册 `aime-ime` scheme。收到链接后先解码、校验；不合格的链接只提示原因，不写任何文件。
2. 弹出确认页：浅色 / 深色候选窗预览、名称、作者、对比度（低于外观页的可读性阈值时显示警告），
   以及「用于浅色 / 深色 / 两者」（按背景亮度预选）。按钮为「导入并启用」「仅导入」「取消」。
3. 带布局的主题有「同时采用主题的布局」选项（默认勾选），预览随之切换。
4. **只有用户点击后才写入**，并且只写生成层 `aime/generated/aime.yaml` 的这几项：
   - `preset_color_schemes/<id>`：`name`、`author`、`color_format: argb`、13 个颜色与布局键；
   - 「导入并启用」时再写 `style/color_scheme` 和 / 或 `style/color_scheme_dark`；
   - 采用布局时写 `style/aime/<布局键>`（这是「外观」页的设置，优先于任何配色），候选窗因此与官网预览一致。
5. `id` 与内置主题相同（如 `sakura`）时**不写入配色**，只切换为该内置主题。
6. 生成层已有同 `id` 的导入主题时，确认页提示「将替换已有的 X」；取消则文件不变。
7. 写入后照常自动部署，候选窗随即换色；「我的配色」（`aime_custom`）不会被改动。
8. 多个链接排队，一次只显示一个确认页。

## 数据来源与校验

- 内置主题来自 `SharedSupport/aime.yaml` 的 `preset_color_schemes`；`scripts/export-themes.py` 导出官网的
  `src/data/themes.json`（带源文件 SHA-256）和两端测试共用的 fixture（`Tests/AIMECoreTests/Fixtures/theme-v1`）。
- fixture 记录每个主题的规范 JSON、`aime-ime://` 链接和期望的最低文字对比度；Swift 与官网各自的测试都必须与它逐字一致。
- 官网画廊与详情页的预览图由 `scripts/render-themes.sh` 用 App 的候选窗代码渲染（横排、竖排），与安装后看到的一致；
  编辑器的实时预览按同一套几何规则在浏览器里绘制。
- 官网编辑器是纯前端：不发起网络请求，状态只在 URL hash 与浏览器本地存储里。
