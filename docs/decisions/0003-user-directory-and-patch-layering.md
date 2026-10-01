# ADR-0003：独立用户目录与三层补丁合成

- 状态：已接受（经实测修订）· 2026-09-29

## 决策

1. 用户目录为 `~/Library/AIME/Rime`，与鼠须管 `~/Library/Rime` 共存；后者只作为导入源，**只读**。
2. 每个受管配置（`default`、各方案、前端 `aime`）有三层补丁：

   | 层 | 文件 | 所有者 |
   |---|---|---|
   | defaults | `SharedSupport/aime/defaults/<name>.yaml` | AIME 发行版 |
   | imported | `aime/imported/<name>.custom.yaml` | 用户手写（导入时原样复制） |
   | generated | `aime/generated/<name>.yaml` | AIME 设置 |

3. AIME 把三层的 `patch:` 条目**合成为一个扁平的字面补丁**写入 `<name>.custom.yaml`：
   后层覆盖前层的同名键及其全部子键；`…/+` 追加键累加；
   `preset_color_schemes`、`app_options` 按子项合并（整块补丁会被拆成逐项键）。

## 为什么不用 `__patch` / `__include` 引用各层（初版方案，已否决）

初版 shim 写成：

```yaml
patch:
  __patch:
    - aime/imported/default.custom:/patch?
    - aime/generated/default:/patch?
```

实测（雾凇拼音 + librime 1.17）发现：`patch:` 节点内的 `__patch` 会把各层的键路径**在 patch
节点本身上执行**，`menu/page_size: 5` 变成嵌套的 `menu: {page_size: 5}`，外层补丁再用它**整段替换**
目标的 `menu`；`engine/translators/+` 更是让整个 `engine` 只剩一个 translator。`__include` 的覆盖键
经 `MergeTree` 同样按路径执行。librime 的 `ConfigMap` 是有序 map，字面补丁按键名排序应用，
父键先于子键，因此合成扁平字面补丁能保持 RIME 原有语义。
回归测试：`PatchLayeringTests.importedLayerApplies / generatedLayerOverridesImported /
defaultsLayerAppendsWithoutClobbering / collectionMapsMergeInsteadOfReplacing`。

## 其他实测结论

- librime 以秒为精度比较源文件时间戳，同一秒内的两次修改会被判定为未变化。AIME 把被修改的目标
  记入 `aime/.dirty`，部署前删除对应 `build/` 产物。
- 手写层保持用户原文件（含注释）不变，是唯一需要人工编辑的地方；合成文件在每次部署前重新生成。
