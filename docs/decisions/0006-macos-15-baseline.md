# ADR-0006：最低系统下调到 macOS 15

- 状态：已接受 · 2026-11-10
- 取代：[ADR-0004](0004-macos-26-baseline.md) 中「部署目标 macOS 26.0」一条；工具链、依赖与并发约定不变。

## 背景

有用户在 macOS 26 以下的系统上打开安装包，停在「选择目的宗卷」页，「继续」按钮是灰的，没有任何说明（安装包的 `volume-check` 要求 26.0）。

## 决策

- 部署目标 macOS 15.0（`project.yml`、`Package.swift`、`scripts/package.sh` 的 `MIN_MACOS`、更新清单的 `minimumSystemVersion` 四处同步）。
- 构建仍需 Xcode 26+ 的 SDK；CI 继续用 `macos-26` 镜像。
- 安装包增加 `installation-check`：系统低于最低版本时开场即弹窗说明，`volume-check` 保留作兜底。

## 理由

- 把部署目标降到 15 编译，只有两处 macOS 26 专属 API：FoundationModels（Apple 端侧模型）与工具栏的 `sharedBackgroundVisibility`，各加一处 `#available` 即可。librime 与插件最低 10.15。
- 端侧模型在 15 上报告「需要 macOS 26」，AI 动作可改用自备的 OpenAI 兼容接口，其余功能不受影响。
- 在 macOS 15.7.7 虚拟机上实测：安装、添加输入源、打字与中英切换、设置各页亮/暗外观。

## 不下调到 macOS 14 的原因

设置 App 的卡片表单（`CardFormStyle`）依赖 macOS 15 的分组子视图 API，另有 `defaultLaunchBehavior` 等 6 处 15 专属接口；降到 14 需要为所有设置页做样式降级，收益与测试成本不成比例。

## 代价

- 每次发版需在 macOS 15 上至少过一遍安装、打字、中英切换与设置页截图（见 `docs/release-checklist.md`）。
- 新代码使用 macOS 26 API 时必须加 `#available`，否则编译即失败。
- macOS 15 上曾出现 SwiftUI 渲染差异（外观页分组标题空白），UI 改动需要在 15 上截图对照。
