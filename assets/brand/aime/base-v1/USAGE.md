# AIME 视觉基底 v1.0

方向：圆角字签。名称：AIME / 艾么输入法。口号：中文常新，自在表达。

`brand-board.png`是整体参照；`extension-board.png`是网页、发布卡片、头像与贴纸的图形参照。`brand-reference.pdf`为四页参考手册，页面图形是位图；独立SVG为正式可编辑母版。

横向彩色组合用`lockup-color.svg`；透明黑标用`lockup-black.svg`，自有暗底用`lockup-white.svg`；用户选定的黑底白标矩形组合用`lockup-reversed.svg`。

独立方形只放字签：`square-black.svg`为黑底白签，`square-white.svg`为白底黑签，`square-paper.svg`为纸白底朱红签；同名PNG为1024px，`-256.png`为256px。`app-icon-candidate.svg/png`含外侧透明留白，尚未接入App。

菜单栏用透明单色字签，文件在`menu/`：`AIME-bookmark.pdf`是真矢量16pt PDF；`menu-template.svg`为SVG；PNG有16/20/24/32px及2x。这里是候选素材，不是系统输入源实测结果。

所有字签轮廓共享`tokens.json`中的100×120单位路径，顶部圆角22、V口深30，净空建议为标志宽度22%。保持比例、宽V口、单张圆顶，不添加眼睛、毛笔、贴字、折角或叠签。方形版不要塞入AIME和中文名。组合字标已固定，不逐个替换字体。

配色：朱红#B64032、纸白#F7F2E9、墨黑#242321、砂金#D3B88F；严格黑白标志使用#000000/#FFFFFF。砂金用于辅助，不作浅底正文。平面标志不加纸纹、阴影或渐变。

纸签形象参照为`paper-reference.png`：纸白正面、朱红背面、轻弯姿态。生成图偏厚偏长，不能拿来量尺寸；以矢量轮廓为准。`paper-reference-provenance.json`保留原图尺寸、哈希、完整提示与偏差。

英文AIME为自绘圆端几何字标；中文用Noto Sans SC 650转轮廓，正文建议400、标题500–650。Noto来源与许可证在`font-source.json`和`licenses/`；Logo无需安装字体。仓库MIT许可附在`LICENSE`，不包含商标注册结论。

`manifest.json`列文件SHA-256。包内`source/`附导出脚本，需要放回AIME仓库对应scripts/brand路径再运行；Node脚本需要sharp，Swift脚本需要macOS CoreText。原始AI纸签图不可通过矢量脚本复现。当前源文件与最终核验在仓库`docs/brand/final-2026-10-01/`。
