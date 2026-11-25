# 变更记录

## 未发布 — 续跑通知的会话 id、Ctrl+C 路径隔离

2026-11-25。升级到 `0aada87` 之后在本机做了一次重启，暴露出两处只在真机路径上才现形的问题。

### 续跑通知写规范 session id

`-SessionId` 一路传给引擎时被剥成裸 uuid（`lib/config.js` 的 `normalizeSessionId`
与 `scripts/dsh-restart.ps1` 的 `Normalize-SessionId` 都做 `-replace '^session-'`），
写进 `.smart-restart\pending-notice.json` 的 `sessionId` 是 `c36fce12-…`。宿主的 waker
拿它调 `sessionPersistence.stat()` / `agents.resume()`，而 DSH 的持久化目录是
`sessions\<workspace>\session-<uuid>` → `not found` → notice 归档成 `dropped`，
被中断的会话不会被唤醒。

- `lib/config.js`：`normalizeSessionId` 输出规范形态 `session-<id>`，两种输入都收、幂等。
- `scripts/dsh-restart.ps1`：`Normalize-SessionId` 同样输出规范形态，`auto` 分支补前缀。
- `scripts/dsh-plugin-install.ps1`：写通知前归一化，install 与 restart 两条通道契约一致。
- 本机对照：07:41 的 install 通知写的是 `session-ff9f11e7-…`（带前缀，resume 成功）；
  10:37 的 restart 通知写的是 `c36fce12-…`（裸，dropped）。

### Ctrl+C 路径隔离到子进程（`-TryCtrlC`）

`DshCtrlC.Send` 先 `FreeConsole()` 再 `AttachConsole()`；AttachConsole 失败时直接返回，
进程此时已无控制台，紧接着的 `netstat.exe` 以
「获取控制台模式时发生 Win32 内部错误 句柄无效。0x6」终止整个 run（宿主没停）。

- 发送器独立成 `scripts/dsh-ctrlc-sender.ps1`；`Invoke-TryCtrlC` 改用 `Start-Process`
  起它并读退出码，子进程崩掉只回非零码，主引擎继续走 taskkill 强杀。
- 对照组 `test/console-probe.ps1`（无控制台环境下 `freeonly` 在第一次 netstat 后即终止，
  `baseline` 正常）、回归验证 `test/verify-ctrlc-isolation.ps1`，两者都用
  `test/run-detached-probe.ps1` 以 WMI 拉起（父进程 WmiPrvSE、无控制台）。

### 上游合并

- #6 `fix(install): write the result to -Report` —— 调用方给的 `-Report` 优先于内部 stamp 命名。

### 本机实测（2026-11-25）

| 项 | 之前 | 现在 |
|---|---|---|
| notice 的 sessionId | `c36fce12-…`（裸） | `session-c36fce12-…` |
| waker 结果 | `dropped`（not found） | 可取到会话并 resume |
| `-TryCtrlC` 的 run | aborted 0x6，宿主未停 | 子进程发 Ctrl+C，主引擎继续 |
| selftest / parity | 95/95、262/262 | 95/95、262/262 |

## 0.6.5 — 工作区存储预检、花名册重建与会话列表修复

2026-11-24。侧栏 `tools` 工作区变空的那次事故有三层，这一版把能落在本仓库的两层修掉，
第三层（宿主侧会话列表）落在本机的 `@local/dsh-local-repair` 里，见文末。

### 引擎（scripts/dsh-restart.ps1）

- **存储预检 `Test-StoragePreflight` / `Test-StorageGate`**：解析 `<DSH_HOME>\storages\*.json`，
  对 `workspace.json` 按 workspace 域 schema 逐条校验（ISO-8601 时间戳、`workspaceIds` 与表一致、
  同一会话不能挂在两个工作区）。`-Preflight` 和真实重启都会在**停机之前** fail-closed：
  坏存储 → `exit 3 storage-invalid`，旧实例不动；`-DryRun` 只报告；新增 `-ForceStorage` 显式豁免。
  `-Status -Json` 增加 `storage` 块。
- 为什么值得一个闸门：workspace.json 是**整份** zod 校验，一条记录的 `createdAt` 被外部脚本写成
  `Date.now()` 毫秒数，整个 workspace 域就 FAILED，侧栏「工作区」变空，十个依赖插件 PENDING —
  而错误只出现在宿主日志的一行 `state=FAILED` 里。
