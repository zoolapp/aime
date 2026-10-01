# aime_tech_2026 · 2026 AI / 互联网词库

AIME 自带的补充词库，收录 2026 年常见的 AI 公司与产品、AI 与开发术语、互联网流行语、平台与品牌。
随 AIME 安装，以 `table_translator@aime_tech` 挂载到雾凇拼音（见 `SharedSupport/aime/defaults/rime_ice.yaml`），
在 AIME 设置里可随方案一同关闭。

## 格式

每个 `.tsv` 文件四列，制表符分隔：

| 列 | 说明 |
|---|---|
| 词条 | 上屏文字，保留品牌的正确大小写，如 `DeepSeek` |
| 编码 | 中文为全拼、音节以空格分隔（`zhi neng ti`，ü 写作 v）；英文为小写字母与数字（`gpt5`） |
| 类别 | `ai_company` `ai_product` `ai_term` `dev_tool` `internet_slang` `brand` `platform` |
| 权重 | 1–100，越常用越高 |

`swift scripts/build-dicts.swift --check` 校验列数、类别、权重与拼音音节合法性；
`scripts/fetch-dicts.sh` 会生成 `aime_tech.txt` 放入 SharedSupport。

## 贡献

欢迎通过 PR 或「词库请求」Issue 补充词条。请注意：

- 只收录已有一定传播度的词，不收录人身攻击、低俗、政治敏感内容；
- 品牌名以官方写法为准；
- 一次 PR 聚焦一个类别，便于评审。

## 许可

词表内容以 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) 授权。初稿由 AI 辅助整理并经人工抽检。
