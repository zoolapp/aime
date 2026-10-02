# AIME 宣传素材

当前首选主图：**中文常新，自在表达。** 副文案采用两层排版：朱红「开源｜隐私」，墨黑「AI 时代的输入法」，AI 下方用短朱红线强调。保留用户指定的斜侧笔记本场景，界面随屏幕倾斜，介绍整体产品定位。

| 文件 | 尺寸 | 用途 |
| --- | --- | --- |
| [hero-v4.jpg](hero-v4.jpg) / [原图 PNG](hero-v4.png) | 1774×887 | 当前中英 README 头图、X 单图及 GitHub Social preview；JPEG 260 KB |
| [hero-v3.jpg](hero-v3.jpg) / [原图 PNG](hero-v3.png) | 1774×887 | 上一版正视显示器场景，保留修订记录 |
| [hero-v2.jpg](hero-v2.jpg) / [原图 PNG](hero-v2.png) | 1774×887 | 上一版交互场景，保留修订记录；透视与功能副标题已由 v3 修正 |
| [github-social.png](github-social.png) / [SVG](github-social.svg) | 1280×640 | 旧版中文文字卡备选 |
| [github-social-en.png](github-social-en.png) / [SVG](github-social-en.svg) | 1280×640 | 旧版英文文字卡备选 |
| [x-social.png](x-social.png) / [SVG](x-social.svg) | 1200×630 | 旧版 X 中文文字卡备选 |
| [x-social-en.png](x-social-en.png) / [SVG](x-social-en.svg) | 1200×630 | 旧版 X 英文文字卡备选 |
| [quiet-desk-concept.png](quiet-desk-concept.png) | 1774×887 | 安静打字场景概念插图，可作为跟帖的第二张图 |
| [video-poster.jpg](video-poster.jpg) | 1920×1080 | 发布短片（39 秒，首帧即品牌页）的封面帧，取自片尾 37.5s；短片源码与分镜见 [assets/video/launch-2026-10-01](../../video/launch-2026-10-01/storyboard.md)，成片（含本地合成配乐与打字音）由 `bash scripts/video/render-launch.sh` 渲染到 `dist/video/`，不入库 |

v4 按用户提供的斜侧笔记本图通过内置 imagegen 编辑；菜单、结果与文字随屏幕角度倾斜，移除连接箭头，文案增加字号、颜色和留白层次。主图通过内置 imagegen 制作，参考现有 Logo 和真实 CandidateView 渲染的快捷菜单／AI 结果。纸签改为朱红正面，保留纸页文化元素。PNG 为生成原图，JPEG 仅做同尺寸格式编码，未裁切、缩放、叠字或修图；JPEG 小于 GitHub Social preview 的 1 MB 限制。图片中标明「界面合成 · 示例内容」，不是实机桌面截图或真实模型请求结果。

原生参考图见 [快捷菜单](hero-v2-references/menu-root-light.png) 与 [AI 结果](hero-v2-references/ai-result-light.png)，内容来自测试中的固定虚构示例。参考图像经生成器重绘，因此不保证最终 UI、Logo 与色值逐像素一致；可见文字和菜单内容已与参考核对。v2／v3／v4 没有 SVG 母版；旧版 SVG 导出脚本不会重建它们。

下列旧版文字卡与无界面场景图保留为备选，主题为「有些话，适合静静打出来」。它们不再作为默认主图。纸白、墨黑、朱红和圆角字签沿用现有品牌母版。旧版中文与英文文字已转为轮廓，SVG 不依赖用户电脑安装字体。图片不承诺当前下载包已公证。

SVG 是可编辑母版；PNG 由母版直接渲染。生成插图不参与这些文字卡片，卡片也不是软件截图。

场景图使用内置 imagegen，以现有纸签材质为参照，原图直接复制保存。它描绘空白纸页、键盘和暗屏笔记本电脑，没有产品 UI 或真实用户输入；发帖时称「概念插图」。其纸签姿态是插图解释，Logo 几何始终以现有矢量母版为准。原图多出植物与笔筒、电脑边缘有裁切，作为场景图使用，不用于功能或几何验收。

重新导出旧版文字卡（在仓库根目录，v2／v3／v4 为独立生成图）：

```bash
bash scripts/brand/fetch-font.sh
swift scripts/brand/export-launch.swift
# sharp 可由本地 node_modules 或 AIME_BRAND_NODE_MODULES 提供。
node scripts/brand/export-launch.mjs
```

字体使用与现有品牌一致的固定 Noto Sans SC，SHA-256 校验在脚本内；字体许可见 [OFL](../../brand/aime/base-v1/licenses/NotoSansSC-OFL.txt)。标志及排版遵循仓库 [MIT](../../../LICENSE)，使用名称和标志不得暗示不存在的官方背书。

中文 alt text：纸白底、朱红字签与 AIME 字标；有些话，适合静静打出来。基于 RIME 的开源 macOS 中文输入法，本地输入、按需 AI、词库订阅更新；0.1.x 开发预览。

English alt text: AIME on a warm ivory card with a vermilion bookmark: Some words, better typed in quiet. Open-source Chinese input for macOS, built on RIME; local input, optional AI and vocabulary subscriptions; developer preview.

场景图 alt text：概念插图：柔和日光下，安静书桌上摆着键盘、暗屏电脑与空白纸页，纸页上放着带朱红薄边的纸签。

v2 alt text：AIME 宣传合成图：Mac 和键盘旁有朱红纸签，屏幕展示选区文字、AIME 快捷菜单以及翻译／润色两条示例结果。中文常新，自在表达；翻译、润色，在光标处完成。

v3 alt text：AIME 宣传合成图：朱红字签与 AIME 字标，中文常新，自在表达；开源、隐私、AI 时代的输入法。正视屏幕展示快捷菜单和示例结果，下方是完整键盘与纸页书签，界面基于原生参考生成。

v4 alt text：AIME 宣传合成图：中文常新，自在表达；朱红小字「开源｜隐私」，墨黑「AI 时代的输入法」带短朱红线。暖色书桌上是斜侧笔记本、前景键盘与纸页书签，屏幕内展示随屏幕倾斜的快捷菜单和示例结果。