- 矩阵新增 WS 组（WS-01..WS-03），parity 262/262。

### 工具（scripts/workspace-store-doctor.mjs）

- 新增 `--reconcile`：按磁盘事实重建工作区花名册——只保留 `cwd` 匹配且 `delegationDepth === 0`
  的会话，把磁盘上未登记的主会话按 mtime 补回，ISO 写回，落盘前用 `--check` 的同一套 schema 复验，
  固定备份 `workspace.json.bak-doctor-reconcile-<stamp>`；宿主运行时默认**拒绝写盘**（exit 2）。
- 这是「写入方」的推荐路径：之前那次外部脚本直接拼 JSON，把数字 epoch 写了进去。

### 本机实测（2026-11-24）

| 项 | 之前 | 0.6.5 |
|---|---|---|
| 正常 `workspace.json` 预检 | 无此能力 | `ok=true`，4 个文件 / 0 错误 / 0 警告 |
| 伪造坏存储（数字 epoch + 非法 ISO + 重复会话） | 宿主启动后才炸 | 3 个错误全部命中；`-Preflight` rc=3、1.4s、未拉起任何实例 |
| `-Status` 的 `storage` 阶段 | — | 29ms（只查 workspace.json） |
| `tools` 花名册 | 82 条（32 条子代理 + 50 主会话） | reconcile 后 50 条，全部是主会话 |
| `Mnemon · Skills` 花名册 | 289 条（288 条子代理） | 1 条（真正属于该目录的） |
| 默认工作区 | 266 条（21 条子代理） | 245 条 |
| reconcile 写盘 | — | 备份 + schema 复验通过；宿主运行时 `--apply` 被拒（rc=2，文件哈希不变） |

### 宿主侧（@local/dsh-local-repair，不在本仓库）

会话列表这条链路上有三处本机修复，改的是 `dsh-session-persistence-jsonl` 的 overlay：

- `listBudget.limit` 200 → 1000：`C:\tools` 有 293 份会话，旧的每目录 200 份窗口把 82 条真会话
  整体挤出窗口，`tools` 组就渲染成空的；
- **header 帧放宽**：83 份会话把 header 行和首批事件压进了同一个 zstd 帧，旧的「第一帧必须恰好一行」
  判据把它们从每次 `list()` 里丢掉（其中包括 `tools` 的 50 条主会话）；现在按第一个换行截断。
  修复后 `session/list` 返回 **910** 条，`tools` 293 条；
- 跨重启 header 索引（`<DSH_HOME>\cache\session-header-index.json`，键 = 路径 + size + mtime）+
  1.5s 并发 `list()` 合并，减少重复 sweep；本机 910 条首轮落盘 442KB。

侧栏「分批渲染」overlay 仍然**停用**：它在这个 0.2.2-rc.3 客户端上会把整个「工作区」段渲染没
（需要 `Ctrl+Shift+R` 才恢复），在查清之前不启用。

## 0.6.4 — 桌面宿主的残留与死管道

2026-11-23 23:45–23:56 连做 11 次重启调试，留下了两样东西：5 个**孤儿宿主**（父进程已退出、
`taskkill /T` 顺树杀不到，共占 ~1.8GB、各自占两个端口、各自跑一份 profile 的后台任务），
以及一个把 `console.error` 写到死管道上的主进程 —— 屏幕上就是两个弹窗。

### 引擎（scripts/dsh-restart.ps1）

- **孤儿宿主回收**（`Get-OrphanDesktopHosts` / `Stop-OrphanDesktopHosts`）：判据是**进程身份**
  （命令行含本机 `dsh-desktop-host` 入口）加上「父 pid 已不在存活进程表里」，而不是 pid 树 ——
  树关系在父进程死掉那一刻就断了，这正是孤儿收不到的原因。`Stop-DesktopApp` 在 `taskkill /T`
  之后自动做一轮清扫；`-CleanupOrphans` 可单独只清扫（不动当前实例），`-DryRun` 只报告不杀。
  清扫失败只记 warn，不把一次成功的重启变成失败。
