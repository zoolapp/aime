# Third-party notices

AIME's original code is licensed under [MIT](LICENSE), Copyright (c) 2026 ZOOL LLC. This does not relicense dependencies, dictionaries, or adapted community documents. AIME is not a Squirrel fork and contains no Squirrel GPLv3 source code.

This inventory covers what the AIME app bundles and what it can download. It is not a substitute for the full license texts, which must accompany distributed components (e.g. `SharedSupport/LICENSE` for rime-ice). The current local build has not yet passed the complete license-packaging audit; see [the release checklist](docs/release-checklist.md) and [the native plugin licence review](docs/native-plugin-license-audit.md).

## Components and data

| Component | Upstream / license | Status and handling |
| --- | --- | --- |
| librime 1.17.0 (33e7814) | [rime/librime](https://github.com/rime/librime), BSD-3-Clause | **Bundled** as `Contents/Frameworks/librime.1.dylib` from the official prebuilt release; sha256 pinned in `Vendor/librime.lock`. Statically includes yaml-cpp (MIT), leveldb (BSD-3), marisa-trie (BSD-2/LGPL-2.1 dual), glog (BSD-3), OpenCC (Apache-2.0). |
| librime-lua (ec52e48) | [Pinned license](https://github.com/hchunhui/librime-lua/blob/ec52e48ea18f11af37717a01c337f853215cf70b/LICENSE), BSD-3-Clause | **Bundled** in `Contents/Frameworks/rime-plugins/` from the same librime release. Embeds Lua (MIT); the embedded Lua version and full notices remain to be audited. |
| librime-octagram (dfcc151) | [Pinned license](https://github.com/lotem/librime-octagram/blob/dfcc15115788c828d9dd7b4bff68067d3ce2ffb8/LICENSE), **GPL-3.0** | **Bundled native plugin**, linked to `librime.1.dylib`. The earlier BSD classification was incorrect. Review the combined-program scope and provide the required corresponding source before binary distribution; a separate plugin directory does not establish an independent work. |
| librime-predict (920bd41) | [Pinned license](https://github.com/rime/librime-predict/blob/920bd41ebf6f9bf6855d14fbe80212e54e749791/LICENSE), BSD-3-Clause | **Bundled** in `Contents/Frameworks/rime-plugins/` from the same librime release. Transitive components remain to be audited. |
| OpenCC data | [BYVoid/OpenCC](https://github.com/BYVoid/OpenCC), Apache-2.0 | **Bundled** in `Contents/SharedSupport/opencc/` from the librime dependency archive. |
| Yams | [jpsim/Yams](https://github.com/jpsim/Yams), MIT | Swift package dependency (version pinned in `Package.resolved`). |
| swift-argument-parser | [apple/swift-argument-parser](https://github.com/apple/swift-argument-parser), Apache-2.0 | Swift package dependency of the `aime` CLI. |
| rime-ice / 雾凇拼音 2026.06.30 | [iDvel/rime-ice](https://github.com/iDvel/rime-ice), GPL-3.0 | **Bundled** in `Contents/SharedSupport/`: schemas, word lists and executable Lua scripts. Downloaded at build time by `scripts/fetch-dicts.sh`, never committed. Its `LICENSE` ships next to it; source is the pinned upstream release. AIME intends to distribute it as a separate work; that boundary must be reviewed against the actual adaptations and coupling before release. It does not become MIT. Also installable as a package. |
| wanxiang / 万象拼音 v18.0.15 | [amzxyz/rime_wanxiang](https://github.com/amzxyz/rime_wanxiang), CC-BY-4.0 | Optional download through the package manager (sha256 pinned in `dicts/registry.json`); not bundled. |
| rime-frost / 白霜拼音 1.0.4 | [gaboolic/rime-frost](https://github.com/gaboolic/rime-frost), GPL-3.0 | Optional download; not bundled. |
| rime-essay / 八股文 | [rime/rime-essay](https://github.com/rime/rime-essay), LGPL-3.0 | Optional download of `essay.txt` at a pinned commit; not bundled. |
| AIME online word lists / historical aime_tech_2026 | AIME, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | **Optional subscription**, with a catalog shipped as `SharedSupport/aime/vocabulary-catalog.json`. Current builds remove `aime_tech.txt` and `aime/aime_tech.tsv`; `dicts/aime_tech_2026` remains historical source material. Online word lists are maintained in the separate `aime-dicts` project and are downloaded when subscribed. Attribution: “AIME word lists — Luo Lei and contributors — CC BY 4.0”, with the specific source URL and modification notices retained on redistribution. Brand names belong to their owners; inclusion implies no endorsement. |
| Contributor Covenant 2.1 | [Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | Adapted in `CODE_OF_CONDUCT.md` with an AIME reporting contact. Its attribution is retained; the repository's MIT license does not replace this document's license. |

## Distribution checklist

The three pinned plugin license texts and observed Vendor binary hashes are recorded in [the native-plugin manifest](licenses/native-plugins/manifest.json). The build embeds this partial inventory, the plugin license texts, AIME's original license, and these notices under `Contents/Resources/LicenseMaterials/` before signing. It rejects license or pre-signing plugin inputs that differ from the audited hashes. This is not a complete corresponding-source package or distribution approval. See [the audit and remaining work](docs/native-plugin-license-audit.md).

Before publishing any binary or dictionary package:

1. Inventory the exact versions, source URLs, archive hashes, bundled libraries, plugins, scripts, and data files, including transitive components in prebuilt archives.
2. Include the full required license texts and copyright notices with the distributed artifacts, plus any applicable `NOTICE` file. This summary is not a substitute for those texts.
3. For GPL material, including the native octagram plugin, review the combined-program scope, fulfill the applicable corresponding-source requirements, and preserve modifications/provenance. AIME's original MIT source license does not establish that the combined binary can be distributed under MIT alone. Separate download alone does not waive license obligations.
4. Ensure original MIT source contains no copied, translated, or adapted GPL implementation code, including Squirrel code. Data import compatibility is not permission to copy source.
5. For CC BY 4.0 data, include attribution, a license link, and modification notices. Do not imply endorsement by named brands or upstream authors.

Licensing must be checked against the pinned artifact, not only a moving upstream branch. Resolve missing or conflicting provenance before adding or distributing a component.
