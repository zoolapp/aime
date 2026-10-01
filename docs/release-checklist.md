# AIME 发布检查清单

每次发布逐项勾选，记录提交 SHA、工具链、测试日志和未解决问题；未验证项不得写成已通过。

## 版本与构建

- [ ] 同步 `project.yml` 的 `MARKETING_VERSION` 与 `Packages/AIMEKit/Sources/aime/AIME.swift` 的 CLI `version`，按需递增 `CURRENT_PROJECT_VERSION`；核对构建产物的 `aime --version`。
- [ ] 更新 `CHANGELOG.md`：把已验证的变更从 Unreleased 移至对应版本，写明日期、已知限制和升级注意事项。
- [ ] 记录 `xcodebuild -version`、`swift --version`、macOS 版本和 CPU 架构。目标工具链为 Swift 6.4；当前 Package.swift 声明最低工具版本 6.2，CI 选择 runner 上最新稳定 Xcode，发布前须核对实际版本。
- [ ] 发布提交的 CI 全绿：SwiftPM 构建与测试、Release CLI、p99 门禁、词库检查、Xcode Release 构建及 artifact 上传。词库发生变化时，Dictionaries 工作流也须通过。
- [ ] 核对 `Vendor/librime.lock`、`dicts/registry.json` 和第三方分发许可及声明；记录依赖版本与下载校验结果。
- [ ] 执行 `python3 -m unittest discover -s scripts/tests -v`；解包核对 `Contents/Resources/LicenseMaterials/` 的 receipt、三份插件许可和原始 manifest。参照 [局部嵌入验收](license-packaging-verification.md) 区分已核对输入哈希与最终签名产物哈希，补齐清单中仍未通过的材料。
- [ ] 按 [原生插件许可审计](native-plugin-license-audit.md) 审查 `librime-octagram` 的 GPL-3.0 组合范围；为受覆盖程序提供固定版本的完整对应源码、实际改动与构建材料。解包最终安装包核对全部许可/署名，下载页就近链接对应源码；仅有 MIT 声明或上游主页不算通过。

## 本地安装与输入实测

- [ ] 备份现有 AIME 用户配置；在 macOS 26+ 测试机执行下列步骤。`install-dev.sh` 会替换当前用户安装的 AIME 并终止旧进程，须保存正在输入的内容。

```bash
bash scripts/fetch-librime.sh
# fetch-dicts 内部也调用 stage-plugins，干净检出时需先创建目录。
mkdir -p Packages/AIMEKit/.build
bash scripts/fetch-dicts.sh
swift build --package-path Packages/AIMEKit
bash scripts/stage-plugins.sh
swift test --package-path Packages/AIMEKit
bash scripts/install-dev.sh
```

- [ ] 在系统设置启用 AIME，必要时注销并重新登录；运行 `"$HOME/Library/Input Methods/AIME.app/Contents/Helpers/aime" doctor`，检查插件、方案和路径。
- [ ] 分别在 **TextEdit、Safari、VS Code、微信** 实测中文连续输入、候选翻页及选择、空格/回车上屏、退格、标点、中英文切换、焦点切换与应用重启，记录应用版本及结果。
- [ ] 验证设置应用能打开，修改配置后重新部署生效；确认已有用户配置和词频未被意外覆盖。
- [ ] 对最终下载解压的发布包另做安装及输入冒烟测试。本地 `install-dev.sh` 会嵌入 CLI 和设置应用；CI 的 `AIME-unsigned.zip` 只打包 Xcode 生成的 AIME.app，不执行这一步。发布说明须如实列出包内组件，若承诺完整套件则先组装并验证完整产物。

## 性能与内存

- [ ] 执行同 CI 的 Release 基准，保留 p50/p90/p99/max、机器型号、系统版本和词库版本；p99 必须 ≤ 5 ms。临时用户目录避免改写日常词频数据。

```bash
swift build --package-path Packages/AIMEKit -c release --product aime
bash scripts/stage-plugins.sh
AIME_BENCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aime-bench.XXXXXX")"
"$(swift build --package-path Packages/AIMEKit -c release --show-bin-path)/aime" bench \
  --user-dir "$AIME_BENCH_DIR" --shared-dir build/SharedSupport \
  --schema rime_ice --keys nihaoshijie --iterations 2000 --assert-p99-ms 5
```

- [ ] 测量实际输入法进程的常驻内存：启动并输入后执行 `ps -o pid=,rss=,etime=,command= -p "$(pgrep -x AIME)"`，RSS 单位为 KiB；结合活动监视器记录空闲、连续输入 10 分钟和重新部署后的内存。目标 ≤ 200 MB，明确使用的计量单位并保留结果。
- [ ] 可用 `/usr/bin/time -l` 包裹上述 bench 命令记录 CLI 峰值内存；该结果不能代替输入法进程的常驻内存测量。超标须定位或在预发布说明中明确披露，不宣称已达标。