- **stdout/stderr 有归属**（`Start-DesktopApp`）：0.6.1 起桌面版刻意不重定向，结果是 Electron
  继承启动者那一代控制台的管道；启动者一退出读端就没了，主进程 `console.error` 直接抛
  `write EPIPE`（就是那个「A JavaScript error occurred in the main process」弹窗，日志里
  `ECONNRESET` 刷屏）。现在 stdout/stderr 写 `host.desktop.*.log`，stdin 保持不重定向。
  当年「重定向后 10s 自己退出」的真凶是句柄继承，已由 `Hide-StdHandleInheritance` 解决。
- `cleanupOrphans` 进入 `CALL_KEYS`，工具侧可请求。

### 测试

`npm test` 全绿（selftest 94 / integration 16 / parity **259/259**）。

### 本机实测

| 项 | 之前 | 0.6.4 |
|---|---|---|
| 残留桌面宿主 | 5 个孤儿，~1.8GB，端口 55465/56390/56569/56696/57688… | 0，一次 `-CleanupOrphans` 回收 |
| 当前实例 | 正常（端口 3082 / 4173，健康检查 ok） | 不受影响，`-CleanupOrphans` 不碰它 |
| 主进程 stderr | 继承死管道 → `write EPIPE` 弹窗 | 写入 `host.desktop.err.log` |

## 0.6.3 — 等待有进度、预算说法只有一个来源

台账（0.6.2）解决了「用另一个窗口看它是不是还活着」，但**命令行本身**仍然是一段静默：
深验证 70–150s、就绪 60–140s 期间一行字都不出，屏幕上和卡死长得一样。这一版把等待过程
直接写到终端上，并把预算的说明收回成单一来源。

### 引擎（scripts/dsh-restart.ps1）

- **新增进度行 `Write-ProgressLine`**：三个最长等待循环（`Test-DesktopVerify`、
  `Wait-DesktopHostReady`、`Wait-HostReady`）每 `-ProgressSec`（默认 5s）打一行
  `.. 阶段 · 已等 Ns · 剩余 Ns · 第几轮 / 最后 HTTP`。「已等」在增长 = 程序在跑；
  「剩余」是本次动作的剩余预算；第三段说明它在等什么。写 stderr —— `-Json` 下 stdout
  仍然只有一个 JSON 对象。`-ProgressSec` 可调，节流与台账的 2s 心跳分开计算，互不影响。
- **阶段合计**：`Add-Step` 在阶段成功走完时补一行 `.. 阶段 · 完成 · 用时 Ns`；
  失败/警告不补，因为失败行本身就是结论。
- **预算说明收回一处**（`Format-BudgetParts`）：旧版 `budget` 行里的组成是按条件硬写的，
  实测出现了「就绪 90s」与预算按 240s 算的两套说法。现在说明与数字由同一个函数生成，
  `-Preflight`、`-Stop`、桌面版跳过深验证各自算自己的组成。
- 人读模式在 `budget` 行后追加一句「等待中每 Ns 打一行进度」，避免把进度行误读成新问题。

### 测试

`npm test` 全绿（selftest 94 / integration 16 / parity **258/258**）。

### 本机实测

| 项 | 0.6.2 | 0.6.3 |
|---|---|---|
| `-VerifyOnly` 期间终端可见内容 | 开始行 + 70s 后结果 | 每 5s 一行进度，阶段结束补合计 |
| 进度可取到的信息 | 无（需另开窗口看台账） | 已等 / 剩余预算 / 第几轮 / 最后 HTTP |
| 预算说明 | 硬写拼接，与数字可能不一致 | 同一函数生成 |
| `-VerifyOnly -VerifyReadySec 90` | 通过 | 通过，隔离实例端口 `63633` → HTTP 401，53.9s |

## 0.6.2 — 「点了没反应」：活动台账、冷启动判据、一次动作一个预算

这一版修的是一类**看不见**的故障：引擎在做正确的事，但它在等，而外面没有任何证据说明它在等。
2026-11-23 实测一次命令行重启静默 14 分钟（进程活着、CPU 停在 2.7s、stderr 一个字都没有），
观察者无法区分「还在跑」「卡死」「根本没启动」。另外冷启动时宿主形态会被误判成 web，
于是桌面版 exe 从来没被拉起。

### 引擎（scripts/dsh-restart.ps1）

- **新增活动台账 `activity.json`**（`Write-Activity` / `Get-ActivityPath`）：拿到重启锁就写，
  每推进一个阶段重写一次；等循环里按 2 秒节流刷新心跳。进程一死就没人再写，所以
  「文件很旧」= 没人在跑，不是卡死。只读动作（`-Status` / `-CheckShadowed` /
  `-RepairSharedScope` / `-Record`）不写 —— 它们不能假装有人在干活。
