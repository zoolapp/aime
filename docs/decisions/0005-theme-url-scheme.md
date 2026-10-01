# ADR-0005：主题包与 `aime-ime://` 一键导入

- 状态：已接受 · 2026-10-01

## 决策

- 主题以 JSON「主题包」（`aime-theme` v1）交换，只含 13 个 RIME 配色键，颜色统一为 `0xAARRGGBB`。
- 「AIME 设置」注册 `aime-ime` URL scheme；链接 `aime-ime://theme?v=1&d=<base64url>` 自包含主题包，导入完全离线。
- 导入必须经确认页由用户点击；只写生成层的 `preset_color_schemes/<id>` 与 `style/color_scheme(_dark)`。
- 官网主题栏目（画廊、详情、编辑器）是纯前端，链接与 App 由同一份 fixture 校验。

## 理由

- 只含颜色：与鼠须管 / RIME 配色语义一致、可直接复制成 YAML；布局属于个人偏好，不该随主题漂移；字段少，攻击面小。
- 由设置 App 而非输入法进程处理：输入法进程保持只处理按键，不弹窗、不解析外部输入；设置 App 已有预览与部署链路。
- 自包含链接而非下载地址：不引入网络请求与隐私面，也无需托管服务。
- 用户确认 + 写入范围白名单：外部链接不能静默改配置，也不会覆盖「我的配色」（`aime_custom`）。

## 影响

- 详见 [docs/themes.md](../themes.md)。新增 `scripts/export-themes.py`，内置配色变更后需重新导出官网数据与 fixture。
