# ADR-0004：最低系统 macOS 26，Swift 6 严格并发

- 状态：已接受 · 2026-09-29

## 决策

- 部署目标 macOS 26.0；工具链 Xcode 26+/Swift 6.x，`SWIFT_STRICT_CONCURRENCY=complete`。
- 依赖只有 Yams（YAML）与 swift-argument-parser（CLI）；测试用 Swift Testing。
- 工程由 XcodeGen `project.yml` 生成，`.xcodeproj` 不入库。

## 理由

- AI 助手的端侧能力（Foundation Models）需要 macOS 26。
- 新项目没有存量用户，不背旧系统兼容包袱；RIME 生态对旧系统的用户已有鼠须管。

## 并发落地

- `RimeEngine` / `RimeSession` 标注 `@MainActor`。
- `IMKInputController` 未标注主 actor：重写方法声明为 `nonisolated`，内部用
  `MainActor.assumeIsolated` 进入（IMK 固定在主线程回调，只跨越编译器的隔离边界，不跨线程）。
- librime 的通知回调来自部署线程，统一转发到主线程处理。

## 代价

旧系统上的贡献者需要升级；如果社区有需求，可以评估把 AIMEAI 做成可选组件后下调到 macOS 15。