- **两处最长静默补上心跳**：`Test-DesktopVerify` 与 `Test-DeepVerify` 的等待循环、
  `Wait-DesktopHostReady` 与 `Wait-HostReady` 的就绪循环，每轮都写「第几轮 / 已等 Ns /
  剩余预算 / 最后 HTTP」。
- **`-Status` 报「当前动作」**：人读输出新增两行 —— `当前动作`（进行中 / 进程还在但没推进 /
  没人在跑）与 `宿主判据`（`hostKind` 是怎么判出来的）。`-Status -Json` 的 `status` 里
  新增 `activity` 与 `hostKindSource`。
- **一次动作一个预算**（`Set-ActionBudget` / `Get-BudgetLeftSec`）：拿锁之后按本次要跑的阶段
  算总预算，就绪等待、桌面就绪等待、桌面深验证三层全部引用同一个截止时刻。旧版每层各自计
  一个 90s / 150s，一个失败的重启可以合法地静默耗掉七分钟以上；而且每一层都会**重新**开始等。
- **冷启动宿主形态判据**（`Resolve-HostKind`）：顺序改为「运行中的宿主 → `machine.json` 的
  `hostKind` → 启动档案 → web」，并记录来源。旧版只看「有没有进程」和「启动档案里有没有 exe
  字面量」—— 开机后 DSH 还没起来时两条都不成立，这台明确是桌面版的机器被判成 web，
  接着去跑 `cmd /c dsh web --no-open ...`：既没有 exe 被拉起，也没有一行提示。
  `machine.json` 存在时它的 `hostKind` 是这台机器的属性，一份旧启动档案不能推翻它。
  `Resolve-DesktopProfileName` 同样补上 `machine.json` 这级来源。
- **探测器不再把读超时翻倍**（`Invoke-HttpProbe`）：实测一个「accept 后永不响应」的端口
  让一次探测花 10.19s（读超时 5s × 重发 2 次）。现在连不上立刻返回（1.51s），
  连上了但不回只等一个读超时（5.25s），且不再用一个「重连」字样掩盖失败。
- **每一步都落台账**：`Add-Step` 是阶段的唯一出口，台账写在那里，漏掉的调用点也被覆盖。
- 顺带修掉 `Wait-HostReady` 超时文案里的 `$MaxSecs`（不存在的变量，StrictMode 下会抛）。

### 文档与测试

- README.zh.md：§10 状态文件表新增 `activity.json`，`machine.json` 一行补 `hostKind` 与
  「比启动档案更权威」；§13 故障排查新增「点了重启一动不动」与「冷启动形态判错」两段，
  并说明一次动作的预算怎么算。
- `docs/parity-matrix.md`：§15 新增 MP-08 / MP-09 / MP-10 三行（台账、冷启动判据、单预算）。
- `test/parity.mjs`：对应三条探针。**parity 258/258**；`npm test` 全绿（selftest 94 / integration 16）。

### 本机实测

| 项 | 0.6.1 | 0.6.2 |
|---|---|---|
| `-VerifyOnly` 期间的对外可见进度 | 只有「开始」和 70s 后的结果 | 台账 2s 一跳（实测 43 轮 / 59s），`-Status` 同屏显示当前步骤 |
| 冷启动（无宿主 / 无档案 / `machine.json=desktop`） | 判成 `web`，exe 不被拉起 | 判成 `desktop`，来源 `machine.json` |
| accept-但不回的端口探测 | 10.19s | 5.25s |
| 死端口探测 | 3.0s（连接 1.5s + 重发 1.5s） | 1.51s |
| 桌面版重启全程 | 60.0s（无中间进度） | 60.0s，逐阶段 + 台账可观察 |


## 0.6.0 — 安装通道改名 + `install_plugin` 工具

这一版把「装插件不把宿主弄坏」那条链路真正接给模型用，并把它叫成它实际干的事。

### 脚本

- `scripts/dsh-repair.ps1` → **`scripts/dsh-plugin-install.ps1`**。它主要干的是安装/升级/卸载，
  修复（重建共享投影、查遮蔽）只是其中两个单项开关；按「修复」去猜名字的人永远找不到它。
