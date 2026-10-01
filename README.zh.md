<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/aime/base-v1/lockup-white.png">
    <img src="assets/brand/aime/base-v1/lockup-color.png" width="300" alt="AIME · 艾么输入法">
  </picture>
</p>

<p align="center"><b>中文常新，自在表达。</b></p>

<p align="center">基于 RIME 的开源 macOS 中文输入法 · 本地优先 · 可选 AI</p>

<p align="center">
  <a href="https://aime.zool.app">官网</a> ·
  <a href="https://github.com/zoolapp/aime/releases">下载</a> ·
  <a href="https://aime.zool.app/docs/">使用文档</a> ·
  <a href="docs/privacy.md">隐私说明</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/zoolapp/aime/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/zoolapp/aime/ci.yml?branch=main&style=flat-square&label=CI" alt="CI"></a>
  <a href="https://github.com/zoolapp/aime/releases"><img src="https://img.shields.io/github/v/release/zoolapp/aime?include_prereleases&style=flat-square&label=release" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2f855a?style=flat-square" alt="MIT"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-111111?style=flat-square&logo=apple" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/librime-1.17-B64032?style=flat-square" alt="librime 1.17">
</p>

<p align="center">
  <img src="assets/screenshots/settings-overview-light.png" width="860" alt="艾么输入法设置 · 概览">
</p>

