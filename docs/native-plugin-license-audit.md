# 原生插件固定版本许可核对

2026-10-01 核对结果：`librime-octagram` 固定修订的 `LICENSE` 是 GPL-3.0，此前 `THIRD_PARTY_NOTICES.md` 将三个插件统一写为 BSD-3-Clause 不准确。AIME 原创代码仍为 MIT；公司可以发布开源 App，但当前安装包的组合程序范围与对应源码材料尚未通过发行验收。

## 已验证材料

| 插件 | 固定源码修订 | 根目录 LICENSE |
| --- | --- | --- |
| librime-lua | `ec52e48ea18f11af37717a01c337f853215cf70b` | BSD-3-Clause |
| librime-octagram | `dfcc15115788c828d9dd7b4bff68067d3ce2ffb8` | GPL-3.0 |
| librime-predict | `920bd41ebf6f9bf6855d14fbe80212e54e749791` | BSD-3-Clause |

从官方仓库固定修订获取三个许可全文，HTTP 均为 200；正文与此前缓存逐字一致，Git blob SHA-1 与官方固定树一致。文件保存在 [`licenses/native-plugins/`](../licenses/native-plugins/manifest.json)，manifest 记录固定链接、许可 SHA-256、观察到的 Vendor 二进制 SHA-256 和待审状态。这是三份插件根许可的部分清单，未宣称覆盖所有传递依赖，也未推定 GPL 的 only/or-later 版本限定。

`Vendor/librime/version-info.txt` 中三个短修订与上述完整修订的前缀相符；引擎压缩包版本与 SHA 来自 `Vendor/librime.lock`。短修订记录不能单独证明预编译产物的完整可复现构建来源，因此对应源码验收仍待执行。

`otool -L` 显示三个 Vendor 插件的 x86_64 和 arm64 切片均链接 `@rpath/librime.1.dylib`。`scripts/embed-runtime.sh` 将整个 `rime-plugins` 目录复制到 `Contents/Frameworks/` 并重新签名；`RimeEngine.initialize` 调用 librime 的初始化接口。上述证据证明原生插件被打包及其链接关系，未进行本轮运行时插件加载实测；目录分开不证明 GPL 聚合边界成立。manifest 中二进制 SHA 仅对应重新签名前的 Vendor 文件，不能用于校验最终安装包。

验证输出：`build/release-audit/native-plugin-license-checks.json`；三个插件的链接输出：`build/release-audit/librime-*-otool.txt`。本轮只修改文档与许可材料，未构建、安装或签名 App。

## 发行前尚需验证

- 结合实际源码和运行时调用审查 octagram、librime 与 AIME 是否构成 GPL 覆盖的组合程序；原始 MIT 文件许可与组合程序发行条件分别记录。依据为 [固定 GPL 原文](https://github.com/lotem/librime-octagram/blob/dfcc15115788c828d9dd7b4bff68067d3ce2ffb8/LICENSE) 第 1、5、6 条。
- 保存最终二进制所需的对应源码、依赖、接口文件、实际改动和生成/安装脚本；验证能够由这些材料构建。GitHub 源码链接和三个 LICENSE 文件本身不构成完整对应源码包。
- 补齐其余原生依赖、Lua 和词库的版本、版权、许可及适用 NOTICE；Yams 的 CYaml/libyaml 等传递组件也需核对实际来源，不能仅列 Yams 根 MIT 许可。
- 将经审核的全部材料真正装入最终安装包，解包复核，并在二进制下载处提供清晰的对应源码入口。构建现在会在签名前把三个已审插件的许可、原始 manifest 和声明装入 `Contents/Resources/LicenseMaterials/`；它拒绝与已审 SHA 不符的输入。这只覆盖部分插件许可，不能代替其余材料与完整对应源码包。
- 公开公司组织、仓库、正式安装包和域名部署仍待推进。

官网说明于 2026-10-01 同步到 `aime-web` 提交 `ae7158e`（未 push）：中英开源页列出三个固定插件许可，明确原生 GPL 与原创 MIT 的区别、安装包待审状态。8 张新页面截图已与基准逐张对照，两种语言的 6 个许可链接实际导航通过；证据为 `../aime-web/.ui-acceptance/2026-10-01-native-license/VERDICT.md` 和 `verification.json`。这仅完成官网说明同步，不代表上述安装包审查通过。

保留 octagram 功能并准备满足 GPL 的开源发行材料是当前建议。移除或替换插件会影响语法模型/万象兼容范围，需要另作产品与实现评估；此次核对没有更改功能或重新许可 AIME 原创代码。