- `scripts/probe-notice.ps1` → **`scripts/probe-plugin-install.ps1`**（它的目标脚本改了名）。
- 新增 **`-OnDemand`**（Install 参数组）：调用方（agent 工具）自己负责停机与拉起，脚本因此跳过会话空窗闸门、
  不再对已停的宿主调 `-Stop`（那会以非零码退出）、也不写续跑通知。健康探测照做且只读，
  宿主没起来就报 `unhealthy`，不当成功。
- 状态文件名前缀改为 `dsh-plugin-install-*`。

### 工具

- 新增 **`install_plugin`**（`lib/install-tools.js`）：`status` / `plan` / `install` / `repair_scope` / `check_shadowed`。
  `install` 的顺序是 工具 `-Status` → 工具 `-Stop` → 脚本 `-OnDemand -Confirm` → 工具 `-Start`，
  `detail.steps` 逐阶段回报，安装在 files 已落盘后即使拉起失败也不掩盖安装结果。
- `plugin_manager`（DSH 自带）保持原样不动：它和 pnpm 之间没有钩子，改写安装目录里的文件会被下次更新覆盖。
  这一步只是给 agent 一条明确的替代路径，观察一轮后再考虑重定向。
- 配置新增 `tools.install`（默认 true）与 `installTimeoutMs`（默认 900000）。

### 文档与测试

- parity 254/254、selftest 93、integration 16（+1 skipped）。
- README 中英、`docs/parity-matrix.md`、`cordis.patch.yml` 同步改名与新增项。

## 0.5.0 — 宿主发现放到 WMI 服务端、探针换成原始 TCP

这一版继续只改「读机器状态的代价」与几个实测踩到的正确性问题。行为语义（401/200 才算就绪、
退出码、终态词、信封必选字段）不变。

### 引擎（scripts/dsh-restart.ps1）

- **宿主发现改为服务端筛选**：`Get-DesktopHostProcesses` 不再按进程名 `Name='DeepSeek Harness.exe'`
  写死，也不再拉全表在 PowerShell 里筛 500 个命令行；改为一条 `CommandLine LIKE '%dsh-desktop-host%'`
  交给 WMI 筛，完整路径仍由正则严格判定。改名的壳同样认得出，一次查询 ~120-270ms。
  `Find-DesktopHostRows` 带进程内缓存，`Resolve-HostKind` / `Resolve-DesktopProfileName` / 实例发现
  不再各查一遍宿主。
- **探针换成原始 TCP**（`Get-HttpStatusCodeDetail`）：直接 `ConnectAsync(...).Wait(预算)` + 写请求 +
  读状态行。HttpClient/HttpWebRequest 两个栈在 3082 上每次要 1.6-2s，而这只是「问几号状态码」。
  三条实测坑写进注释：死端口上同步构造函数会卡 ~14s；`try` 里 return + `finally` 里 Close 会让
  一次成功调用固定多出 2s；读超时必须显式设 `NetworkStream.ReadTimeout`。
- **`Test-WebAuthUrl` 带路径与端口**：token 在 `?token=` 上，只请求 `/` 会让一个有效 token 被判成
  失效（实测把 `launchUrl` 打成 unknown）；持久地址的端口不在当前实例实际监听的端口里时直接判过期，
  不再去探一个死端口。
- **`Read-FileTailText`**：取 boot token 只读日志尾部 64KB（几十 MB 的日志全文 `Select-String` 要 1-2s）。
- **端口挑面**：命中 200 即停，其余端口标 `stage=unprobed`；`Get-AuxPortHint` / `Save-AuxPortHint`
  把实测确认的附件端口（如 CDP 的 4173，也回 200）记进 `state\aux-ports.json`（按 Electron 主进程 pid
  归属，pid 变了就不认），下次标 `stage=skipped` 不探。401 面永不记为附件面。
- **`instances-2` 补探**：第一次采样早退留下的 `unprobed` 端口，用一次 `-ProbeAll` 补探，
  选面结论仍以第一次为准 —— 只为了让建议表学到东西。
- **计时**：`Add-Phase` 同标签累加（不再被后续探针覆盖），基准换成 `Stopwatch`（`Get-Date` 每次 ~1.1ms），
  并把 `ArrayList`/WMI/类型解析的冷启动（~100ms + ~270ms）放到计时之前预热；`phases` 新增
  `start` / `cim` / `history` / `auth-file` / `auth-log` / `instances-2`。