## 签名与公证

- [ ] AIME 公司团队为 ZOOL LLC（`PX694P4CGY`）；按 [发布流程](releasing.md) 核对证书、账号角色与公证凭据。Apple Development 构建不能作为正式分发产物。
- [ ] 正式签名使用有效、未吊销的 **Developer ID Application** 证书，启用 Hardened Runtime，为嵌套 dylib、插件、CLI、设置应用和外层应用从内到外签名，使用可信时间戳及适用的 entitlements。
- [ ] **警告：切勿使用已吊销证书签名，macOS 会将其判为恶意软件并移入废纸篓。** 发布前核验证书状态；`install-dev.sh` 默认 ad-hoc 签名且使用 `--timestamp=none`，不能替代正式发布签名流程。
- [ ] 按 [Apple 公证工作流](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) 使用 `xcrun notarytool submit AIME-signed.zip --keychain-profile "$AIME_NOTARY_PROFILE" --wait`，确认状态为 Accepted；凭据保存在 Keychain 或受控 secret 中，不写入仓库。
- [ ] 公证成功后执行 `xcrun stapler staple AIME.app`、`xcrun stapler validate AIME.app`、`codesign --verify --deep --strict --verbose=2 AIME.app` 和 `spctl --assess --type execute --verbose=2 AIME.app`；重新用 `ditto -c -k --keepParent AIME.app AIME-signed.zip` 打包含票据的最终产物并验证下载版本。
- [ ] 签名或公证未就绪时发布 **unsigned** 包，Release 中明确“未使用 Developer ID 签名、未经 Apple 公证，仅供知悉风险的测试者使用”。内部库可能带 ad-hoc 签名，这不等于 Developer ID 签名或公证。
- [ ] unsigned Release 附上安装路径与 quarantine 处理方式：先核对下载来源与发布的 SHA-256，解压并将应用放入 `~/Library/Input Methods/`；仅在信任该产物时，对该应用执行以下命令，不关闭系统全局 Gatekeeper，也不将此方法用于绕过证书吊销。

```bash
xattr -dr com.apple.quarantine "$HOME/Library/Input Methods/AIME.app"
```

## GitHub Release

- [ ] 确认版本提交与 CI 成功运行的 SHA 一致，创建对应的 `vX.Y.Z` tag 并推送；这一步由发布负责人执行。推送 tag 后 Release 工作流只生成**草稿**（含 pkg、zip、SHA256SUMS.txt），不会自动发布，流程见 [releasing.md](releasing.md)。
- [ ] 从该提交的 Actions 页面下载 `AIME-unsigned` artifact，取出其中的 `AIME-unsigned.zip`（保留期仅 7 天）；签名发布则使用完成公证、staple 后重新打包的最终 ZIP。
- [ ] 执行 `shasum -a 256 AIME-unsigned.zip`（签名包改用实际文件名），将校验值写入 Release 说明，核对 ZIP 包内包含 AIME.app 且不含个人配置、词频或凭据。
- [ ] 创建 GitHub Release 草稿，选择已验证 tag，附上 ZIP、CHANGELOG 对应条目、最低系统版本、支持架构、包内组件、安装升级步骤、签名状态、基准结果及已知问题；unsigned 包必须附上述 xattr 说明。
- [ ] 预览草稿，核对附件与校验值；未达到稳定版要求时标为 Pre-release，再由发布负责人发布。
- [ ] 从 Release 页面重新下载产物，验证 SHA-256，并在干净测试环境复测安装、输入与卸载；保存 Release 链接和实测证据。

## 安装包（.pkg）

```bash
bash scripts/package.sh                       # → dist/AIME-<version>.pkg（未签名）
AIME_SIGN_IDENTITY=<Developer ID Application 哈希> \
AIME_INSTALLER_IDENTITY="Developer ID Installer: …" bash scripts/package.sh
xcrun notarytool submit dist/AIME-<version>.pkg --keychain-profile aime-notary --wait
xcrun stapler staple dist/AIME-<version>.pkg
```

- 安装到 `/Library/Input Methods/AIME.app`；`postinstall` 以当前登录用户身份执行 `AIME --install`（注册、启用、选中）。
- macOS 对首次安装的第三方输入法可能拒绝立即选中（`TISSelectInputSource` 返回 -50），
  需要用户在「系统设置 › 键盘 › 输入法」中添加 AIME，或注销重新登录一次。结束页已写明。
- 首次启动时若 `~/Library/Rime` 存在且 AIME 用户目录为空，会自动只读导入鼠须管配置，部署后合并词频快照。
- 本机由受沙箱工具生成的文件带 `com.apple.provenance` 扩展属性，`pkgutil --payload-files` 会列出 `._*` 条目；
  安装时会还原为扩展属性，不影响使用。正式发布请在 CI 的干净环境打包。