> [!IMPORTANT]
> **开发预览版。** 正式安装包尚未完成 Developer ID 签名与公证；在此之前，[Releases](https://github.com/zoolapp/aime/releases) 中的安装包为预发布版本，
> 安装说明见下文。AIME 是独立项目，不是鼠须管（Squirrel）的分支，不包含其 GPL 源码，可与鼠须管同时安装。

## 为什么是 AIME

| | |
|---|---|
| **开源，站在 RIME 肩上** | 以 [librime](https://github.com/rime/librime) 为引擎、[雾凇拼音](https://github.com/iDvel/rime-ice) 为默认方案。读取你已有的 RIME 配置，从鼠须管只读导入，一步迁移。AIME 原创代码以 MIT 许可开源。 |
| **你的输入，只在你的 Mac 上** | 打字在本机处理，不写输入日志，不收集、不上传你的输入，没有任何统计上报。常用语与输入统计只存于本机。 |
| **AI 驱动，但由你决定** | 翻译、润色、简繁转换与自定义动作，长按 ⌥ 再按空格即可在光标处完成。默认使用 Apple 端侧模型；只有你主动执行时才处理那一段文字。 |
| **更丝滑的输入** | librime 进程内运行，候选窗原生自绘；开发机实测雾凇拼音单键 p50 0.34 ms / p99 0.61 ms。常用语分类、短语编码、符号板字母直选、高频词置顶。 |

## 功能

- **快捷菜单**：打字时长按 ⌥，空格进入 AI 处理，数字键进入常用语、符号、高频词与设置，全程不离开键盘。
- **AI 处理**：对选中文字、刚打的字或正在选的候选执行翻译、润色、简繁转换，或你自己写提示词的动作（如「粤语」）；结果以候选列表呈现，回车替换。
- **输入图层（可选）**：打出的字先停在光标处，回车上屏，便于整段润色后再发送。
- **可视化设置**：候选数量、中英切换、模糊音、简拼纠错、快捷键、简繁输出、按应用默认中英文等 80 余项，覆盖常用 RIME 配置（[调研文档](docs/rime-config-reference.md)）。
- **外观**：配色画廊与实时预览、字体字号、横排 / 竖排、圆角与间距；可基于任一配色自定义，并提示对比度不足。
- **词库**：官方在线词库目录（版本与 SHA-256 校验，每天 / 每周自动更新），任意 RIME 兼容词表订阅；雾凇、万象、白霜等方案一键安装，冲突先提示。
- **常用语与短语**：分类管理手机号、邮箱、地址等常用内容；表格编辑自定义短语。
- **输入统计（可选，仅本机）**：每日字数、时段与应用分布、高频词，一键置顶为首选。
- **同步与备份**：基于 RIME 同步目录在多台 Mac 间合并词频；一键导出 / 恢复本地备份文件，不经任何云端。
- **首次引导**：从启用输入法到选择全拼 / 双拼、试打示例短语，一分钟完成。
- **命令行**：`aime deploy / bench / doctor / import-squirrel / package / get / set / sync`，便于脚本化与 CI。

<p align="center">
  <img src="assets/screenshots/settings-appearance-dark.png" width="49%" alt="外观（深色）">
  <img src="assets/screenshots/settings-dictionaries-light.png" width="49%" alt="词库">
</p>

## 安装

### 预发布安装包

1. 在 [Releases](https://github.com/zoolapp/aime/releases) 下载最新的 `AIME-<版本>.pkg`，并用同一页面的 `SHA256SUMS.txt` 校验：

   ```bash
   shasum -a 256 -c SHA256SUMS.txt --ignore-missing
   ```

2. 未公证的预发布版本需要右键选择「打开」安装，或先移除隔离属性：`xattr -dr com.apple.quarantine AIME-<版本>.pkg`。
3. 打开 **系统设置 › 键盘 › 输入法 › 编辑…**，点击 **+**，在「简体中文」中添加 **艾么输入法**。首次安装后若未出现，请注销并重新登录。

### 从源码构建

需要 macOS 26+、Xcode 26+ 与 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

```bash
git clone https://github.com/zoolapp/aime.git && cd aime
bash scripts/install-dev.sh
```

脚本会下载并校验固定版本的 librime 与雾凇拼音，构建输入法、设置 App 与命令行工具，安装到 `~/Library/Input Methods/AIME.app` 并注册。

## 从鼠须管迁移

1. 在鼠须管菜单中执行一次「同步用户数据」，使词频快照为最新。
2. 打开艾么输入法设置，在概览页点击「导入」；或使用命令行：

   ```bash
   ~/Library/Input\ Methods/AIME.app/Contents/Helpers/aime import-squirrel --dry-run   # 预览计划
   ~/Library/Input\ Methods/AIME.app/Contents/Helpers/aime import-squirrel
   ```

导入只读，不修改 `~/Library/Rime`。你的 `*.custom.yaml` 原样放入 `~/Library/AIME/Rime/aime/imported/`，界面中的修改写在独立一层并优先生效，可随时恢复。

## 架构

```mermaid
flowchart LR
  subgraph IME["AIME.app · 输入法进程"]
    C[IMKit 控制器] --> R[librime 1.17<br/>+ lua / octagram / predict]
    C --> P[候选窗 · AppKit]
  end
  S["AIME Settings.app · SwiftUI"] -- 写配置层 --> U[(~/Library/AIME/Rime)]
  S -- 部署请求 --> IME
  R --> U
  Sq[(~/Library/Rime · 只读)] -. 导入 .-> U
```

设置 App 不链接 librime，只读写文件，通过分布式通知请求输入法重新部署。每项配置由三层合成：AIME 默认值 → 手写补丁 → 界面修改。详见 [架构说明](docs/architecture.md) 与 [架构决策记录](docs/decisions/)。

## 开发

```bash
bash scripts/fetch-librime.sh && bash scripts/fetch-dicts.sh
swift build --package-path Packages/AIMEKit && bash scripts/stage-plugins.sh
swift test --package-path Packages/AIMEKit
xcodegen generate && open AIME.xcodeproj
```

性能门禁：`aime bench --schema rime_ice --keys nihaoshijie --iterations 2000 --assert-p99-ms 5`。
贡献流程见 [CONTRIBUTING.zh.md](CONTRIBUTING.zh.md)，发布流程见 [docs/releasing.md](docs/releasing.md)，安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## 隐私

日常输入在本机处理，不写输入日志，不上传拼音串、候选列表或用户词频，不包含任何统计或崩溃上报 SDK。订阅在线词库时，输入法按你设定的频率请求公开词表。
只有你主动执行 AI 动作时，目标文字才交给所选模型：默认 Apple 端侧模型在本机运行；若你自行配置云端接口，需单独允许发送文字。详见 [隐私说明](docs/privacy.md)。

## 路线图

- [x] librime 前端、候选窗、命令行、开发安装与 CI
- [x] 可视化设置、外观预览、应用选项、常用语与自定义短语
- [x] 官方在线词库目录、方案包管理（固定版本与 SHA-256）
- [x] 快捷菜单、AI 处理（端侧 / 自备接口）、输入图层
- [x] 输入统计、首次引导、本地备份与恢复
- [ ] Developer ID 签名、公证与自动更新
- [ ] 竖排文字方向、候选窗翻页指示
- [ ] librime 源码可复现构建

## 致谢

[RIME / librime](https://github.com/rime/librime) · [鼠须管](https://github.com/rime/squirrel) · [雾凇拼音](https://github.com/iDvel/rime-ice) · [万象拼音](https://github.com/amzxyz/rime_wanxiang) · [白霜拼音](https://github.com/gaboolic/rime-frost) · [rime-essay](https://github.com/rime/rime-essay) · [OpenCC](https://github.com/BYVoid/OpenCC) · [Yams](https://github.com/jpsim/Yams)

## 许可

AIME 原创代码采用 [MIT](LICENSE) 许可。随应用分发的原生 `librime-octagram` 插件，以及雾凇拼音方案、词表与 Lua 脚本保留 GPL-3.0；
AIME 在线词表采用 CC BY 4.0。其余第三方组件见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，原生插件许可核对见 [插件许可审计](docs/native-plugin-license-audit.md)。
原创代码采用 MIT 不代表整个安装包仅适用 MIT。

<p align="center"><sub>由 <a href="https://zool.app">ZOOL LLC</a> 发布与维护 · 开发者 Luo Lei（<a href="https://github.com/foru17">@foru17</a>）· AIME 与艾么输入法为 ZOOL LLC 的产品名称</sub></p>
