# 插件许可嵌入验收（2026-10-01）

B01b2 通过：实际构建的输入法 App 包含已审三个原生插件的许可全文与来源清单。
B01b、B01c 仍未通过；此结果不代表完整依赖许可、GPL 对应源码或正式发行通过。

## 实际行为

`scripts/embed-runtime.sh` 复制插件后，在签名前运行 `scripts/embed-license-materials.py`。
脚本核对许可 SHA-256、Vendor 二进制 SHA-256、刚复制的插件字节及插件目录成员。
不符合固定清单时返回非零，停止该构建；它不会删除已有资源或重写源清单。

材料位于 `Contents/Resources/LicenseMaterials/`：AIME MIT 许可、第三方声明、三个插件完整许可、
原始 manifest、已有审计与发布说明、范围说明，共 9 份内容文件，另有校验 receipt。
原始 manifest 保留未通过项；receipt 同样将完整许可/完整对应源码审计标为 false。
Vendor 输入哈希在签名前核对，不能用来校验重新签名后的插件；验收 JSON 另记最终插件哈希。

## 验证证据

| 检查 | 实际结果 | 本地证据（gitignored） |
| --- | --- | --- |
| 拒绝错误输入 | 5 项测试通过：正确嵌入、损坏许可、替换 Vendor、修改包内插件/增加插件、清单路径穿越；拒绝发生在写入资源前 | `build/release-audit/license-packaging-tests.log` |
| 实际构建 | Xcode 27.0（27A266a）Release，`** BUILD SUCCEEDED **`，退出 0 | `license-packaging-isolated-build.log` |
| 解包检查 | ZIP 解包后逐项校验 9 个内容文件字节数与 SHA，源清单和三份许可逐字一致 | `license-packaging-verification.json` |
| 插件切片 | lua、octagram、predict 均包含 x86_64 与 arm64；清单中的固定源码记录保留 | 同上 |
| 签名 | 解包后的 App 执行 `codesign --verify --deep --strict --verbose=2` 退出 0；签名为 ad-hoc | `license-packaging-codesign.log`、`license-packaging-signature.log` |

表中简写日志均位于 `build/release-audit/`。本地测试 ZIP：
`build/license-packaging-check/AIME-license-check.zip`，SHA-256：
`172e4f2f6c2535c91b96351c151c733903eacec60dcdcd7e2c4ffb2e7182d626`。

首次使用共享 DerivedData 的构建退出 65，日志明确报告 build.db 被其他构建占用，未计为通过。
后续使用独立源码快照及 DerivedData，未安装、重载或操作用户输入法目录。
快照基于 `e45df99221707a40e569a0ce7d1dd2b5462d28ff`，只复制本任务的嵌入脚本与许可说明改动；
清单记录在 `license-packaging-snapshot.json`，未复制并行任务的未提交应用改动。
本任务的代码被同分支并行提交 `d3fc021` 带入；验收前已比对四个实际构建输入与当前跟踪文件逐字一致。
本次单独提交验收结果，未改写该提交或其他任务的应用代码。

## 尚未证明的范围

这份 ZIP 只用于 Xcode 输入法 App 的资源验收，没有组装 CLI/设置应用完整套件或 `.pkg`。
未执行安装、中文输入、卸载、正式 Developer ID 签名、公证或官网发布。
完整 GPL 对应源码、组合范围及其他传递依赖许可继续保持待审；保留 octagram 功能。

测试命令：

```sh
python3 -m unittest discover -s scripts/tests -v
```
