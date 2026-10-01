# ADR-0001：以 librime 预编译包为引擎

- 状态：已接受 · 2026-09-29

## 背景

AIME 的目标用户已经拥有 RIME 格式的方案、词库、lua 扩展和语法模型。性能是第一优先级。

## 决策

- 不自研引擎，使用 librime。钉定官方 **1.17.0（commit 33e7814）macOS universal 预编译包**，
  `Vendor/librime.lock` 记录 sha256，`scripts/fetch-librime.sh` 下载校验后组装为
  SwiftPM `binaryTarget`（`CRime.xcframework`）与 `rime-plugins/`（lua、octagram、predict）。
- Swift 侧通过 `rime_get_api_stdbool()` 调用，封装在 RimeKit，所有调用限定在主 actor。
- 插件由 librime 从 `librime.1.dylib` 同级的 `rime-plugins/` 目录加载，与鼠须管布局一致。

## 备选

| 方案 | 否决原因 |
|---|---|
| 自研引擎 | 多年工作量，且放弃整个 RIME 生态 |
| Homebrew librime | 链接到 /opt/homebrew，无法随 App 分发 |
| 源码 submodule + CMake + Boost | 首次构建 20 分钟以上，贡献门槛高；列入 Roadmap（R01）作为可复现构建 |

## 影响

- 升级引擎 = 改 lock 文件中的版本与 sha256。
- 预编译包的 dylib 需要用 App 的身份重签；启用 hardened runtime 时需
  `com.apple.security.cs.disable-library-validation`（dlopen 插件）。
