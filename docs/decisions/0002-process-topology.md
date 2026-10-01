# ADR-0002：两个 App + 一个 CLI 的进程拓扑

- 状态：已接受 · 2026-09-29

## 决策

- **AIME.app**：IMK 输入法服务，LSUIElement，进程内运行 librime；候选窗为 AppKit `NSPanel` +
  Core Text 自绘。只做输入相关的事。
- **AIME Settings.app**：SwiftUI，嵌在 `AIME.app/Contents/Applications/`，**不链接 librime**：
  读取 `build/*.yaml`（librime 合并后的结果），把修改写入 `aime/generated/`。
- **aime CLI**：`AIME.app/Contents/Helpers/aime`，是测试、CI 与设置 App 在输入法未运行时的部署入口。
- 进程间通信：文件 + `DistributedNotificationCenter`（`dev.luolei.aime.reload` /
  `dev.luolei.aime.deploy.result`），无特权边界，不需要 XPC。

## 理由

- 设置界面不进常驻进程：控制输入法内存与按键延迟，界面崩溃不影响打字。
- 设置 App 不开 librime 会话，避免与输入法争用 userdb 的 LevelDB 锁。
- 候选窗不用 SwiftUI hosting：每次按键都要重排，AppKit 自绘更可控。

## 风险

- 设置 App 预览是用相同的候选窗视图渲染样例数据，不是真引擎输出；若未来需要真引擎预览，
  应通过 XPC 请求输入法进程，而不是在设置 App 里起第二个 librime 实例。

## 第二意见（codex，2026-09-29）

对 D1–D4 做了对抗评审，评分 2/5，列出 10 项阻断问题。合成结论：

**一致**
- D1（预编译 librime）、D3（独立用户目录 + 只读导入）方向正确。
- 重部署/同步会直接丢弃正在输入的内容；候选点击、翻页绕过会话代际检查。
- inline candidate 用 preedit 的字节光标去索引预览文字；`unzip` 先 wait 后读管道可能死锁。
- 导入器、词库安装「先删后拷」，失败即丢数据；包路径缺少越界与符号链接防护。

**不一致**
- 它认为扁平合成（D4）「不等价于分层语义」。同层父子键互删、跨层 `/=`+`/+` 确是缺陷，已修；
  但扁平合成这一方向保留——嵌套 `__patch` 已实测会整段替换，没有更正确的替代。
- 它要求完整的 revision/事务协议。对 MVP 过重，只落地低成本、高收益部分；分布式通知无法校验发送方，
  以文档说明风险（只能触发用户本可手动触发的重部署）。

**我信谁、怎么做**
采纳全部正确性与数据安全类意见并已修复（附回归测试）：
- 重部署前提交正在输入的内容；`cleanupAllSessions`/`finalize` 统一作废会话包装，防止 ID 复用误删新会话；
- 跨进程 `WorkspaceLock`（flock），CLI 写命令与输入法部署互斥；设置 App 超时不再另起 CLI 部署；
- 部署请求带 request id，结果按 id 匹配，前端配置部署失败计入结果；
- 损坏的补丁层报错并保留上次成功的 shim，而不是当作空配置；
- 导入/安装改为「临时文件 + 原子替换」，旧文件进 `aime/backup/`，安装失败回滚，跨包共享文件不误删；
- 包内 `aime/`、`sync/`、`*.userdb`、符号链接、越界路径一律拒绝；`unzip` 先读管道再 wait。
未做（进 Roadmap）：配置 revision 与部署结果的强绑定、包依赖（`requires`）解析、左右修饰键分别跟踪。

## 事故记录：激活时的跨进程死锁（2026-09-29）

真机切换到 AIME 后，客户端（Chrome 等）卡死。堆栈：`activateServer` → 按应用选项 `set_option(ascii_mode)` →
librime **同步**发出选项通知 → 状态气泡 → 同步向客户端查询光标位置（`attributesForCharacterIndex`）。
客户端正阻塞等待 `activateServer` 返回，双方互等直至超时。第二意见曾把「同步通知重入」列为 NIT，当时未修，是误判。

修复：librime 通知一律异步投递到主线程；激活期间不回调客户端；选项值不变不写；
只为用户刚按键触发的选项变化显示气泡。回归测试 `notificationsAreDeliveredAsynchronously`。
