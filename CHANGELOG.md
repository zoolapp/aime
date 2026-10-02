# Changelog

All notable changes to AIME will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioned releases are intended to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-10-02

### 修复

- 首次引导「按应用自动切换中英文」：扫描结束后列表可能只剩分隔线、看不到应用与选项，现在总会完整显示。
- 同一步的应用扫描明显变快（扫描动画不再每帧重新读取应用图标，过去两三百个应用要二十多秒）。

## [0.1.0] - 2026-10-01

首个公开的开发预览版。

### 输入

- 基于 librime 1.17 的 macOS 输入法，默认雾凇拼音，支持全拼与多种双拼；原生自绘候选窗，横排 / 竖排、亮暗配色。
- **快捷菜单**：打字时长按 ⌥，空格进入 AI 处理，数字键进入常用语、符号板、高频词与设置。
- **AI 处理**：对选中文字、刚打的字或正在选的候选执行翻译、润色或自定义动作，结果以候选呈现、回车替换。
  可用 Apple 端侧模型（取决于设备与地区）或自备 OpenAI 兼容接口；简繁转换在本机完成。
- **输入图层（可选）**：上屏前先在光标处停留成草稿，便于整段处理后再发送。
- 常用语分类、自定义短语、按应用默认中英文。

### 设置

- 可视化设置 80 余项，配色画廊与实时预览；方案与词库一键安装（固定版本与 SHA-256），官方在线词库每天 / 每周自动更新。
- 从鼠须管只读导入；本地备份与恢复；RIME 同步目录合并词频。
- 输入统计（可选，默认关闭，仅本机）；首次引导。
- **自动更新**：每天检查公开的版本清单，下载后校验 SHA-256 与开发者签名，再交给系统安装器；可关闭。

### 发行

- 安装包由 ZOOL LLC 的 Developer ID 签名并经 Apple 公证。
- 安装包含 GPL-3.0 组件，整体按 GPL-3.0 条款分发；附带对应源码包 `AIME-0.1.0-source.tar.gz`。
- 命令行工具 `aime`（deploy / bench / doctor / import-squirrel / package / get / set / sync / subscribe），目前仅支持 Apple 芯片。

[Unreleased]: https://github.com/zoolapp/aime/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/zoolapp/aime/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/zoolapp/aime/releases/tag/v0.1.0