- **`Read-HostServing`**：验证循环里每 800ms 问一次就绪，改用原始 TCP 探针（`Test-HttpServing` 保留原样）。
- **修复（5.1）**：`-Status` 里 `schtasks /Query` 的 stderr 在 `$ErrorActionPreference='Stop'` 下会直接
  中断整个命令 —— 查不到计划任务的机器上 `-Status` 会整行 abort。现在显式收掉 stderr 行。

### 实测（本机，561 个进程，桌面宿主 4 个监听端口）

| 指标 | 0.4.0 | 0.5.0 |
|---|---|---|
| `-Status -Json` 引擎耗时（中位，8 次） | 1.7s（好）/ 3.5s（常见） | 2.7s（中位）/ 13s（宿主自己偶发 10s 慢） |
| `-Status` 人读（中位） | 5.6s | 3.5s |
| 主面探测 | 26-50ms | 3ms（原始 TCP） |
| 宿主发现 | ~1000ms（三处各查一次） | ~400-900ms（一次查询，缓存复用） |

> 13s 那一轮不是脚本的开销：同一轮里 3082 端口自己的读请求就占了 10.05s（宿主偶发慢回），
> 探针按预算等它，与引擎改动无关。

### 测试

`npm test`：88 通过 / 0 失败；parity **254/254**；integration 16 通过（`--with-engine` 17 通过）；
`check-encoding` 在 pwsh 7.6 与 5.1 下 errors=0。


## 0.4.0 — 一次调用只扫一遍机器状态

这一版全部落在「引擎怎么读机器」上：端口表、进程表、宿主 HTTP 面。行为语义
（401/200 才算就绪、退出码、终态词、信封 14 个字段）一个都没动，改的是**读它们的代价**。

### 引擎（scripts/dsh-restart.ps1）

- **新增** `Get-NetstatListenerRows`：全脚本唯一调 `netstat` 的地方，解析成 `{port,pid,host}` 行。
  `Test-PortListening` / `Get-PortOwner` / `Get-ListeningPorts` 全部改读它，进程内缓存 3 秒，
  等待循环里显式 `-Refresh`。以前一次 `-Status` 要扫两三遍整张端口表。
- **新增** `Get-ProcessIndex`：一次 CIM 全表建 `pid → 进程` 字典（同样 3 秒缓存）。
  桌面实例发现不再对每个候选单独 `Get-CimInstance -Filter`。
- **新增** `Invoke-HttpProbe` + `Resolve-HostPort`：按 **200 > 401 > 303 > 其他** 排序逐端口探测，
  命中即返回。连接预算（1.5s）与请求预算（5s）分开 —— 用 HttpClient 一个超时砍两头时，
  3082 端口实测要 1.6-2s，会把一个活着的 200 探成 0（假阴性）。探针显式 `Proxy = $null`，
  不走系统代理。只在「端口通了但给状态码」时 700ms 后重问一次：宿主启动早期会先在
  随机端口上回 404、隔一秒才变 401/200。
- **修复** 端口挑选的稳定性：旧逻辑「第一个回应就算」，桌面宿主同时监听 200 的主面、
  4173 的浏览器调试面、401 的面板面、404 的兜底面 —— 挑到哪个取决于 netstat 顺序。
  现在固定优先级，且 `instances[].probe` 里留下每个端口的实测状态与耗时。
- **修复** 兜底面胜出：401 曾经排在 303 之后，主面读慢一次就会让那个稳定回 404 的兜底端口
  被报成「就绪」。401 现在是第二序位。
- **新增** 分阶段耗时：`-Json` / `-ResultFile` 时信封多一个 `phases` 键
  （prepare / pre-check / host-kind / probe:端口号 / instances / http-probe / auth-url / total），
  人读模式零开销。14 个必选字段与层级不变。
- **新增** `status.pnpmResolved` / `status.cliCmd`：把「实际存在的那个 pnpm.mjs」与
  「安装自带的 dsh.cmd」直接报出来。官方布局在 `resources\runtime` 下，解包后桥把 pnpm 放到
  `resources\app\runtime` 下，外部工具（`scripts\dsh-repair.ps1`）以前自己拼单一路径会拼错。

### 工具

- `scripts/dsh-repair.ps1` 优先用引擎给的 `pnpmResolved`，自己拼路径只作最后兜底。

### 测试与文档

- `test/parity.mjs` 新增 §7 的 D-12…D-15 四条断言（唯一 netstat 扫描点、进程表索引、
  端口优先级与代理绕过、分阶段耗时开关），`docs/parity-matrix.md` 同步。**254/254 行全绿**。
- 本机实测：`-Status -Json` 12.0s → 8.7s（同机、同 561 个进程），单次 `dsh-restart-win -Status`
  7.6s → 5.5s；端口探测从「4 个端口各等超时」变成 300ms 量级。


## 0.3.0 — 机器事实：不再猜安装位置

这一版把「这台机器上 dsh 装在哪、用哪个 node/pnpm」从**推测**改成**探测 + 落盘**，并修掉四个
本机实测暴露的问题。所有改动都不改变 web 宿主的行为与既有退出码 / 终态词。

### 引擎（scripts/dsh-restart.ps1）

- **新增** `Get-DesktopInstallPaths`：桌面版可执行文件从系统登记处反查 —— 卸载登记
  （HKCU/HKLM `Uninstall\*` 的 `DisplayIcon` / `InstallLocation`）、`App Paths`、开始菜单与桌面
  快捷方式的 `TargetPath`。装在非默认目录、App 又正好停着时，这是唯一的确定来源；全部落空
  仍然 fail-closed，不扫盘。
- **新增** `machine.json`（`<StateDir>\machine.json`）作为**第一候选**：`Get-MachineConfig` 读它，
  文件缺失或损坏时返回 `$null` 继续探测，绝不抛。
- **新增** 参数 `-DesktopApp <path>`：显式给出即短路整条探测链；配合 `-Record` 时自动构造启动命令，
  省掉手写引号。
- **新增** `Get-SystemTool`：`netstat` / `taskkill` / `schtasks` / `robocopy` / `cmd` 一律解析到
  `%SystemRoot%\System32`，不再依赖调用方 PATH（git-bash、精简 PATH 的计划任务下行为一致）。
- **修复** `Test-DesktopVerify`：未知 profile 名在桌面版下不再是错误 —— 先按用户层覆盖目录推导，
  与主流程一致（以前会把「profile 名传错」直接报成「真实 profile 不存在」）。
- **修复** `-Status` 的 `HostKind` 降级：宿主停着时 auto 探测曾退化成 `web`，让「重启 → 停止 →
  拉起」的中段看到幻影 `dsh web / 3080`。
- **新增** `status` 字段：`desktopApp` / `desktopAppSource` / `runtimeDir` / `appRoot` / `pnpm` /
  `nodeExe` —— 外部工具（安装器、修复脚本）不必自己推导安装根。

### 工具

- **新增** `scripts/dsh-repair.ps1`：插件安装 / 修复通道（会话空窗闸门 → 快照 → 停机 → `pnpm add` →
  落盘检查 → 查遮蔽 → 拉起 → 健康校验，任一步失败回滚）。它没有自己的路径知识，全部取自
  `dsh-restart-win -Status -Json`，动作全部委托引擎；`-Report <path>` 输出机器可读结果。
- **新增** `scripts/dsh-config.ps1`：一次探测把机器事实写进 `machine.json`（`-Show` 预览 /
  `-Reset` 删除 / `-DesktopApp` 手工指定）。
- **新增** `scripts/probe-notice.ps1`：只读回归 —— AST 抽出续跑通知写入函数，在临时目录里跑三次，
  验证键序、ISO-8601（`Z` 结尾）、`attempts=0`、UTF-8 无 BOM、无 `.tmp` 残留、调用点仍在停机之前。

### 测试与文档

- `test/parity.mjs`：新增 §14「机器事实 / 反硬编码」7 条断言（MP-01…MP-07）；补齐矩阵里
  `X-07` / `X-08` / `X-09` 三条一直缺失的终态词探针；`schtasks` / `taskkill` / `netstat` 的探针
  跟随绝对路径解析更新。**250/250 行全绿**。
- `docs/parity-matrix.md`：新增 §15（MP 组），记录本次四类去硬编码改动与其可执行断言。
- `README.zh.md`：新增 §5.5（`dsh-repair.ps1`）、§5.6（`dsh-config.ps1`）、§8 的安装事实字段表、
  §10 的 `machine.json` 与 `dsh-repair-*` 文件。
