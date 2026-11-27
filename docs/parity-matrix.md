# 功能对照表（parity matrix）· dsh-restart → @brainzombie/dsh-restart-win

> 本文件是「功能零丢失」的**唯一判据来源**（CONTRACT §0.2 / §7）。
> 旧实现仓库：本机归档目录（下称「旧仓库」，已冻结为只读归档；绝对路径见 `.local/audit/hardcode-inventory.md`）。
> 旧仓库路径在本文一律写成 `bin/dsh-restart.ps1:<行>`、`README.md:<行>` 这种相对形式。
> 采集时间：2026-11-14 · 旧引擎版本 `1.0.0-win`（`bin/dsh-restart.ps1:103`）· 2368 行（逐函数通读，无抽样）。
> 本机实况：DSH `0.2.1-rc.5`、profile `web`、端口 `3080` 有监听者、状态目录
> `%LOCALAPPDATA%\dsh-restart`（577 行 `restart-history.jsonl`、83 KB `dsh-restart.log`、已注册计划任务 `DSH Restart`）。

## 0. 使用规则（读表前必看）

1. **一行一个能力**。不合并、不写「同上」。每行必须有旧实现 `file:line`。
2. **「插件目标位置」用「文件 + 符号」表达，不写行号**：移植后行号不可预知，而符号可被机器断言。
   约定：引擎内部一律写 `scripts/dsh-restart.ps1::<函数名>`；**函数名必须与旧引擎逐字相同**
   （`test/parity.mjs` 直接断言「该文件里存在 `function <函数名>`」）。工具面写 `lib/tools.js::<工具名>`。
   **硬约束（parity 自动卡）**：该列**不得**指向 gitignored 路径 —— `.local/`、`node_modules/`、
   `*.log`、`*.result.json`、`dsh-verify.*/`、`runs/` 一律禁止目标指向（新克隆里不存在，CI 上一个
   `Test-Path` 就是 False）。只允许两种形式：① `git ls-files` 能列出来的路径；② `文件::符号`。
   确实没有目标文件时写 `—（无目标文件：不带入，理由见 M-xx）`，解析器会跳过。
3. **「可配置化处理」只有四类取值**：
   - `config.<键>`：变成 `lib/config.js` 的配置键（默认值 = 本机今天的行为，见 CONTRACT §4）；
   - `param`：保留为脚本参数，由工具入参透传，不升级为全局配置；
   - `不变`：纯判定逻辑，不许改（CONTRACT §0「除明确列出的允许本地化项外，任何行为差异都算回归」）；
   - `新增`：仅 CONTRACT §3.2 允许的 `-ResultFile` / `-NoWait`，或 §3.3 的 `-Json` 形状变更。
4. **「验证方式」必须是可执行证据**，不是叙述。`parity:<ID>` 指 `test/parity.mjs` 中该 ID 的断言项
   （断言符号存在 + 行为契约，二者都要）；`本机:` 前缀表示需要本机实跑并贴输出的项。
5. 行 ID 分区：`P`=参数/开关、`F`=主流程与函数、`X`=退出码/终态、`S`=状态文件、`G`=fail-closed 判定、
   `V`=深度验证配方、`D`=进程发现、`T`=计划任务、`N`=续跑通知、`ST`=状态视图、`B`=开发工装、`U`=未文档化/偏差、`M`=必须改变、`WS`=工作区存储预检。

---

## 1. 参数与开关（`bin/dsh-restart.ps1:33-85` param 块全量，一个不落）

| 能力ID | 能力（参数/开关/步骤） | 旧实现位置(旧仓库 file:line) | 插件目标位置 | 可配置化处理 | 验证方式 |
|---|---|---|---|---|---|
| P-01 | `[string]$Profile='web'` DSH profile 名 | bin/dsh-restart.ps1:34；使用 571,978,1279-1281,1293,1719,1871,1892 | scripts/dsh-restart.ps1@param；lib/config.js#profile | config.profile（默认 `web`） | parity:P-01 断言参数存在且默认 `web`；本机 `-Status -Json` → `.profile=='web'` |
| P-02 | `[int]$Port=3080` 宿主端口（同时决定互斥体名） | bin/dsh-restart.ps1:35；936,962,1759,1813,1853,1873,1942,402（任务 XML） | scripts/dsh-restart.ps1@param；lib/config.js#port | config.port（默认 3080） | parity:P-02 断言 `Get-MutexName` 使用 `$Port`；本机 `-Status -Json` → `.port==3080` |
| P-03 | `[string]$BindHost='127.0.0.1'` 探针绑定地址 | bin/dsh-restart.ps1:36；1759,1853,1873,1892 | scripts/dsh-restart.ps1@param；lib/config.js#bindHost | config.bindHost（默认 127.0.0.1） | parity:P-03 断言探针 URL 由 `$BindHost` 拼出；**并断言启动命令不消费它**（见 U-04） |
| P-04 | `[string]$DshHome` 默认 `$env:DSH_HOME` 否则 `$env:USERPROFILE\.dsh` | bin/dsh-restart.ps1:37；1281,1413,1429,1446-1450,1465,1502,1706,1710,1846,1890,1920 | scripts/dsh-restart.ps1@param；lib/config.js#dshHome | config.dshHome（`''` → `%USERPROFILE%\.dsh`） | parity:P-04 断言空值回落表达式；本机 `-Status -Json` → `.dshHome` 为绝对路径且存在 |
| P-05 | `[string]$StateDir` 默认 `$env:DSH_RESTART_HOME` 否则 `%LOCALAPPDATA%\dsh-restart`（**刻意不跟随 PSScriptRoot**，理由见 38-41 行注释） | bin/dsh-restart.ps1:38-42；561,586,594,1714-1716 | scripts/dsh-restart.ps1@param；lib/config.js#stateDir；lib/paths.js | config.stateDir（默认**必须**是 `%LOCALAPPDATA%\dsh-restart`，CONTRACT §4 要求旧日志/启动档案/续跑通知继续可用） | parity:P-05 断言默认表达式；本机 `-Status -Json` → `.stateDir` 指向既有目录且能读到 577 行历史 |
| P-06 | `[int]$ReadySec=90` 重启后就绪等待上限 | bin/dsh-restart.ps1:45；1957,2292 | scripts/dsh-restart.ps1@param | config.readySec（默认 90） | parity:P-06 断言 `Wait-HostReady` 由该参数驱动 |
| P-07 | `[int]$VerifyReadySec=150` 验证实例就绪上限（75s 曾假失败，见 46 行注释） | bin/dsh-restart.ps1:46；1339,1378-1379,1403 | scripts/dsh-restart.ps1@param | config.verifyReadySec（默认 150） | parity:P-07 断言该值进入 `Test-DeepVerify` deadline |
| P-08 | `[int]$GraceSec=3` 优雅停机宽限（实测 `/T` 温和路径从未成功） | bin/dsh-restart.ps1:47；2121,2268 | scripts/dsh-restart.ps1@param | config.graceSec（默认 3） | parity:P-08 断言传给 `Stop-DshInstance` |
| P-09 | `[int]$PortFreeSec=30` 等端口释放上限 | bin/dsh-restart.ps1:48；2123,2280 | scripts/dsh-restart.ps1@param | config.portFreeSec（默认 30） | parity:P-09 断言两次调用点都传该值 |
| P-10 | `[int]$WaitIdleSec=0` >0 则重启前等会话空闲（R11） | bin/dsh-restart.ps1:49；2254 | scripts/dsh-restart.ps1@param；lib/tools.js::win_restart | param `waitIdleSec`（默认 0，不改默认行为） | parity:P-10 断言 `Wait-SessionIdle` 仅在 >0 时被调 |
| P-11 | `[int]$IdleMaxSec=300` 空闲等待硬上限（与 WaitIdleSec 取 Min） | bin/dsh-restart.ps1:50；2254 | scripts/dsh-restart.ps1@param | param `idleMaxSec`（默认 300） | parity:P-11 断言 `[Math]::Min($WaitIdleSec,$IdleMaxSec)` 表达式存在 |
| P-12 | `[switch]$Status` 只读状态 | bin/dsh-restart.ps1:53；2039 | lib/tools.js::win_restart_status；scripts/dsh-restart.ps1@param | 工具 `win_restart_status`（前台只读） | parity:P-12；本机 `win_restart_status` 返回结构体，且进程树无新 node |
| P-13 | `[switch]$DryRun` 演练不写入（不做任何副作用） | bin/dsh-restart.ps1:54；2028,2084,2175,2212,2214-2229,2352 | scripts/dsh-restart.ps1@param；lib/tools.js::win_restart(action=dryRun) | 工具 action 枚举 `dryRun` | parity:P-13 断言 DryRun 分支先于所有写操作；本机 `-DryRun` 前后 `restart-history.jsonl` 行数不变（除终态行） |
| P-14 | `[switch]$Start` 仅拉起（冷启动） | bin/dsh-restart.ps1:55；2072,2079,2141,2175,2257 | lib/tools.js::win_restart(action=start)；scripts/dsh-restart.ps1::main | 工具 action 枚举 `start` | parity:P-14 断言 `$Start` 抑制 dump-config 与续跑通知 |
| P-15 | `[switch]$Stop` 只停机（不深度验证、不写续跑通知、不拉起） | bin/dsh-restart.ps1:56；2078-2136,2352 | lib/tools.js::win_restart(action=stop)；scripts/dsh-restart.ps1::stop 分支（main 内 2078-2136 段） | 工具 action 枚举 `stop` | parity:P-15 断言停机路径无 launch/notice 步骤；本机 `-Stop -DryRun` → rc=0 且 step=dry-run |
| P-16 | `[switch]$Json` 机器可读输出 | bin/dsh-restart.ps1:57；134（抑制逐行输出）,1866-1887 | scripts/dsh-restart.ps1@param；lib/runner.js | **新增（CONTRACT §3.3）**：`-Json` 改为单个对象，固定字段见 CONTRACT:55-56；`status` 动作必须把旧富对象原样嵌在 `status` 键下（CONTRACT:58） | parity:P-16 断言 stdout 只有一个 JSON 文档（`ConvertFrom-Json` 不报 AdditionalTextEncountered）；本机 `-Status -Json` 可解析且 `.status.instances` 存在 |
| P-17 | `[switch]$Fast` 跳过深度验证（有运行实例时默认拒绝停机） | bin/dsh-restart.ps1:58；2028,2175,2203-2211 | scripts/dsh-restart.ps1@param；工具 `fast` | param `fast` | parity:P-17 断言 Fast 分支存在且受 G-06 约束 |
| P-18 | `[switch]$ForceUnverified` 显式承担未验证停机风险（R1 唯一豁免） | bin/dsh-restart.ps1:59；2205,2211 | scripts/dsh-restart.ps1@param；工具 `forceUnverified` | param `forceUnverified` | parity:P-18 断言仅在与 `-Fast` 同用时放行 |
| P-19 | `[switch]$VerifyOnly` 只跑深度验证配方，绝不碰生产实例 | bin/dsh-restart.ps1:60；2027,2042,2352 | lib/tools.js::win_restart_preflight；scripts/dsh-restart.ps1@param | 工具 `win_restart_preflight`（分离执行） | parity:P-19；本机 `-VerifyOnly` 期间端口 3080 监听者 pid 不变 |
| P-20 | `[switch]$Preflight` 同 VerifyOnly（help 文本声称额外做符号链接预检，实际代码与 VerifyOnly 完全同分支，见 U-11） | bin/dsh-restart.ps1:61；2042-2043 | lib/tools.js::win_restart_preflight；scripts/dsh-restart.ps1@param | param `preflight`（与 `verifyOnly` 共用同一分支，不得私自造差异） | parity:P-20 断言 `if ($VerifyOnly -or $Preflight)` 单分支，并在 README 如实描述等价性 |
| P-21 | `[string]$VerifyTempRoot=''` 验证实例临时根（缺省 `$env:TEMP`） | bin/dsh-restart.ps1:62；1262 | scripts/dsh-restart.ps1@param | config.verifyTempRoot（默认空 → `%TEMP%`） | parity:P-21 断言空值回落 `$env:TEMP` |
| P-22 | `[string]$Session` 缺省 `$env:DSH_SESSION_ID` | bin/dsh-restart.ps1:65；576,585,2226,2258 | scripts/dsh-restart.ps1@param；工具 `session` | param `session`（默认空 → 读环境变量） | parity:P-22 断言环境变量回落 |
| P-23 | `[string]$Reason='dsh-restart 安全重启'` 续跑通知原因 | bin/dsh-restart.ps1:66；577,2259 | scripts/dsh-restart.ps1@param；工具 `reason` | param `reason`（默认值保留） | parity:P-23 断言写入 pending-notice.json 的 `reason` 字段 |
| P-24 | `[switch]$Record` 写启动档案 | bin/dsh-restart.ps1:69；2007-2013 | lib/tools.js::win_restart(action=record)；scripts/dsh-restart.ps1::Save-BootRecord | 工具 action 枚举 `record` | parity:P-24；本机 `-Record` 后 `boot-record.json` 的 `recordedAt` 更新 |
| P-25 | `[string]$RecordCommand` 启动命令文本（含 `{PORT}` 占位） | bin/dsh-restart.ps1:70；2008 | scripts/dsh-restart.ps1@param；工具 `recordCommand` | param `recordCommand` | parity:P-25 断言默认文本保留 `{PORT}` 占位语义 |
| P-26 | `[string]$RecordWorkingDirectory` 启动 cwd | bin/dsh-restart.ps1:71；2009 | scripts/dsh-restart.ps1@param；工具 `recordWorkingDirectory` | param | parity:P-26 |
| P-27 | `[switch]$TryCtrlC` 优雅停机（AttachConsole+Ctrl+C，默认关） | bin/dsh-restart.ps1:74；2120,2267；实现 1520-1548 | scripts/dsh-restart.ps1@param；工具 `tryCtrlC` | param `tryCtrlC`（默认 false，行为不变） | parity:P-27 断言默认不进入；本机不实跑（README §八.3 已知未验证） |
| P-28 | `[switch]$ViaTask` 用户入口：交给计划任务执行（脱离进程树） | bin/dsh-restart.ps1:77；1994-2004 | 工具 action `viaTask`；lib/runner.js | 工具 action 枚举 `viaTask` | parity:P-28 断言调用后立即返回且不启动宿主 |
| P-29 | `[switch]$ViaTaskInner` 内部标记：由计划任务拉起时使用（**代码中无任何分支消费它**，语义=「我已在树外」的空标记） | bin/dsh-restart.ps1:78；注释 379-385,466；任务 XML bin/dsh-restart.task.xml:33 | scripts/dsh-restart.ps1@param（必须保留） | param 保留（不改语义） | parity:P-29 断言参数存在且无副作用分支；断言任务 XML 的 Arguments 含它 |
| P-30 | `[switch]$RegisterTask` 注册/更新计划任务 | bin/dsh-restart.ps1:79；1988-1992 | lib/tools.js::win_restart(action=registerTask)；scripts/dsh-restart.ps1::Register-RestartTask | 工具 action 枚举 `registerTask` | parity:P-30 断言 `schtasks /Create /F` 调用 |
| P-31 | `[switch]$UnregisterTask` 删除计划任务 | bin/dsh-restart.ps1:80；1981-1986 | lib/tools.js::win_restart(action=unregisterTask)；scripts/dsh-restart.ps1::main（1981-1986 段） | 工具 action 枚举 `unregisterTask` | parity:P-31 断言 `schtasks /Delete /F` 调用 |
| P-32 | `[string]$TaskName='DSH Restart'` 任务名 | bin/dsh-restart.ps1:81；399,468,476,478,532,1982 | scripts/dsh-restart.ps1@param；lib/config.js#taskName | config.taskName（默认 `DSH Restart`，CONTRACT §4） | parity:P-32 断言上述 6 处全部使用 `$TaskName`；**并断言状态视图不再硬编码**（U-03） |
| P-33 | `[switch]$DoNotTouchDshHome` 内部参数 | bin/dsh-restart.ps1:84（**全文件仅此 1 处引用，无任何使用点**） | scripts/dsh-restart.ps1@param（必须保留） | param 保留（死参数，行为=无；已冻结为契约事实：CONTRACT §3.8 明令不得加新语义） | parity:P-33 断言参数存在；断言函数体无消费分支（若 ps-porter 想给它真实语义，必须先报 Lead，不许私自加行为） |
| P-34 | `#Requires -Version 5.1` + `$ErrorActionPreference='Stop'` + `Set-StrictMode -Version 2.0` | bin/dsh-restart.ps1:31,87,88 | scripts/dsh-restart.ps1 | 不变（StrictMode 2.0 是当年多个真实 bug 的发现工具） | parity:P-34 断言三行都在；`check-encoding.ps1` 双引擎 errors=0 |
| P-35 | 版本常量 `$script:VERSION='1.0.0-win'` | bin/dsh-restart.ps1:103；记录进 568,1868,1889 | scripts/dsh-restart.ps1 | **新增**：版本改为读 `package.json.version`（单一版本源），`-Json` 的 `version` 字段跟随 | parity:P-35 断言 ps1 内不出现写死版本字符串；`node -p require('./package.json').version == 引擎输出 version` |
| P-36 | 点源防呆：被 `. script.ps1` 调用时只警告不执行主流程 | bin/dsh-restart.ps1:98-101 | scripts/dsh-restart.ps1 | 不变 | parity:P-36 断言 `InvocationName -eq '.'` 守卫存在 |

---

## 2. 主流程每一步（`bin/dsh-restart.ps1:1977-2368` 主流程 + 其调用的全部函数）

| 能力ID | 能力（参数/开关/步骤） | 旧实现位置(旧仓库 file:line) | 插件目标位置 | 可配置化处理 | 验证方式 |
|---|---|---|---|---|---|
| F-01 | 入口参数校验与动作分派顺序：UnregisterTask → RegisterTask → ViaTask → Record → 锁 → 引擎闸门 → Status → VerifyOnly/Preflight → 主流程 | bin/dsh-restart.ps1:1980-2061 | scripts/dsh-restart.ps1::main | 不变（顺序即语义：短路径先返回，不触碰实例） | parity:F-01 断言 6 个 early-return 分支的相对顺序；本机 `-Status` 不打印 lock 步骤 |
| F-02 | 互斥锁获取 `Local\dsh-restart-p<port>`（句柄不可继承，R11/R20） | bin/dsh-restart.ps1:1813-1831；2017-2022 | scripts/dsh-restart.ps1::Enter-RestartLock / ::Get-MutexName | 不变（**锁名必须保持 `Local\dsh-restart-p<port>`**，以便与旧引擎互斥、避免新老版本并发重启） | parity:F-02 断言锁名表达式；本机并发跑两次 → 第二个 rc=2 result=locked（历史已有 9 次记录） |
| F-03 | 互斥锁释放（finally 保证） | bin/dsh-restart.ps1:1833-1839；2366-2368 | scripts/dsh-restart.ps1::Exit-RestartLock | 不变 | parity:F-03 断言 `finally { Exit-RestartLock }` |
| F-04 | 引擎能力闸门：验证型重启需要 pwsh 7（`Start-Process -Environment` 需 7.4+、`New-Item -ItemType SymbolicLink`、`System.Net.Http`） | bin/dsh-restart.ps1:536-557；2027-2037 | scripts/dsh-restart.ps1::Get-Ps7RuntimeStatus | config.pwshPath（`''` → 自动，pwsh 优先、回落 powershell.exe，CONTRACT §4） | parity:F-04 断言 `$needsDeepVerify` 表达式；本机用 `powershell.exe` 跑默认重启 → rc=2 `engine-requires-pwsh`（历史 8 次） |
| F-05 | `$needsDeepVerify` 判定：VerifyOnly/Preflight 或「非 Status/Stop/Start/Fast/DryRun 的默认重启」 | bin/dsh-restart.ps1:2027-2028 | scripts/dsh-restart.ps1 | 不变 | parity:F-05 断言表达式逐字符等价 |
| F-06 | Status 分支（只读，不取锁之前就已返回） | bin/dsh-restart.ps1:2039 | lib/tools.js::win_restart_status | — | 见 ST-01..ST-13 |
| F-07 | VerifyOnly/Preflight 分支：符号链接预检 → 深度验证（带重试）→ 失败打印 tail → rc=4 | bin/dsh-restart.ps1:2042-2061 | scripts/dsh-restart.ps1::main | 不变 | parity:F-07 断言分支内顺序（symlink 先于 deep-verify）；本机 `-Preflight` → rc=0 历史 31 次 |
| F-08 | 实例发现步骤（含多监听者警告、无实例 warn/skip 语义按 `-Start` 区分） | bin/dsh-restart.ps1:2063-2073 | scripts/dsh-restart.ps1::Get-DshInstances 调用点 | 不变 | parity:F-08 断言 `instances.Count -ge 1` 分支设置 `$script:TargetPid` |
| F-09 | `-Stop` 与 `-Start` 互斥（同时给 → rc=2 invalid-args） | bin/dsh-restart.ps1:2079-2083 | scripts/dsh-restart.ps1::main | 不变 | parity:F-09；本机 `-Stop -Start` → rc=2 result=invalid-args |
| F-10 | `-Stop -DryRun` 演练分支（只描述将执行的停机） | bin/dsh-restart.ps1:2084-2092 | scripts/dsh-restart.ps1::main | 不变 | parity:F-10 断言 `dry-run` 步骤文案含「不拉起、不写续跑通知」 |
| F-11 | `-Stop` 无目标实例 → result=stopped rc=0（幂等） | bin/dsh-restart.ps1:2093-2097 | scripts/dsh-restart.ps1::main | 不变 | parity:F-11；本机对空闲端口跑 `-Stop` → rc=0 |
| F-12 | `-Stop` 误杀防护：端口占用者不是 node/dsh/bun → rc=12 stop-refused | bin/dsh-restart.ps1:2098-2101；判据 939 | scripts/dsh-restart.ps1::main | 不变 | parity:F-12 断言 `isNode` 检查先于 taskkill；本机用一个非 node 监听器占端口验证（人工 fixture） |
| F-13 | `-Stop` 也走配置操作门禁（README 未写，见 U-11） | bin/dsh-restart.ps1:2103-2116 | scripts/dsh-restart.ps1::Test-ConfigOperationGate 调用点 | 不变 | parity:F-13 断言两个调用点（2104、2239）都存在 |
| F-14 | `-Stop` 判活复核（R14）：目标已消失按已消失处理 | bin/dsh-restart.ps1:2117-2119 | scripts/dsh-restart.ps1::Test-HostAlive | 不变 | parity:F-14 |
| F-15 | `-Stop` 与主流程共用的停机序列：可选 Ctrl+C → `Stop-DshInstance` → 等端口释放 → 报占用者放弃 | bin/dsh-restart.ps1:2120-2128；2267-2286 | scripts/dsh-restart.ps1::Stop-DshInstance / ::Wait-PortFree | 不变 | parity:F-15 断言两处调用顺序一致 |
| F-16 | 组合校验（`--dump-config`）作为**快速失败信号**：exit≠0 且非权限类 → rc=3；权限类（EPERM/EACCES/拒绝访问/cannot resolve profile bundle）→ 判据不明，不拦截 | bin/dsh-restart.ps1:2141-2170（判定 2154-2164） | scripts/dsh-restart.ps1::main | 不变（**不许**升级为安全判据：dsh 任何子命令都会真 boot 并写 cordis.yml） | parity:F-16 断言 `$permish` 正则与 `$dumpOk` 三态（true/false/null）；本机历史 5 次 config-invalid |
| F-17 | 深度验证分支：符号链接预检 → 停机权限预检（elev-gate）→ 深度验证（带一次重试）→ 失败 rc=4 | bin/dsh-restart.ps1:2175-2202 | scripts/dsh-restart.ps1::main | 扩展（desktop 分支对 main pid 做同一闸门） | parity:F-17 断言 elev-gate 在 deep-verify 之前（省掉 60s 白跑） |
| F-18 | 深度验证被跳过（找不到 dsh 本体）→ 仅 warn，不失败 | bin/dsh-restart.ps1:1326；2202 | scripts/dsh-restart.ps1::Test-DeepVerify | 不变 | parity:F-18 断言返回 `$null` 时主流程只 warn |
| F-19 | `-Fast` 分支：跳过深度验证并提示；有实例且无 `-ForceUnverified` → rc=10 | bin/dsh-restart.ps1:2203-2211 | scripts/dsh-restart.ps1::main | 不变 | 见 G-06 |
| F-20 | `-DryRun` 分支：算一次将重建的环境块（只读）→ 打印停机/拉起/续跑通知三条计划 → rc=0 | bin/dsh-restart.ps1:2214-2229 | scripts/dsh-restart.ps1::main | 不变 | parity:F-20 断言 DryRun 调 `Get-RegistryEnvironmentBlock`（**不是** `Sync-ProcessEnvironment`）；本机历史 45 次 dry-run |
| F-21 | 拉起前置检查（闸门 A/B）在**停机之前**执行，失败 rc=11 且旧实例不动 | bin/dsh-restart.ps1:2233-2238 | scripts/dsh-restart.ps1::Test-LaunchPrereq 调用点 | 不变 | parity:F-21 断言调用点行号早于 stop 段；本机可复现：`-Record` 一条不存在的命令 → rc=11 |
| F-22 | 配置操作门禁（R10）：transactions/locks 命中 → rc=5 | bin/dsh-restart.ps1:2239-2251 | scripts/dsh-restart.ps1::Test-ConfigOperationGate | 不变 | 见 G-08 |
| F-23 | 等会话空闲（R11）：`WaitIdleSec>0` 时最多等 `min(WaitIdleSec,IdleMaxSec)`，超时只写日志不阻断 | bin/dsh-restart.ps1:2254；1499-1516 | scripts/dsh-restart.ps1::Wait-SessionIdle | param `waitIdleSec`/`idleMaxSec` | parity:F-23 断言超时返回 false 但主流程继续 |
| F-24 | 停机**之前**写续跑通知（Windows 无 SIGTERM 交付语义，不能指望停机钩子） | bin/dsh-restart.ps1:2256-2260 | scripts/dsh-restart.ps1::main | 不变 | 见 N-03 |
| F-25 | 停机（有目标时）：判活 → 可选 Ctrl+C → `Stop-DshInstance`，失败 rc=6 | bin/dsh-restart.ps1:2262-2270 | scripts/dsh-restart.ps1::Stop-DshInstance | 不变 | 见 G-19 |
| F-26 | 记录「确实停过旧实例」`$script:StoppedPid`（P3 抢救的触发依据） | bin/dsh-restart.ps1:2272-2274 | scripts/dsh-restart.ps1 | 不变 | parity:F-26 断言赋值点仅在停机成功后 |
| F-27 | 回收旧实例遗留的孤儿 DSH 子进程（R22）：父进程已死 + 命令行含 `deepseek-ai` 或 `codegraph` 才杀 | bin/dsh-restart.ps1:2276-2277；实现 1645-1668 | scripts/dsh-restart.ps1::Remove-OrphanDshChildren | 不变 | parity:F-27 断言白名单正则与「父进程存活则跳过」 |
| F-28 | 等端口释放（R5）：既要无 LISTENING，也要真的可 bind；等不到 → rc=7 且**放弃启动** | bin/dsh-restart.ps1:2279-2286；1634-1643 | scripts/dsh-restart.ps1::Wait-PortFree | 不变 | 见 G-10 |
| F-29 | 拉起：环境块重建 → 注入宿主环境 → 解析启动计划 → 追加 banner → 记录 boot-token 基线 → 目录兜底 → `Start-Process` 重定向日志 | bin/dsh-restart.ps1:2288-2289；1682-1756 | scripts/dsh-restart.ps1::Start-DshInstance | 不变（`DSH_UC_PROFILE_NODE_MODULES` / `NPM_CONFIG_LEGACY_PEER_DEPS` / `DSH_HOME` 注入见 M-12） | parity:F-29 断言注入三连与 banner 编码路径（`UTF8Encoding($false)`） |
| F-30 | 就绪校验（R3/R7/R14）：401/200 才算就绪 + 端口归属核对 + 父链解析真实服务器 pid | bin/dsh-restart.ps1:2291-2292；1758-1809 | scripts/dsh-restart.ps1::Wait-HostReady | 不变 | 见 D-08 |
| F-31 | 未就绪回收（R20）：先杀真实服务器 pid 与启动器，再按端口兜底清本次启动链 | bin/dsh-restart.ps1:2293-2310 | scripts/dsh-restart.ps1::main | 不变 | parity:F-31 断言 `killPids` 含 NewPid 与 proc.Id 去重 |
| F-32 | 扫尾（R8/R9）：列出非本次实例的 node 进程，只报不杀 | bin/dsh-restart.ps1:2313-2316；1670-1678 | scripts/dsh-restart.ps1::Get-ResidualChildren | 不变 | parity:F-32 断言不调用 taskkill |
| F-33 | 两层生效提示（R15）：客户端插件由宿主启动时生成分发，需 Ctrl+Shift+R 硬刷新 | bin/dsh-restart.ps1:2318-2319 | scripts/dsh-restart.ps1::main | 不变（文案可本地化，语义不变） | parity:F-33 断言 step 名 `client-plugin` |
| F-34 | 公布访问地址（R23/R24/R25）：等**新** boot token 最多 20s，拿到就落盘并打印；拿不到只 warn、不改退出码 | bin/dsh-restart.ps1:2321-2335；777-806 | scripts/dsh-restart.ps1::Wait-NewHostToken | 不变（等待预算可配置？**否**：CONTRACT 未列，保持 20000ms 常量） | 见 S-05 |
| F-35 | 成功终态 `restarted-ok` rc=0 | bin/dsh-restart.ps1:2336-2337 | scripts/dsh-restart.ps1::Write-Terminal 调用点 | 不变 | 见 X-01 |
| F-36 | catch 全捕获：写 fatal 步骤、可选 DEBUG 转储、按 StoppedPid 走抢救、否则 `aborted:` rc=1 | bin/dsh-restart.ps1:2339-2364 | scripts/dsh-restart.ps1::main | 不变 | 见 G-12 / X-11 |
| F-37 | `finally` 释放锁（任何路径） | bin/dsh-restart.ps1:2366-2368 | scripts/dsh-restart.ps1::Exit-RestartLock | 不变 | parity:F-37 |
| F-38 | 步骤输出格式 `[ ok ] <name,-18> <detail>`，warn 同时进 `$script:Warn`，`-Json` 时静默 | bin/dsh-restart.ps1:131-138 | scripts/dsh-restart.ps1::Add-Step | 不变 | parity:F-38 断言四种 state 的标记（ok/warn/skip/其它=FAIL） |
| F-39 | 审计条目 `{ts,level,message}` 收集，error/warn 同时 Write-Warning | bin/dsh-restart.ps1:140-143 | scripts/dsh-restart.ps1::Write-Audit | 不变 | parity:F-39 |
| F-40 | 终态记录 `Write-Terminal`：设置 Result/ExitCode，写 `dsh-restart.log` 一行 + `restart-history.jsonl` 一个对象，**绝不写 stdout**（曾因 -Json 双文档被 StrictMode 抓出） | bin/dsh-restart.ps1:563-606（记录 schema 566-583；日志行 584-585；fallback 586,594；禁写注释 602-605） | scripts/dsh-restart.ps1::Write-Terminal | 不变 | 见 S-03 / S-04 |
| F-41 | 无 BOM UTF-8 落盘工具（pending-notice.json 必须无 BOM，否则宿主 JSON.parse 抛错） | bin/dsh-restart.ps1:145-150 | scripts/dsh-restart.ps1::New-Utf8NoBom | 不变 | parity:F-41 断言 `UTF8Encoding($false)`；本机读 pending-notice.json 前 3 字节非 EF BB BF |
| F-42 | 拉起即死时的输出回显（诊断）：打印 stdout/stderr 尾部 12 行 + 命中错误行 6 条 | bin/dsh-restart.ps1:1132-1150；调用 1801 | scripts/dsh-restart.ps1::Show-LaunchFailure | 不变 | parity:F-42 断言两处文件都被读；本机可用 `-Record` 指向立即退出的命令复现 |
| F-43 | taskkill 输出压缩（几十行 → 一行统计 + 3 条样本） | bin/dsh-restart.ps1:1550-1569 | scripts/dsh-restart.ps1::Format-KillOutput | 不变 | parity:F-43 断言 4 类成因正则（Access is denied/terminated forcefully/child processes/SUCCESS） |
| F-44 | 日志 banner 追加（拉起时写 profile/port/cmd/cwd，**显式无 BOM UTF-8**：5.1 的 `Add-Content -Encoding UTF8` 会对新建文件写 BOM） | bin/dsh-restart.ps1:1718-1726 | scripts/dsh-restart.ps1::Start-DshInstance | 不变 | parity:F-44 断言使用 `[IO.File]::AppendAllText` + `UTF8Encoding($false)`；本机 `host.out.log` 首字节非 EF BB BF |
| F-45 | boot-token 基线：拉起前记下旧 token 与日志长度，之后只认变化后的 token | bin/dsh-restart.ps1:1728-1739；92-95 | scripts/dsh-restart.ps1::Start-DshInstance | 不变 | parity:F-45 断言 `$script:PrevBootToken` 与 `$script:LogOffsetBeforeLaunch` 都在拉起前赋值 |
| F-46 | 启动目录不存在时退回 `$env:USERPROFILE`（warn，不中断） | bin/dsh-restart.ps1:1741-1745 | scripts/dsh-restart.ps1::Start-DshInstance | 不变 | parity:F-46 |
| F-47 | DEBUG 开关 `$env:DSH_RESTART_DEBUG`：打印 argv 改写细节与异常转储 | bin/dsh-restart.ps1:1055-1058；2341-2348 | scripts/dsh-restart.ps1 | 不变（环境变量名保留，便于排障） | parity:F-47 断言两个 DEBUG 分支存在 |
| F-48 | 中英混排的**输出语言**（步骤文案、提示语） | bin/dsh-restart.ps1:136,464-466,1105,1250-1251,1624-1629,2319,2334 | scripts/dsh-restart.ps1 | 不变（中文对外文案保留；新增英文 README 即可，不改引擎文案） | parity:F-48 断言关键 step 名（lock/discover/launch/ready/url）保持英文稳定 |

---

## 3. 退出码与终态词表（README「退出码」小节 + 代码实际全集）

> **README 的退出码表只有 0-10，缺 11 与 12**（见 U-05）。下表以**代码**为准，共 13 个 rc 值（0–12）、26 个 result 词（X-01..X-26 一行一词）。

| 能力ID | 能力（参数/开关/步骤） | 旧实现位置(旧仓库 file:line) | 插件目标位置 | 可配置化处理 | 验证方式 |
|---|---|---|---|---|---|
| X-01 | rc=0 `restarted-ok`（重启成功） | bin/dsh-restart.ps1:2336 | scripts/dsh-restart.ps1::Write-Terminal('restarted-ok',0) | 不变 | parity:X-01；本机历史 196 次 |
| X-02 | rc=0 `status`（只读状态） | bin/dsh-restart.ps1:2039 | scripts/dsh-restart.ps1::Write-Terminal('status',0) | 不变 | parity:X-02；本机历史 214 次 |
| X-03 | rc=0 `verify-only-ok`（预检/验证通过） | bin/dsh-restart.ps1:2046 | scripts/dsh-restart.ps1::Write-Terminal('verify-only-ok',0) | 不变 | parity:X-03；本机历史 31 次 |
| X-04 | rc=0 `dry-run`（演练；两处产生） | bin/dsh-restart.ps1:2090,2227 | scripts/dsh-restart.ps1::Write-Terminal('dry-run',0)（-Stop 演练与主流程演练两个调用点） | 不变 | parity:X-04；本机历史 45 次 |
| X-05 | rc=0 `stopped`（-Stop 完成/无需停机；两处） | bin/dsh-restart.ps1:2095,2134 | scripts/dsh-restart.ps1::Write-Terminal('stopped',0)（无目标与停机完成两个调用点） | 不变 | parity:X-05；本机历史 25 次 |
| X-06 | rc=0 `task-registered` | bin/dsh-restart.ps1:1990 | scripts/dsh-restart.ps1::Write-Terminal('task-registered',0)（与 X-12 同一 `$(if)` 表达式） | 不变 | parity:X-06；本机历史 4 次 |
| X-07 | rc=0 `task-unregistered`（成功）；`schtasks /Delete` 失败时同一个词带 rc=1，修复后进程退出码与信封 `exitCode` 一致 | bin/dsh-restart.ps1:1984（**旧件缺陷：该分支末尾 `exit 0` 钉死，失败路径进程退出码仍为 0**；新件改为 `exit $script:ExitCode`） | scripts/dsh-restart.ps1::Write-Terminal('task-unregistered', rc)；`rc` 由 `$LASTEXITCODE` 决定（0 或 1）；随后 `exit $script:ExitCode` | 不变（退出码语义修正属缺陷修复，非配置化） | parity:X-07（探针 `PROBES['X-07']` 仍匹配 `Write-Terminal('task-unregistered'`）；本机历史 1 次成功路径；失败路径须用无权限/不存在的任务名构造，断言 `ok=false` 且进程 rc=1 |
| X-08 | rc=0 `via-task-dispatched`（已交给计划任务） | bin/dsh-restart.ps1:2003 | scripts/dsh-restart.ps1::Write-Terminal('via-task-dispatched',0) | 不变 | parity:X-08；本机历史 1 次 |
| X-09 | rc=0 `recorded`（启动档案已写） | bin/dsh-restart.ps1:2012 | scripts/dsh-restart.ps1::Write-Terminal('recorded',0) | 不变 | parity:X-09；本机历史 1 次 |
| X-10 | rc=0 `rescued-after-abort:<原因>`（中止后抢救成功） | bin/dsh-restart.ps1:2359 | scripts/dsh-restart.ps1::Write-Terminal('rescued-after-abort:'+$fatal,0)（动态拼接，前缀必须逐字保留） | 不变 | parity:X-10 断言仅在 `$script:HostUrl` 存在时打印地址后写该终态 |
| X-11 | rc=1 `aborted:<首行异常>`（未捕获异常；终态仍记录） | bin/dsh-restart.ps1:2363 | scripts/dsh-restart.ps1::Write-Terminal('aborted:'+$fatal,1)（catch 兜底；`try` 包裹防二次抛） | 不变 | parity:X-11；本机历史 8 条（含 2 条 StrictMode 事故，见 U-09） |
| X-12 | rc=1 `task-register-failed` | bin/dsh-restart.ps1:1990 | scripts/dsh-restart.ps1::Write-Terminal('task-register-failed',1)（与 X-06 同一 `$(if)` 表达式） | 不变 | parity:X-12；本机历史 2 次 |
| X-13 | rc=2 `locked`（已有另一个重启在跑） | bin/dsh-restart.ps1:2019 | scripts/dsh-restart.ps1::Write-Terminal('locked',2) | 不变 | parity:X-13；本机历史 9 次 |
| X-14 | rc=2 `engine-requires-pwsh`（5.1 引擎拒绝验证型重启） | bin/dsh-restart.ps1:2034 | scripts/dsh-restart.ps1::Write-Terminal('engine-requires-pwsh',2) | 不变 | parity:X-14；本机历史 8 次 |
| X-15 | rc=2 `invalid-args`（-Stop 与 -Start 互斥） | bin/dsh-restart.ps1:2081 | scripts/dsh-restart.ps1::Write-Terminal('invalid-args',2) | 不变 | parity:X-15 |
| X-16 | rc=3 `config-invalid`（组合校验失败，旧实例未动） | bin/dsh-restart.ps1:2169 | scripts/dsh-restart.ps1::Write-Terminal('config-invalid',3)（行内 `; exit 3`） | 不变 | parity:X-16；本机历史 5 次 |
| X-17 | rc=4 `verify-only-failed`（预检/深度验证失败，日志保留） | bin/dsh-restart.ps1:2059 | scripts/dsh-restart.ps1::Write-Terminal('verify-only-failed',4) | 不变 | parity:X-17；本机历史 5 次 |
| X-18 | rc=4 `verify-failed`（重启前深度验证失败，旧实例未动） | bin/dsh-restart.ps1:2199 | scripts/dsh-restart.ps1::Write-Terminal('verify-failed',4) | 不变 | parity:X-18；本机历史 11 次 |
| X-19 | rc=5 `gate-blocked`（配置操作门禁；两处） | bin/dsh-restart.ps1:2113,2248 | scripts/dsh-restart.ps1::Write-Terminal('gate-blocked',5)（-Stop 路径与主流程两个调用点） | 不变 | parity:X-19；本机历史 5 次 |
| X-20 | rc=6 `stop-failed`（停机失败；三处：-Stop 路径、elev-gate、主流程） | bin/dsh-restart.ps1:2121,2189,2269 | scripts/dsh-restart.ps1::Write-Terminal('stop-failed',6)（三处调用，缺一即少一条失败路径） | 不变 | parity:X-20；本机历史 3 次 |
| X-21 | rc=7 `port-busy`（端口未释放→放弃启动；两处） | bin/dsh-restart.ps1:2126,2283 | scripts/dsh-restart.ps1::Write-Terminal('port-busy',7)（-Stop 与主流程两个调用点） | 不变 | parity:X-21（本机未命中过；需构造占用者 fixture） |
| X-22 | rc=8 `ready-failed:<reason>`，reason ∈ `port-owner-mismatch`/`exited`/`timeout` | bin/dsh-restart.ps1:2309；reason 来源 1789,1794,1802,1808 | scripts/dsh-restart.ps1::Write-Terminal('ready-failed:'+$ready.reason,8)（Wait-HostReady 返回三个 reason） | 不变（**reason 词表必须逐字保留**，日志与排障文档依赖它） | parity:X-22 断言三个 reason 字符串、`写终态→exit 8` 相邻、以及失败分支在 exit 前必有 `abort-cleanup` 交代实例去向；本机历史已命中 `exited`/`port-owner-mismatch`/`timeout` 共 4 次（2026-11-23 四次 rc=8） |
| X-23 | rc=9 `via-task-failed`（任务未注册/触发失败） | bin/dsh-restart.ps1:1999 | scripts/dsh-restart.ps1::Write-Terminal('via-task-failed',9) | 不变 | parity:X-23 |
| X-24 | rc=10 `verify-required`（有实例但未验证即要停机，R1 拒绝） | bin/dsh-restart.ps1:2208 | scripts/dsh-restart.ps1::Write-Terminal('verify-required',10) | 不变 | parity:X-24；本机历史 1 次 |
| X-25 | rc=11 `launch-prereq-failed`（拉起前置检查失败，停机前中止） | bin/dsh-restart.ps1:2236 | scripts/dsh-restart.ps1::Write-Terminal('launch-prereq-failed',11) | 不变（README 缺此码，见 U-05） | parity:X-25 |
| X-26 | rc=12 `stop-refused`（端口占用者非 node/dsh/bun，拒绝 -Stop） | bin/dsh-restart.ps1:2100 | scripts/dsh-restart.ps1::Write-Terminal('stop-refused',12) | 不变（README 缺此码，见 U-05） | parity:X-26 |

---

## 4. 状态文件与落盘契约（`%LOCALAPPDATA%\dsh-restart` 全量）

| 能力ID | 能力（参数/开关/步骤） | 旧实现位置(旧仓库 file:line) | 插件目标位置 | 可配置化处理 | 验证方式 |
|---|---|---|---|---|---|
| S-01 | `boot-record.json`（启动档案）：`{recordedAt,command,cwd,profile,port,host,dshHome,note}` 共 8 键，无 BOM；重启时原样重放命令 | bin/dsh-restart.ps1:967-986（schema 974-983；路径 968） | scripts/dsh-restart.ps1::Get-BootRecord / ::Save-BootRecord | config.stateDir 下的固定文件名（不变） | parity:S-01 断言字段名全集与 `ConvertTo-Json -Depth 5`；本机现存文件 8 键、371 字节 |
| S-02 | `pending-notice.json`（续跑通知，宿主侧消费后删除）：`{sessionId,reason,when}`，写 `<DshHome>\.smart-restart\`，**必须无 BOM** | bin/dsh-restart.ps1:1427-1439；路径 1429-1432；编码 145-150 | scripts/dsh-restart.ps1::Write-PendingNotice | 不变 | parity:S-02 断言路径与三键；本机当前目录下无该文件（已被上次启动消费）→ 说明一次性语义 |
| S-03 | `restart-history.jsonl`（审计，每次执行一条 JSON）：16 个字段 `ts/version/result/rc/profile/port/target_pid/new_pid/url/session/reason/host/user/steps/warnings/audit` | bin/dsh-restart.ps1:566-583；写 594-601 | scripts/dsh-restart.ps1::Write-Terminal | 不变（字段名是外部消费契约，`-Json` 变更**不得**改这里） | parity:S-03 断言 16 个键名与顺序；本机 577 行、1.66 MB 全可 `ConvertFrom-Json` |
| S-04 | `dsh-restart.log`（每次执行一行人类可读终态，含中文）：`<iso> [dsh-restart] 终态 result=… rc=… 旧pid=… 新pid=… profile=… port=… session=…` | bin/dsh-restart.ps1:584-593 | scripts/dsh-restart.ps1::Write-Terminal | 不变 | parity:S-04 断言日志行格式串；本机文件 83 KB、末行为 `restarted-ok rc=0` |
| S-05 | `web-auth-url.txt`（访问地址缓存）：`{url,token,pid,port,profile,savedAt,source}`，**含真实 token** | bin/dsh-restart.ps1:610,682-699；读 644-680；校验 701-711；自愈 713-755 | scripts/dsh-restart.ps1::Save-WebAuthUrlRecord / ::Read-WebAuthUrlRecord / ::Resolve-WebAuthUrl | 不变（文件位置/结构不变；内容属隐私，见 M-06） | parity:S-05 断言 7 键与 `source` 三个取值（`url 步（token 变化判据）`/`rescue 步（token 变化判据）`/`host.out.log（-Status 校验后补写）`） |
| S-06 | `host.<hostKind>.out.log` / `host.<hostKind>.err.log`（宿主 stdout/stderr；按形态分文件，桌面 App 会长期占住自己那份） | bin/dsh-restart.ps1:1714-1715,1718-1726,1747-1749；读 1132-1150,628-642,757-775 | scripts/dsh-restart.ps1::Start-DshInstance + `Get-HostLogName`（写入与 -Status 回读共用同一命名） | 不变（文件名由 `Get-HostLogName` 单点生成：`Wait-NewHostToken` 与 `Resolve-WebAuthUrl` 都经它取名，避免一边改名一边读旧名） | parity:S-06 断言命名集中在 `Get-HostLogName` 且 out/err 两个方向都经它取名 |
| S-07 | `dsh-restart.task.xml`（计划任务定义，UTF-16LE 带 BOM 落盘） | bin/dsh-restart.ps1:364-367,445-448,461-462 | scripts/dsh-restart.ps1::Get-TaskXmlPath / ::Save-RestartTaskXml | config.stateDir 下固定文件名（不变） | parity:S-07 断言 `UnicodeEncoding($false,$true)`；本机文件前 4 字节 `FF FE 3C 00` |
| S-08 | `fallback\` 子目录（日志/历史写失败时降级第二落点） | bin/dsh-restart.ps1:586,594 | scripts/dsh-restart.ps1::Write-Terminal | 不变 | parity:S-08 断言两个 foreach 都有 fallback 第二项且 `break` 语义为「首个成功即停」 |
| S-09 | 验证实例临时目录 `dsh-verify.<8hex>`（失败时保留日志供排障） | bin/dsh-restart.ps1:1262-1265；清理 1385-1390；保留 1203,1365 | scripts/dsh-restart.ps1::Test-DeepVerify | config.verifyTempRoot（默认 `%TEMP%`） | parity:S-09 断言目录名模式与 KeepDir 逻辑 |
| S-10 | `symlink-probe\`（符号链接权限探针临时目录，try/finally 删除） | bin/dsh-restart.ps1:1242-1258 | scripts/dsh-restart.ps1::Test-SymlinkPrivilege | 不变 | parity:S-10 断言 finally 中递归删除 |
| S-11 | `<DshHome>\.smart-restart\marker.json`（**只读消费**：pid/lastBootAt/dshVersion，宿主侧写） | bin/dsh-restart.ps1:1884,1897-1898 | scripts/dsh-restart.ps1::Show-Status | 不变（只读，不写） | parity:S-11 断言无写入调用；本机文件 92 字节可解析 |
| S-12 | `safe-mode-cleanup\`（SAFE MODE 处置备份：`safe-mode.bak`/`quarantine\`/`recovery-history\`/`user-PATH.bak.txt`） | SAFE-MODE-排查记录.md:74-84（**运维产物，非引擎写**） | —（无目标文件：不带入，理由见 M-08） | 无 | 人工：`git ls-files` 无该目录 |
| S-13 | `_bak\`（历史版本归档，含 5 个 ps1 + task xml + smoke 备份） | 旧仓库目录约定（README.md:118） | —（无目标文件：不带入，git 历史即版本） | 无 | 人工：`git ls-files` 无 `_bak/` |
| S-14 | `<external-tool>-restart-<ts>.log`（其他工具写入状态目录的同名日志，引擎不读不写） | 本机状态目录实况（不逐个记录） | —（无目标文件：不带入） | 无 | 人工：引擎代码不引用任何外部工具日志名 |

---

## 5. 每个 fail-closed 判定（预检 / 门禁 / Fast 拒绝 / 抢救拉起）

| 能力ID | 能力（参数/开关/步骤） | 旧实现位置(旧仓库 file:line) | 插件目标位置 | 可配置化处理 | 验证方式 |
|---|---|---|---|---|---|
| G-01 | 并发门禁：拿不到互斥体立即 rc=2，**不排队、不重试** | bin/dsh-restart.ps1:2017-2022 | scripts/dsh-restart.ps1::Enter-RestartLock | 不变 | parity:G-01；本机并发两跑，第二个 5s 内 rc=2 |
| G-02 | 引擎门禁：需要深度验证却跑在 5.1 上 → 在**停机之前** rc=2，给出可操作提示 | bin/dsh-restart.ps1:2029-2036 | scripts/dsh-restart.ps1::Get-Ps7RuntimeStatus | 不变 | parity:G-02 断言三项能力检查（PSVersion≥7 + `Start-Process -Environment`） |
| G-03 | 符号链接预检（宿主冷启动的硬前提）：`New-Item -ItemType SymbolicLink` 试一次；失败 → step fail 并给两条修复路径 | bin/dsh-restart.ps1:1233-1259；调用 2043,2176 | scripts/dsh-restart.ps1::Test-SymlinkPrivilege | 不变 | parity:G-03 断言 `symlink-preflight` 步骤名与修复文案要点（开发者模式 / 管理员）；本机 rc=0 通过 |
| G-04 | 符号链接预检的**降级**：探针本身异常时不拦截（交给深度验证给真实结论） | bin/dsh-restart.ps1:1253-1255 | scripts/dsh-restart.ps1::Test-SymlinkPrivilege（catch 分支） | 不变 | parity:G-04 断言 catch 返回 `$true` |
| G-05 | 停机权限预检（elev-gate）：目标令牌打不开 + 自身未提升 → 跳过深度验证直接 rc=6，并给两条出路 | bin/dsh-restart.ps1:2180-2193；判据 1571-1591；P/Invoke 482-529 | scripts/dsh-restart.ps1::Test-StopPermission | 不变 | parity:G-05 断言 `CanQueryTargetToken==1` 的判定与「已跳过深度验证」文案 |
| G-06 | **Fast 拒绝（R1）**：存在运行实例且 `-Fast` 未配 `-ForceUnverified` → rc=10，坚决不停机 | bin/dsh-restart.ps1:2203-2211 | scripts/dsh-restart.ps1::main | 不变（CONTRACT §3.7 明确要求保留） | parity:G-06；本机历史 1 次 verify-required；构造：`-Fast` 且 3080 有监听者 |
| G-07 | 拉起前置闸门 A：启动命令第一个词无法在 PATH 解析 → 停机前 rc=11 | bin/dsh-restart.ps1:1103-1108 | scripts/dsh-restart.ps1::Test-LaunchPrereq | 不变 | parity:G-07 断言先剥离 `cmd/powershell/pwsh /c /d /s` 前缀 |
| G-08 | 拉起前置闸门 B（真实事故换来的）：命令以 pnpm/npm/yarn/bun 开头且 cwd 的 `package.json` 把该名字定义成本地脚本（或存在 `pnpm-workspace.yaml`）→ 停机前 rc=11，并给出正确写法 | bin/dsh-restart.ps1:1110-1128 | scripts/dsh-restart.ps1::Test-LaunchPrereq | 不变 | parity:G-08 断言判据**不依赖** `pnpm-workspace.yaml` 单独成立（README.md:423-426 说明为何改判 package.json scripts） |
| G-09 | 配置操作门禁（R10）：`*.transaction`/`*.transaction.json`/`RECOVERY_REQUIRED*`（depth 2）+ 两个 locks 目录命中 → rc=5 | bin/dsh-restart.ps1:1443-1453；调用 2104,2239 | scripts/dsh-restart.ps1::Test-ConfigOperationGate | 不变 | parity:G-09 断言 3 个 glob + 2 个目录；本机历史 5 次 gate-blocked |
| G-10 | 残留锁归因（只读诊断，不删文件）：owner pid 已死 + 心跳 >30s → 追加「这是残留锁，用 `dsh-config-manager recover-stale-lock` 回收」；任何不确定一律返回 null 不乱报 | bin/dsh-restart.ps1:1455-1497（阈值 1493；心跳 sidecar 1479；owner 存活检查 1476） | scripts/dsh-restart.ps1::Get-StaleEnvLockAdvice | 不变 | parity:G-10 断言 4 条保守返回 null 的路径与 30s 阈值 |
| G-11 | 端口未释放门禁（R5）：等 `PortFreeSec` 后仍不可 bind → **放弃启动** rc=7，绝不制造半残实例 | bin/dsh-restart.ps1:2280-2286；2123-2128 | scripts/dsh-restart.ps1::Wait-PortFree | 不变 | parity:G-11 断言失败分支不含 Start-DshInstance 调用 |
| G-12 | 就绪失败回收（R20）：未就绪 → 杀 NewPid + 启动器 → 按端口兜底清本次启动链 → rc=8 | bin/dsh-restart.ps1:2293-2310 | scripts/dsh-restart.ps1::main | 不变 | parity:G-12 断言回收发生在 `Write-Terminal` 之前 |
| G-13 | **抢救拉起（P3）**：中止落在「旧实例已停」之后 → 尽力拉回一次，成功则 rc=0 `rescued-after-abort:` | bin/dsh-restart.ps1:2350-2362；实现 1930-1975 | scripts/dsh-restart.ps1::Invoke-RescueLaunch | 不变 | parity:G-13 断言触发条件 5 个排除项（-Stop/-DryRun/-Status/-VerifyOnly/-Preflight） |
| G-14 | 抢救的前置约束：端口已有监听者则**绝不再拉第二个**，直接判定已恢复 | bin/dsh-restart.ps1:1942-1945 | scripts/dsh-restart.ps1::Invoke-RescueLaunch | 不变 | parity:G-14 |
| G-15 | 抢救只尝试一次；失败则回收本次尝试的实例并把手工命令写进步骤（不循环、不掩盖） | bin/dsh-restart.ps1:1964-1970 | scripts/dsh-restart.ps1::Invoke-RescueLaunch | 不变 | parity:G-15 断言无 while/重试循环 |
| G-16 | 抢救自身抛异常也必须吞掉并转成失败步骤（已在 catch 里，再抛就没人接） | bin/dsh-restart.ps1:1971-1974 | scripts/dsh-restart.ps1::Invoke-RescueLaunch | 不变 | parity:G-16 |
| G-17 | 深度验证的资源前提：真实 profile 缺 `node_modules` → 立即 fail（`profile-missing-node-modules`）并说清根因，不许报 StrictMode 的变量错误 | bin/dsh-restart.ps1:1289-1296 | scripts/dsh-restart.ps1::Test-DeepVerify | 不变 | parity:G-17 断言 `$vNm` 在 else 分支外声明（旧版曾因只在 else 赋值而崩） |
| G-18 | 组合校验的**误报防护**：EPERM/EACCES/拒绝访问/`cannot resolve profile bundle` 视为「判据不明」而非配置错误 | bin/dsh-restart.ps1:2154-2160 | scripts/dsh-restart.ps1::main | 不变 | parity:G-18 断言 `$permish` 正则四类 |
| G-19 | 停机失败 → rc=6，并区分「权限边界」与「没生效」：Access is denied 时当场打印根因 + 两条出路 + 任务注册状态 | bin/dsh-restart.ps1:1593-1632（边界判定 1620-1630） | scripts/dsh-restart.ps1::Stop-DshInstance | 不变 | parity:G-19 断言 `taskkill` 两次调用都记录真实 rc 与输出 |
| G-20 | 停止权限的假阴性防护：目标已消失时 OpenProcess 也失败，必须判「可终止」而不是「权限不足」 | bin/dsh-restart.ps1:1581-1585 | scripts/dsh-restart.ps1::Test-StopPermission | 不变 | parity:G-20 |
| G-21 | 提权探测本身失败 → 降级为「未知，不拦截」 | bin/dsh-restart.ps1:1579；526-528 | scripts/dsh-restart.ps1::Test-Elevation | 不变 | parity:G-21 |

---

## 6. 深度验证配方（R1/R2/R16，隔离 home 四件套）

| 能力ID | 能力（参数/开关/步骤） | 旧实现位置(旧仓库 file:line) | 插件目标位置 | 可配置化处理 | 验证方式 |
|---|---|---|---|---|---|
| V-01 | 隔离根：`<VerifyTempRoot>\dsh-verify.<8hex>` + 一个空闲端口（`TcpListener` 绑 0 端口取号） | bin/dsh-restart.ps1:1262-1265；831-834 | scripts/dsh-restart.ps1::Test-DeepVerify / ::Get-FreePort | config.verifyTempRoot；端口自动取（不配置） | parity:V-01 断言目录名模式与 `Get-FreePort` 实现 |
| V-02 | 配方 A：profile 顶层小文件（`package.json`/`cordis.patch.yml`/`cordis.yml`/lock）**真拷贝**（宿主每次组装都要重写 cordis.yml，必须落在可写位置） | bin/dsh-restart.ps1:1279-1284 | scripts/dsh-restart.ps1::Test-DeepVerify | 不变 | parity:V-02 断言 `Get-ChildItem -File` 逐个 `Copy-Item` |
| V-03 | 配方 B：`.dsh-module-fallback` **真拷贝且不跟随重解析点**（用 robocopy /sl 或 `Copy-Item -Recurse` 会把 967MB 真实内容抄一遍，实测 23s 未完成） | bin/dsh-restart.ps1:1285-1288；1206-1231 | scripts/dsh-restart.ps1::Copy-TreeWithLinks | 不变 | parity:V-03 断言 `ReparsePoint` 分支重建 junction 且 `continue` |
| V-04 | 配方 C：`profiles\<p>\node_modules` 必须是**真目录** + 逐顶层条目 junction（对 junction 本层做截断写会 EPERM） | bin/dsh-restart.ps1:1297-1305 | scripts/dsh-restart.ps1::Test-DeepVerify | 不变 | parity:V-04 断言先 `New-Item -ItemType Directory` 再逐条目 junction |
| V-05 | 配方 D：预建 fallback 已持有包的 profile 侧投影链接（让宿主 heal 的 `lstatSync` 命中即早返回，幂等） | bin/dsh-restart.ps1:1306-1320 | scripts/dsh-restart.ps1::Test-DeepVerify | 不变 | parity:V-05 断言 `@*` scoped 目录与非 scoped 两条分支 |
| V-06 | 环境注入：`DSH_HOME=<隔离根>`、`DSH_UC_PROFILE_NODE_MODULES=<隔离 node_modules>`（否则临时实例会继承真实 home，把真实 profiles 当成自己的根） | bin/dsh-restart.ps1:1327-1329 | scripts/dsh-restart.ps1::Test-DeepVerify | 不变 | parity:V-06 断言两个键名 |
| V-07 | 启动 argv：`node <bin.js> web --port <free> --host 127.0.0.1 --no-open`，**绝不加 `--profile`**（`web` 就是它的别名，传了会 `unknown option` 且进程不退出→留孤儿） | bin/dsh-restart.ps1:1330-1333 | scripts/dsh-restart.ps1::Test-DeepVerify | 不变 | parity:V-07 断言 argv 中无 `--profile` |
| V-08 | 启动方式：`Start-Process -WindowStyle Hidden -Environment <hashtable> -RedirectStandardOutput/-Error -PassThru`（`-Environment` 需 pwsh 7.4+） | bin/dsh-restart.ps1:1334-1337 | scripts/dsh-restart.ps1::Test-DeepVerify | 不变 | parity:V-08 断言四个参数齐备 |
| V-09 | 就绪判据：只认 **401/200**；404 = 端口已绑但路由未注册（不算就绪）；同时记录日志是否出现 `token=` | bin/dsh-restart.ps1:1339-1355；判据定义 900-920 | scripts/dsh-restart.ps1::Test-HttpServing | 不变（**不许**放宽为「任意状态码」：会假阳性） | parity:V-09 断言 `ready = ($s -eq 401 -or $s -eq 200)`；本机实测 9.4s 出现 404 → 10.4s 变 401（README.md:57） |
| V-10 | 成功返回：`{ok,port,http,logdir}`，并记录「日志已出现 token= / 未出现」 | bin/dsh-restart.ps1:1357-1361 | scripts/dsh-restart.ps1::Test-DeepVerify | 不变 | parity:V-10 |
| V-11 | 失败分类：区分「进程已退出（exit=N）」/「端口已绑但路由未就绪（404）」/「端口无响应」，并保留末 15 行 + 命中错误行 10 条 | bin/dsh-restart.ps1:1364-1381 | scripts/dsh-restart.ps1::Test-DeepVerify | 不变 | parity:V-11 断言三条 reason 分支 |
| V-12 | 回收：进程对象 → 端口占用者（权威）→ 确认端口真的释放后才删目录；未释放则保留目录并 warn | bin/dsh-restart.ps1:1385-1390；1172-1204 | scripts/dsh-restart.ps1::Remove-VerifyInstance | 不变 | parity:V-12 断言 `[ref]$Progress` 与 15s 端口轮询 |
| V-13 | 一次重试：首次未就绪重跑一遍（隔离 home 每次都要跑 config-manager 启动期导出/定时备份，偶发顶到预算；当日 8 次验证有 2 次假失败） | bin/dsh-restart.ps1:1395-1408 | scripts/dsh-restart.ps1::Invoke-DeepVerifyWithRetry | 不变 | parity:V-13 断言最多两次 `Test-DeepVerify` 调用 |
| V-14 | 验证绝不动生产：`-VerifyOnly/-Preflight` 全程不 stop、不 launch、不写续跑通知 | bin/dsh-restart.ps1:2042-2061,2352 | lib/tools.js::win_restart_preflight | 不变 | 本机：预检前后 `Get-PortOwner 3080` 恒为同一 pid |
| V-15 | `-Preflight` 与 `-VerifyOnly` 的**等价性**（help 文本声称有差异，代码同分支） | bin/dsh-restart.ps1:60-61,2042 | scripts/dsh-restart.ps1 | 不变（记录等价，不造差异） | parity:V-15 断言单分支；README 如实写明等价（见 U-11） |

---

## 7. 端口→PID 的进程发现（本机 CIM/tasklist 被拒后的唯一权威）

| 能力ID | 能力（参数/开关/步骤） | 旧实现位置(旧仓库 file:line) | 插件目标位置 | 可配置化处理 | 验证方式 |
|---|---|---|---|---|---|
| D-01 | 端口监听从 `netstat -ano -p TCP` 取 LISTENING 行（`Get-NetTCPConnection` 在本机沙箱不可靠） | bin/dsh-restart.ps1:810-814 | scripts/dsh-restart.ps1::Test-PortListening | 扩展：web 侧不变（**不许**换成 CIM/Get-NetTCPConnection 单一路径）；desktop 侧新增 Get-ListeningPorts 反查宿主端口 | parity:D-01 断言命令行字面量 `netstat -ano -p TCP` |
| D-02 | PID 解析：按空白切分取最后一列；`@()` 强制数组去重排序（单元素管道会退化成标量→曾因 `.Count` 崩溃） | bin/dsh-restart.ps1:816-829（StrictMode 事故注释 820-822） | scripts/dsh-restart.ps1::Get-PortOwner | 不变 | parity:D-02 断言 `@($pids \| Sort-Object -Unique)` 恒返回数组 |
| D-03 | 候选实例形状：`{pid,name,port,isNode,start,ws_mb,handles,source='port-listener'}` | bin/dsh-restart.ps1:927-952 | scripts/dsh-restart.ps1::Get-HostCandidate | 不变（字段名被 `-Status -Json` 消费） | parity:D-03 断言 8 个字段名 |
| D-04 | 进程名二次校验：正则匹配 `node`、`dsh`、`bun` 三者之一，仅作辅证 | bin/dsh-restart.ps1:939 | scripts/dsh-restart.ps1::Get-HostCandidate | 不变 | parity:D-04 断言正则 |
| D-05 | 端口监听者是发现权威（R4）；命令行只用于把 Electron 跑的 `dsh web` shim 的 `isNode` 置真（本机 CLI shim 实测，进程名不是 node） | bin/dsh-restart.ps1:929-933 | scripts/dsh-restart.ps1::Get-HostCandidate | 不变 | parity:D-05 断言 `Get-HostCandidate` 函数体内无 `CommandLine` 读取（`Remove-OrphanDshChildren` 里的 CommandLine 白名单属 D-11，不在本行范围） |
| D-06 | 判活：进程存在 **且** 仍是该端口监听者 | bin/dsh-restart.ps1:959-963 | scripts/dsh-restart.ps1::Test-HostAlive | 不变 | parity:D-06 |
| D-07 | CIM 可用性探测与降级声明（`-Status` 里如实显示「CIM 不可用→以端口监听者为权威」） | bin/dsh-restart.ps1:922-925；1899 | scripts/dsh-restart.ps1::Get-CimAvailable | 不变 | parity:D-07；本机 `-Status` 该行显示降级文案 |
| D-08 | 端口归属核对 + 父链解析（最多 6 跳）：经 shell 包装器启动时以**真实服务器 pid** 作为新实例，否则后续回收杀错进程留孤儿 | bin/dsh-restart.ps1:1766-1791 | scripts/dsh-restart.ps1::Wait-HostReady | 不变 | parity:D-08 断言 `$hop -lt 6` 与 `port-owner-mismatch` 失败分支 |
| D-09 | 「可 bind」判据（R21）：只 bind 不 accept，避免制造 TIME_WAIT；LISTENING 消失但绑不上时不得放行 | bin/dsh-restart.ps1:836-854 | scripts/dsh-restart.ps1::Test-PortBindable | 不变 | parity:D-09 断言 `TcpListener.Start()` + finally `Stop()` |
| D-10 | 残留 node 视图（只报不杀）：除根 pid 外的全部 node 进程及内存 | bin/dsh-restart.ps1:1670-1678 | scripts/dsh-restart.ps1::Get-ResidualChildren | 不变 | parity:D-10（注意 U-08：语义是「全部除此 pid」而非「子进程」） |
| D-11 | 孤儿 DSH 子进程白名单回收：命令行含 `deepseek-ai` 或 `codegraph` **且** 父进程已不存在才杀 | bin/dsh-restart.ps1:1645-1668 | scripts/dsh-restart.ps1::Remove-OrphanDshChildren | 不变 | parity:D-11 断言白名单正则与父进程存活跳过 |
| D-12 | **一次端口表**：`Get-NetstatListenerRows` 是唯一调 `netstat` 的地方，解析成 `{port,pid,host}` 行；`Get-ListeningPorts` 只按 pid 过滤，可传入已取好的行。进程内缓存 3s（`-Refresh` 强制重扫），等待循环每 2s 显式刷新 | 无旧实现（0.4.0 新增） | scripts/dsh-restart.ps1::Get-NetstatListenerRows | 扩展：web 侧行为不变 | parity:D-12 断言只有 `Get-NetstatListenerRows` 一族调用 netstat 字面量、`Get-ListeningPorts` 接受 `$Rows` |
| D-13 | **进程表按 pid 索引**：`Get-ProcessIndex` 一次 CIM 全表建 `pid→进程` 字典（同样 3s 缓存），桌面实例发现不再对每个候选单独 `Get-CimInstance -Filter` | 无旧实现（0.4.0 新增） | scripts/dsh-restart.ps1::Get-ProcessIndex | 扩展 | parity:D-13 断言 `Get-DesktopInstances` 用 `Get-ProcessIndex` 且 `ContainsKey` 判空 |
| D-14 | **宿主 HTTP 面的挑选**：`Resolve-HostPort` 按 `Get-HostFaceRank` 的 401 > 200 > 303 > 其他 排序（宿主自己的面要 token，附件面 4173 永远 200），逐端口以 `Invoke-HttpProbe` 探测（先连一次判活，再用 `Get-HttpStatusCodeDetail` 的原始 TCP 读状态行 —— 天然不走系统代理，没有 `HttpWebRequest`/`HttpClient` 就没有代理解析）。连接预算（`ConnectAsync(...).Wait`）与读预算（`NetworkStream.ReadTimeout`）分开；命中 200 即停，其余端口标 `stage=unprobed`；已知附件端口标 `stage=skipped` 且不探。只在「端口通了但给状态码」时 700ms 后重问一次（宿主启动早期先 404 后 401） | 无旧实现（0.4.0 新增；替代「按 netstat 顺序无脑 GET」） | scripts/dsh-restart.ps1::Resolve-HostPort / Get-HostFaceRank / Get-HttpStatusCodeDetail | 扩展：`Test-HttpServing` 语义不变（401/200 = 就绪） | parity:D-14 断言排序表、重问条件、`skipped`/`unprobed` 两种「没选它」的区分、连接与读两个预算；本机实测 -Status 12.0s → 1.7s |
| D-16 | **桌面就绪与停机（2026-11-23 真机四连修）**：等待循环每轮 `-Refresh` 重读宿主进程表（否则一直看启动前那次 WMI 快照，永远看不到新宿主）；不再用 `$script:NewPid` 过滤候选（那个变量是 Electron 主进程 pid，拿去比宿主子进程 pid 永远不等）；**桌面拉起把 stdout/stderr 重定向到 `host.desktop.*.log`、stdin 不重定向**（不给归属时 Electron 继承启动者那一代控制台的管道，启动者退出后 `console.error` 抛 `write EPIPE` 弹窗；当年「重定向后自己退出」的真凶是句柄继承，已由 `Hide-StdHandleInheritance` 解决）；「上一代宿主」的排除同时看 pid **和** 出生时刻（pid 会被复用） | 无旧实现 | scripts/dsh-restart.ps1::Wait-DesktopHostReady / Start-DesktopApp | 不变 | parity:D-16 断言各自对应一处；本机实测重启连跑两次 `restarted-ok`（118s / 121s） |
| D-17 | **孤儿宿主回收**：`taskkill /T` 只能顺 pid 树杀，而树关系在父进程死掉那一刻就断了 —— 调试连做 11 次重启后，5 个孤儿宿主仍在跑、共占 ~1.8GB、各自占端口、各自跑一份 profile 的后台任务。判据改为按进程身份（命令行含本机 `dsh-desktop-host` 入口）且父 pid 已不在存活进程表里；停机在 `taskkill` 之后做一轮清扫，`-CleanupOrphans` 可单独只清扫不改动当前实例，`-DryRun` 只报告不杀 | 无旧实现（0.6.3 新增） | scripts/dsh-restart.ps1::Get-OrphanDesktopHosts / Stop-OrphanDesktopHosts | 扩展：与 D-11（`Remove-OrphanDshChildren` 白名单回收）互补，一个管 node 子进程、一个管桌面宿主 | parity:D-16 第二条断言；本机实测 5 个孤儿一次回收，当前实例 24612 不受影响 |
| D-18 | **访问地址的自愈补写**：重启后 `web-auth-url.txt` 里必然是上一代记录（pid 对不上当前宿主），而本次 boot 的 `dsh web: http://…?token=…` 行就在被重定向（截断重写）的 `host.desktop.out.log` 里。旧实现先按 pid 预筛，对不上就直接不扫日志 → `-Status` 恒为 `launchUrlState=unknown`，重启步骤里「地址稍后由 -Status 补写」这句承诺永远不成立（本机 token 行实测 60~200s 才打印，必然错过重启时的 20s 窗口）。现在日志候选一律参与，唯一判据是带 token 的 HTTP 探测（有效 → 303；旧 token 必被新实例拒绝），探测通过才落盘 | 0.6.2–0.6.6 本机实现（pid 预筛；0.6.7 移除） | scripts/dsh-restart.ps1::Resolve-WebAuthUrl | 扩展：`-Status` 仍是只读动作，只多写状态目录里的一张缓存 | parity:D-18 断言无 pid 预筛、探测先于落盘；本机实测 `launchUrlState` 由 unknown 转 ok，文件刷新为 pid=28824 / 59729 |
| D-15 | **分阶段耗时**：`-Json` / `-ResultFile` 时记录 `phases`（prepare / pre-check / host-kind / probe:<port> / instances / http-probe / auth-url / total），人读模式零开销 | 无旧实现（0.4.0 新增） | scripts/dsh-restart.ps1::Add-Phase | 扩展：既有 14 个信封字段不变，只多一个键 | parity:D-15 断言 `Add-Phase` 在 `$script:PhasesOn` 为假时直接返回 |

---

## 8. 计划任务脱离执行（Windows 无 setsid 的 P1 路径）

| 能力ID | 能力（参数/开关/步骤） | 旧实现位置(旧仓库 file:line) | 插件目标位置 | 可配置化处理 | 验证方式 |
|---|---|---|---|---|---|
| T-01 | 任务引擎选择：优先 `pwsh.exe`，找不到才回落 `System32\WindowsPowerShell\v1.0\powershell.exe`（任务里写**绝对路径**，任务环境 PATH 可能不含 pwsh） | bin/dsh-restart.ps1:376-391 | scripts/dsh-restart.ps1::Get-RestartTaskEngine | config.pwshPath（`''` → 自动） | parity:T-01 断言 `Get-Command pwsh` 优先与回落路径 |
| T-02 | 引擎回落时明确 warn：`-ViaTaskInner` 的验证型重启需要 pwsh 7.4+，任务会失败并提示 | bin/dsh-restart.ps1:463-467 | scripts/dsh-restart.ps1::Register-RestartTask | 不变 | parity:T-02 断言 warn 分支存在 |
| T-03 | XML 生成（纯函数）：`RegistrationInfo.Description/URI`、`Principals`、`Settings`、`Actions.Exec` | bin/dsh-restart.ps1:393-443 | scripts/dsh-restart.ps1::New-RestartTaskXml；scripts/dsh-restart.task.xml | 不变（**模板文件必须与生成函数逐字同构**，见 T-10） | parity:T-03 断言函数与模板 XML 的标签集合一致 |
| T-04 | 身份与权限：`UserId=<USERDOMAIN>\<USERNAME>`、`LogonType=InteractiveToken`、`RunLevel=HighestAvailable`（凭 Administrators 组拿完整令牌） | bin/dsh-restart.ps1:398,412-418 | scripts/dsh-restart.ps1::New-RestartTaskXml | 不变（用户身份在**运行期**从环境取，不许写死） | parity:T-04 断言三处字面量；本机任务 `Run As User: <本机用户名>`、`Logon Mode: Interactive only` |
| T-05 | 触发与并发：`<Triggers />`（仅按需）、`MultipleInstancesPolicy=IgnoreNew`、`AllowHardTerminate=false`、`ExecutionTimeLimit=PT15M`、`Priority=7` | bin/dsh-restart.ps1:411,419-433 | scripts/dsh-restart.ps1::New-RestartTaskXml（Settings 段）；scripts/dsh-restart.task.xml | 不变 | parity:T-05 断言 `PT15M` 与 `IgnoreNew`；本机 `Stop Task If Runs X Hours and X Mins: 00:15:00` |
| T-06 | 电源/空闲策略：`DisallowStartIfOnBatteries=false`、`StopIfGoingOnBatteries=false`、`RunOnlyIfIdle=false`、`IdleSettings` 双 false | bin/dsh-restart.ps1:421-430 | scripts/dsh-restart.ps1::New-RestartTaskXml（Settings 段）；scripts/dsh-restart.task.xml | 不变 | parity:T-06 断言四个 false 字面量 |
| T-07 | 动作参数：`-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<ps1>" -ViaTaskInner -Profile <p> -Port <port> -DshHome "<home>" -StateDir "<state>"` | bin/dsh-restart.ps1:401-402 | scripts/dsh-restart.ps1::New-RestartTaskXml（Actions.Exec.Arguments）；scripts/dsh-restart.task.xml | 参数值全部来自 config/param（不许写死） | parity:T-07 断言 6 个参数名齐备；本机任务 `Task To Run` 与之一致 |
| T-08 | 工作目录：`<WorkingDirectory>%USERPROFILE%</WorkingDirectory>` | bin/dsh-restart.ps1:403 | scripts/dsh-restart.ps1::New-RestartTaskXml（Actions.Exec.WorkingDirectory）；scripts/dsh-restart.task.xml | 不变（默认用户家目录） | parity:T-08；本机 `Start In: C:\Users\<user>` |
| T-09 | XML 文本转义：只转 `& < >`，**保留双引号原样**（`SecurityElement.Escape` 会把 `"` 变 `&quot;`，与 schtasks 回读产生无谓差异） | bin/dsh-restart.ps1:369-374 | scripts/dsh-restart.ps1::ConvertTo-XmlText | 不变 | parity:T-09 断言只替换三个字符 |
| T-10 | 模板文件 `bin\dsh-restart.task.xml` 必须与生成函数逐字同构（当前是本机实例化后的产物，见 M-04） | bin/dsh-restart.task.xml:1-37 | scripts/dsh-restart.task.xml | **必须改变**：模板改为占位符版本（`{{PS_EXE}}`/`{{SCRIPT}}`/`{{PROFILE}}`/`{{PORT}}`/`{{DSH_HOME}}`/`{{STATE_DIR}}`/`{{USER}}`/`{{CWD}}`）或直接由函数生成、模板仅作 golden fixture | parity:T-10 断言模板中不含用户名、主机名、`C:\Users` 或 `C:\Program Files` 字面量 |
| T-11 | 落盘编码：UTF-16LE **带 BOM**（schtasks 硬要求） | bin/dsh-restart.ps1:445-448 | scripts/dsh-restart.ps1::Save-RestartTaskXml | 不变 | parity:T-11 断言 `UnicodeEncoding($false,$true)` |
| T-12 | 注册/更新：`schtasks /Create /TN <TaskName> /XML <path> /F`，rc 决定 `task-registered`/`task-register-failed` | bin/dsh-restart.ps1:468-471；1988-1992 | scripts/dsh-restart.ps1::Register-RestartTask | 不变 | parity:T-12；本机任务已注册（`Last Result: 0`） |
| T-13 | 触发：`schtasks /Run /TN <TaskName>`，失败 → rc=9 并提示先 `-RegisterTask` | bin/dsh-restart.ps1:474-480；1994-2004 | scripts/dsh-restart.ps1::Invoke-ViaTask | 不变 | parity:T-13 |
| T-14 | 删除：`schtasks /Delete /TN <TaskName> /F` | bin/dsh-restart.ps1:1981-1986 | scripts/dsh-restart.ps1::main | 不变 | parity:T-14 |
| T-15 | 注册状态查询：`schtasks /Query /TN <TaskName>` rc==0 即已注册（供 elev-gate 与 stop-hint 文案用） | bin/dsh-restart.ps1:531-534 | scripts/dsh-restart.ps1::Get-TaskRegistered | 不变 | parity:T-15 |
| T-16 | 脱离语义：任务进程的父是任务计划服务 → 天然不在 DSH 进程树，`-ViaTask` 必须**立即返回**（真正重启在任务里跑） | bin/dsh-restart.ps1:1994-2005；bin/dsh-restart.cmd:9-11 | lib/runner.js（分离执行）+ scripts/dsh-restart.ps1 | 不变 | parity:T-16 断言 ViaTask 分支不含等待；本机历史 1 次 via-task-dispatched |
| T-17 | CLI shim：根目录只放 `dsh-restart.cmd`（跳 `bin\dsh-restart.cmd`），内层 `pwsh` → 回落 `powershell`，**纯 ASCII**（cmd.exe 按 OEM 代码页读文件） | dsh-restart.cmd:1-5；bin/dsh-restart.cmd:1-18 | bin/dsh-restart-win.mjs（CLI）；install.ps1（PATH shim） | **新增**：CLI 名改为 `dsh-restart-win`，shim 内容按 win 版重写；ASCII-only 约束保留 | parity:T-17 断言 `.cmd` 无非 ASCII 字节（pack/check 同款检查）；本机 `dsh-restart -Status` 可用 |

---

## 9. 续跑通知（R12：Windows 无 SIGTERM 交付语义的替代路径）

| 能力ID | 能力（参数/开关/步骤） | 旧实现位置(旧仓库 file:line) | 插件目标位置 | 可配置化处理 | 验证方式 |
|---|---|---|---|---|---|
| N-01 | 会话缺省：`$env:DSH_SESSION_ID`，为空则跳过通知（boot 侧回退 target=primary） | bin/dsh-restart.ps1:65,1428 | scripts/dsh-restart.ps1::Write-PendingNotice | param `session` | parity:N-01 断言空值走 skip 分支 |
| N-02 | `session=auto` → 取 `<DshHome>\sessions` 下最新 `session*.jsonl*` 的目录名 | bin/dsh-restart.ps1:1412-1419,1421-1425 | scripts/dsh-restart.ps1::Get-NewestSessionId / ::Normalize-SessionId | 不变 | parity:N-02 断言过滤模式与 `LastWriteTime` 倒序取 1 |
| N-03 | sessionId 归一：去掉 `session-` 前缀（boot 侧要裸 uuid） | bin/dsh-restart.ps1:1424 | scripts/dsh-restart.ps1::Normalize-SessionId | 不变 | parity:N-03；本机历史中 `session=""` 与实测 uuid 两种都出现过 |
| N-04 | 写 `<DshHome>\.smart-restart\pending-notice.json`：`{sessionId,reason,when}`，**无 BOM**（宿主 `JSON.parse` 遇 BOM 抛错、通知被丢弃） | bin/dsh-restart.ps1:1427-1439；编码 145-150 | scripts/dsh-restart.ps1::Write-PendingNotice | 不变 | parity:N-04 断言路径与三键；本机该文件在启动后被消费删除（一次性） |
| N-05 | 时序：必须**在停机之前**写（不能指望停机钩子）；`-Start`（冷启动）不写 | bin/dsh-restart.ps1:2256-2260 | scripts/dsh-restart.ps1::main | 不变 | parity:N-05 断言调用点在 stop 段之前且受 `-not $Start` 保护 |
| N-06 | 写入失败只 warn（不阻断重启） | bin/dsh-restart.ps1:1435-1437 | scripts/dsh-restart.ps1::Write-PendingNotice | 不变 | parity:N-06 |
| N-07 | 插件侧契约：重启类工具必须**先写通知再分离执行**，并留 `restartDelayMs` 让工具结果先落盘 | CONTRACT.md:90-91（新增约束，无旧实现） | lib/tools.js::win_restart + lib/runner.js | config.restartDelayMs（默认 1500） | 本机：`win_restart` 返回后 `pending-notice.json` 立即出现，1.5s 后宿主进程才开始停 |

---

## 10. 状态视图（`-Status` / `-Status -Json` 字段契约）

| 能力ID | 能力（参数/开关/步骤） | 旧实现位置(旧仓库 file:line) | 插件目标位置 | 可配置化处理 | 验证方式 |
|---|---|---|---|---|---|
| ST-01 | 顶层字段：`version/dshHome/stateDir/profile/port/url` | bin/dsh-restart.ps1:1867-1874 | lib/tools.js::win_restart_status；scripts/dsh-restart.ps1::Show-Status | 不变 | parity:ST-01 断言 6 个键；本机 `-Status -Json` 可解析 |
| ST-02 | 访问地址三件套：`launchUrl`、`launchUrlState`（取值 ok/stale/unknown 三态之一）、`launchUrlDetail` | bin/dsh-restart.ps1:1858-1860,1875-1876；判定 713-755 | scripts/dsh-restart.ps1::Resolve-WebAuthUrl | 不变 | parity:ST-02 断言三态词表 |
| ST-03 | `http`（状态码）/`serving`（有响应） | bin/dsh-restart.ps1:1853,1877-1878 | scripts/dsh-restart.ps1::Test-HttpServing | 不变 | parity:ST-03 |
| ST-04 | `cimOk`（CIM 是否可用，用于解释进程发现降级） | bin/dsh-restart.ps1:1845,1879 | scripts/dsh-restart.ps1::Get-CimAvailable | 不变 | parity:ST-04 |
| ST-05 | `instances[]`（见 D-03 字段） | bin/dsh-restart.ps1:1844,1880 | scripts/dsh-restart.ps1::Show-Status | 不变 | parity:ST-05 |
| ST-06 | `nodeChildren[]`（`{pid,name,ws_mb}`） | bin/dsh-restart.ps1:1864,1881 | scripts/dsh-restart.ps1::Get-ResidualChildren | 不变 | parity:ST-06 |
| ST-07 | `bootRecord`（启动档案原样回显，无记录则 null） | bin/dsh-restart.ps1:1846,1882 | scripts/dsh-restart.ps1::Get-BootRecord | 不变 | parity:ST-07 |
| ST-08 | `lastRestart`（`restart-history.jsonl` 末行解析） | bin/dsh-restart.ps1:1847-1852,1883 | scripts/dsh-restart.ps1::Show-Status | 不变 | parity:ST-08 |
| ST-09 | `marker`（`<DshHome>\.smart-restart\marker.json`，只读） | bin/dsh-restart.ps1:1884 | scripts/dsh-restart.ps1::Show-Status | 不变 | parity:ST-09 |
| ST-10 | 人类可读输出：DSH_HOME/状态目录/目标/HTTP/访问地址/进程发现/实例表/子进程/启动档案/最近重启 | bin/dsh-restart.ps1:1889-1911 | scripts/dsh-restart.ps1::Show-Status | 不变（文案保持，新增英文 README 即可） | parity:ST-10 断言 10 个标签串；本机 `-Status` 逐行比对 |
| ST-11 | 托管形态判定（R13）：Windows 服务（名字含 dsh）> 计划任务 > 未托管 | bin/dsh-restart.ps1:1913-1919（**硬编码 `"DSH Restart"`，见 U-03**） | scripts/dsh-restart.ps1::Show-Status | 不变（改用 `$TaskName`） | parity:ST-11 断言使用 `$TaskName`；本机应显示「计划任务 'DSH Restart' 已注册」 |
| ST-12 | 客户端插件状态：`profiles\web\node_modules\dsh-smart-restart` 是否存在（**硬编码 profile=web，见 U-03**） | bin/dsh-restart.ps1:1920 | scripts/dsh-restart.ps1::Show-Status | 不变（改用 `$Profile`） | parity:ST-12 断言使用 `$Profile`；本机该目录存在 |
| ST-13 | 当前令牌与停机可行性提示（TokenElevationType：1 Default / 2 Full / 3 Limited） | bin/dsh-restart.ps1:1922-1927；482-529 | scripts/dsh-restart.ps1::Test-Elevation | 不变 | parity:ST-13 断言三态文案与配色逻辑 |
| ST-14 | `-Json` 与人类可读二选一，且 `Write-Terminal` **绝不**再向 stdout 写第二个 JSON（曾导致 `-Status -Json` 输出两个文档） | bin/dsh-restart.ps1:1866-1887；602-605 | scripts/dsh-restart.ps1::Write-Terminal | **新增（CONTRACT §3.3）**：`-Json` 统一为单对象；`status` 动作把**本表 ST-01..ST-09 的旧富对象原样**放进 `.status` 键（字段名与层级不变，CONTRACT:58） | parity:ST-14 断言 stdout 只有一份 JSON，且 `.status` 下 9 个旧字段名逐字存在 |

---

## 11. 开发与验证工装（旧仓库自带，必须移植）

| 能力ID | 能力（参数/开关/步骤） | 旧实现位置(旧仓库 file:line) | 插件目标位置 | 可配置化处理 | 验证方式 |
|---|---|---|---|---|---|
| B-01 | `check-encoding.ps1`：UTF-8 BOM 校验（1/3）、纯 LF 校验（2/3）、pwsh7+PS5.1 双引擎 `Parser::ParseFile errors=0`（3/3），全过打印 OK exit 0，任一失败 exit 1 | bin/check-encoding.ps1:1-296（BOM 116-122；换行 124-146；双引擎 148-287；结论 291-296） | scripts/check-encoding.ps1 | 不变（CI 与本地同一入口；`-Path` 参数保留） | 本机：`pwsh -File scripts/check-encoding.ps1` → `OK` rc=0；`powershell.exe -File …` 同样 rc=0 |
| B-02 | `pack.ps1`：① 安全闸（安装副本比交付副本新则 exit 2，防静默覆盖线上修复）② 补 BOM ③ `.cmd` 纯 ASCII 校验 ④ 双引擎语法 ⑤ 同步 ⑥ 跑 smoke | bin/pack.ps1:1-92（安全闸 36-47；BOM 49-54；ASCII 56-62；双引擎 64-73；同步 75-82；smoke 84-89） | scripts/check-encoding.ps1（承接 ②③④ 检查能力）；.github/workflows/ci.yml（承接 ⑥）；pack.ps1 本体不移植（⑤ 同步语义消失，见 M-09） | **必须改变**（见 M-09） | 人工：CI 里等价命令存在；`git ls-files` 无 `pack.ps1` |
| B-03 | `smoke.ps1`：5 个只读用例（无实例 Status / 有实例 Status / Status -Json / DryRun / Preflight），并过滤「最近一次重启」行避免历史误伤 | bin/smoke.ps1:1-89（用例 55-80；过滤 32-35） | test/parity.mjs（读路径断言） | 不改语义；用例必须以「无实例端口」参数化 | 本机：`pwsh -File test/…` 等价 5 用例全 PASS（旧版实测全通过） |
| B-04 | `audit-profile.ps1`：只读复刻 DSH bundle 解析，列出解析不到的 bundle（`cannot resolve profile bundle` 的根因定位），exit 3/0 | bin/audit-profile.ps1:1-106（解析规则 26-45；锚点 47-51；判定 61-74；exit 106） | scripts/audit-profile.ps1（ps-porter 已移植） | 不变（`-Profile`/`-DshHome` 参数化） | 本机：`pwsh -File scripts/audit-profile.ps1 -Profile web` → 列出解析成功数，exit 0；parity:B-04 断言该文件存在且含 `-Profile`/`-DshHome` 两个参数 |
| B-05 | 双引擎可解析性约束（PS 5.1 无 BOM 时按 GBK 解析含中文脚本 → 69 个语法错误，而 pwsh 7 正常） | README.md:71-85,142-159 | scripts/check-encoding.ps1 + .github/workflows/ci.yml | 不变（编码约束不暴露为配置） | 本机：`pwsh -File scripts/check-encoding.ps1` 与 `powershell.exe -File scripts/check-encoding.ps1` 都必须打印 `OK` 且 rc=0（同 B-01 的双引擎断言） |

---

## 12. README 未记载 / 与实现有偏差的能力（单列，禁止并入其他行）

| 能力ID | 能力（参数/开关/步骤） | 旧实现位置(旧仓库 file:line) | 插件目标位置 | 可配置化处理 | 验证方式 |
|---|---|---|---|---|---|
| U-01 | **整套环境块重建**（继承底 + machine 层 + user 层分层展开；PATH machine 在前去重；`REG_EXPAND_SZ` 分层展开时机）。README 完全未记载，却是「setx 改动能否到达新宿主」的唯一机制 | bin/dsh-restart.ps1:155-328（分层 155-193；展开 195-223；构造 232-328） | scripts/dsh-restart.ps1::Get-RegistryEnvironmentBlock | 不变（纯只读重建；DryRun 也调它） | parity:U-01 断言三层构造顺序与 PATH 去重；本机 `-DryRun` 打印「环境块：N 项（继承底/覆盖 machine/user/跳过）」 |
| U-02 | **身份校正**：`USERNAME`/`USERDOMAIN` 不在注册表里，用令牌身份覆盖（实测遇到过 `USERNAME=SYSTEM` 而真实身份是普通用户） | bin/dsh-restart.ps1:347-358 | scripts/dsh-restart.ps1::Sync-ProcessEnvironment | 不变 | parity:U-02 断言 `WindowsIdentity::GetCurrent().Name` 分割赋值 |
| U-03 | 两处硬编码偏差：`Show-Status` 用字面量 `"DSH Restart"`（不跟 `$TaskName`）、用字面量 `profiles\web\...dsh-smart-restart`（不跟 `$Profile`） | bin/dsh-restart.ps1:1916,1918,1920 | scripts/dsh-restart.ps1::Show-Status | 不变（改为参数化） | parity:U-03 断言无字面量残留 |
| U-04 | `-BindHost` **不参与启动命令**：宿主绑哪里由 boot-record/DEFAULT_LAUNCH 决定，`-BindHost` 只影响探针 URL 与状态显示（已冻结为接口事实：CONTRACT §3.8） | bin/dsh-restart.ps1:36,126,1002,1015 对比 1759,1853,1873 | scripts/dsh-restart.ps1 + docs/migration.md | config.bindHost（须在文档写明该边界） | parity:U-04 断言启动 argv 不含 `$BindHost`；文档写明「改 bindHost 不会改宿主监听」 |
| U-05 | README 退出码表缺 **11**（launch-prereq-failed）与 **12**（stop-refused）→ 已冻结为契约事实（CONTRACT §3.9：以代码为准，新文档必须补齐 0–12 与 26 个终态词） | README.md:212-226 对比 bin/dsh-restart.ps1:2236,2100 | README.md / README.zh.md（docs-writer 修） | 不变 | 人工：README 退出码表含 0-12 全量；`test/parity.mjs` 断言码表 = X-01..X-26 的 rc 集合 |
| U-06 | `-Json` 形状由 CONTRACT §3.3 重定义（旧版是「状态对象」，字段与 history 记录不同）。**已定案（2026-11-14 Lead 裁决）**：固定字段 **13 个**（契约原文「14 个」系笔误，§3.3 已改为 13）；`status` 动作必须把旧富对象原样嵌在 `status` 键下（§3.3 第 2 条），消费方不得从 `steps[]` 反推 status | bin/dsh-restart.ps1:1866-1887 对比 CONTRACT.md:55-61 | lib/runner.js + scripts/dsh-restart.ps1 | **新增**（允许的破坏性变更，须迁移说明） | parity:U-06 断言 13 个固定字段齐备、`.status` 嵌套保留旧富对象（ST-01..ST-09 字段名逐字存在）；`docs/migration.md` 说明旧消费方改法 |
| U-07 | `-Stop` 也会执行配置操作门禁（README 只说「只停机」） | bin/dsh-restart.ps1:2103-2116 | scripts/dsh-restart.ps1::main | 不变 | parity:U-07 |
| U-08 | `Get-ResidualChildren` 语义是「除根 pid 外的**全部 node 进程**」，不是「子进程」；`-Status` 里作为 `nodeChildren` 暴露 | bin/dsh-restart.ps1:1670-1678,1864 | scripts/dsh-restart.ps1::Get-ResidualChildren | 不变（**不得**为了名实相符改行为） | parity:U-08 断言只遍历 `Get-Process -Name node` |
| U-09 | StrictMode 事故留痕：历史 8 条 `aborted:` 中含 2 条 `找不到属性 "Count"` / 3 条 `找不到属性 "tail"` —— 这是「空数组被解包成 $null」与「catch 返回对象无 tail」的两次真实崩溃 | bin/dsh-restart.ps1:820-822,2048-2054；本机 restart-history.jsonl | test/parity.mjs（回归用例） | 不变（回归必须锁住） | parity:U-09 构造 4 个回归断言：无实例 Status、VerifyOnly 失败路径、Get-PortOwner 单元素、Get-ResidualChildren 空结果 |
| U-10 | 互斥体真名是 `Local\dsh-restart-p<port>`，而步骤文案写 `Local\dsh-restart-<port>`（少一个 `p`，纯文案不一致） | bin/dsh-restart.ps1:1813 对比 2018,2022 | scripts/dsh-restart.ps1 | 不变（**锁名**保持，仅修文案可选项） | parity:U-10 断言锁名含 `-p`；文案若改须报 Lead |
| U-11 | `-Preflight` 与 `-VerifyOnly` 代码等价（help 文本暗示 Preflight 额外做符号链接预检，实际两者都做）→ 已冻结为契约事实（CONTRACT §3.8：文档如实写等价，禁止为「看起来有区别」加行为） | bin/dsh-restart.ps1:60-61,2042-2043 | scripts/dsh-restart.ps1 | 不变 | parity:U-11（同 V-15） |
| U-12 | `restart-history.jsonl` **无轮转**：本机已 577 行 / 1.66 MB，随使用无限增长 | bin/dsh-restart.ps1:594-601 | scripts/dsh-restart.ps1::Write-Terminal | 不变（新增轮转属行为变更，须报 Lead 批准；不得私自加） | 人工：本机文件增长曲线记录在 `.local/audit/`；矩阵不含轮转能力 |
| U-13 | `-Status` 的 `url` 字段是**无 token** 的裸地址 `http://<bind>:<port>/`，带 token 的在 `launchUrl` | bin/dsh-restart.ps1:1873-1875 | scripts/dsh-restart.ps1::Show-Status | 不变（避免 token 出现在随手复制的位置） | parity:U-13 断言两个字段语义不同 |
| U-14 | 5.1 下 `Add-Content -Encoding UTF8` 新建文件会写 BOM（pwsh 7 不写）→ 引擎对**必须无 BOM** 的文件一律走 `.NET` + `UTF8Encoding($false)` | bin/dsh-restart.ps1:1718-1726；145-150 对比 590,598 | scripts/dsh-restart.ps1 | 不变 | parity:U-14 断言 pending-notice/banner 走 .NET 路径；history/log 允许 Add-Content |
| U-15 | `host.out.log` 的 token 抓取必须用 `Select-String`（`[IO.File]::ReadAllLines` 在宿主持有写句柄时会抛共享冲突） | bin/dsh-restart.ps1:628-642（注释 631-633）；757-775 | scripts/dsh-restart.ps1::Get-HostAuthUrlRecord / ::Get-AppendedText | 不变 | parity:U-15 断言 `FileShare::ReadWrite` 与 `Select-String` |

---

## 13. 必须改变或不带入（去本机化清单，交 ps-porter / docs-writer / privacy-auditor 执行）

> 判据：CONTRACT §4 末段「脚本内**禁止**出现：用户名、本机磁盘根下的归档目录、主机名、真实 token、真实 session id、
> 任何 `%LOCALAPPDATA%` 之外的绝对个人路径」。
> 分组：**代码内必须改** = M-01..M-05、M-10..M-13；**仓库内容必须不带入/重写** = M-06..M-09、M-14。
>
> **本表脱敏约定（重要）**：本文件是**要发布的** tracked 文件，因此表格里不写真值 ——
> 用户名写 `<本机用户名>`、主机名写 `<本机主机名>`、家目录写 `C:\Users\<user>`、session 写 `<session-id>`。
> **逐字原值 + 精确行号**放在 `.local/audit/hardcode-inventory.md`（gitignored，不随仓库发布）；
> 机器扫描用的词表放在 `.local/audit/redaction-terms.txt`。
> ps-porter 执行本表时读那份 inventory 定位，改完用同一词表自检。

| 能力ID | 能力（参数/开关/步骤） | 旧实现位置(旧仓库 file:line) | 插件目标位置 | 可配置化处理 | 验证方式 |
|---|---|---|---|---|---|
| M-01 | `.EXAMPLE` 注释里的示例路径是本机绝对路径（`C:\Users\<user>\Documents\<repo>\tools`）→ 改成 `%USERPROFILE%` 或 `<repo>`，示例命令改用全局 `dsh`（该目录已不存在，`pnpm dsh` 形态已作废） | bin/dsh-restart.ps1:29 | scripts/dsh-restart.ps1 头部注释 | 文字改写（无行为） | 扫描词表（`.local/audit/redaction-terms.txt`）对 `scripts/**` 零命中；`git ls-files` 全文扫描同样零命中 |
| M-02 | 注释里用**具体端口数字**叙述（三处：`权威判据 = 端口 <port> 的监听者…` / `例如从 <old-port> 迁到 <port>` / `若 <port> 仍被本次启动链…`）→ 改为 `$Port` 泛化表述（真实端口字样不进仓库，行号见左列） | bin/dsh-restart.ps1:930,1031,2077,2300 | scripts/dsh-restart.ps1 注释 | 文字改写（无行为） | 端口字面量仅允许出现在默认值表达式（P-02）与文档示例里；`scripts/**` 注释中零命中 |
| M-03 | 任务名在两处被写死成 `"DSH Restart"`（不跟 `$TaskName`）→ 统一 `$TaskName` | bin/dsh-restart.ps1:1916,1918 | scripts/dsh-restart.ps1::Show-Status | 参数化（默认值仍 `DSH Restart`） | parity:U-03 |
| M-04 | **任务模板文件**含本机实例化结果：`<UserId><本机主机名>\<本机用户名></UserId>`、`C:\Program Files\PowerShell\7\pwsh.exe`、`C:\Users\<user>\AppData\Local\dsh-restart\bin\dsh-restart.ps1`、`-DshHome "C:\Users\<user>\.dsh"`、`-StateDir "C:\Users\<user>\AppData\Local\dsh-restart"`、`<WorkingDirectory>C:\Users\<user></WorkingDirectory>` → 模板改占位符（`{{USER}}`/`{{PS_EXE}}`/`{{SCRIPT}}`/`{{PROFILE}}`/`{{PORT}}`/`{{DSH_HOME}}`/`{{STATE_DIR}}`/`{{CWD}}`），运行期由 `New-RestartTaskXml` 生成真实值 | bin/dsh-restart.task.xml:10,32,33,34 | scripts/dsh-restart.task.xml | 模板参数化（行为不变：生成结果与今天一致） | 扫描词表对 `scripts/dsh-restart.task.xml` 零命中；本机 `-RegisterTask` 后生成物与旧任务 `schtasks /Query /XML` 逐字段一致 |
| M-05 | 版本号写死 `1.0.0-win`，与 package.json 双源 → 引擎版本改读 `package.json.version`（`-Json.version` 跟随） | bin/dsh-restart.ps1:103 | scripts/dsh-restart.ps1；lib/paths.js | 单一版本源 | parity:P-35 |
| M-06 | **真实 token / 授权 URL**：`web-auth-url.txt`（`url`/`token` 两字段）、`restart-history.jsonl` 的 `url` 字段、`dsh-restart.log` 若含地址 → 一律不进仓库；测试夹具只允许明显假值（`token=test-token-not-real`） | 本机 `%LOCALAPPDATA%\dsh-restart\web-auth-url.txt`（265 字节）；bin/dsh-restart.ps1:575,689-690,2329 | docs/migration.md | 内容隔离（不改代码行为；逐字取证清单不进仓库、不进目标列） | `git ls-files \| xargs grep -l 'token=[A-Za-z0-9_-]\{16,\}'` 无命中；privacy-auditor 机器扫描报告 |
| M-07 | **真实 session id**（一个本机 uuid 曾写进操作卡与示例表）：示例一律 `<session-id>`；夹具用 `00000000-0000-0000-0000-000000000000` | 重启操作卡.md:20；bin/dsh-restart.ps1:2226 文案 | docs/migration.md | 内容隔离（夹具 uuid 一律用全零占位） | 用同一词表扫描（见第 5 节 `.local/audit/redaction-terms.txt`）；`docs/` 内 uuid 形状仅允许占位符 |
| M-08 | **运维记录四件套**（`重启操作卡.md` 227 行、`目录选择器修复记录.md` 152 行、`SAFE-MODE-排查记录.md` 97 行、`MCP接入记录.md` 172 行）通篇本机实况（真实 pid、旧端口、`<主机名>\<用户名>`、`Administrators` 组、本机插件名与版本）→ **不带入仓库**。若要保留知识价值，只能改写为无本机事实的通用排障章节（由 docs-writer 决定，且必须过 privacy 扫描） | 重启操作卡.md:1-227；目录选择器修复记录.md:1-152；SAFE-MODE-排查记录.md:1-97；MCP接入记录.md:1-172 | —（无目标文件：不带入；若重写则落到 docs/troubleshooting.md） | 内容隔离 | `git ls-files` 无这四个文件；若重写，扫描词表零命中 |
| M-09 | `pack.ps1` 的「交付副本 ↔ 安装副本」同步语义在插件仓库里不存在（安装走 npm/pnpm，源仓库即真源）→ 不移植该脚本；只把它 ②③④⑥ 的**检查能力**并入 `scripts/check-encoding.ps1` + CI | bin/pack.ps1:1-92（尤其 36-47 安全闸、75-82 同步） | .github/workflows/ci.yml + scripts/check-encoding.ps1 | 结构性变更（须在 docs/migration.md 说明「改完脚本跑 check-encoding，不再有 pack 同步」） | `git ls-files` 无 `pack.ps1`；CI 里存在 BOM/LF/双引擎三条检查 |
| M-10 | `$env:DSH_UC_PROFILE_NODE_MODULES` / `$env:NPM_CONFIG_LEGACY_PEER_DEPS` 是本机 npm/pnpm 生态的 workaround（修 dsh-update-checker 不写 package.json/lock 与 ERESOLVE）→ **保留**（属行为，不许删），但必须在 README 说明其作用与「只写进程级、不写用户级」的原因，并允许用配置关掉 | bin/dsh-restart.ps1:1693-1711 | scripts/dsh-restart.ps1::Start-DshInstance；README.md | 建议 config.injectHostEnv（默认 true = 今天行为）；**默认值不许变** | parity:M-10 断言两个变量名与「只写 Process 作用域」；README 有对应小节 |
| M-11 | `Get-DshEntry` 的候选**只有三条、且全是通用路径**（`%APPDATA%\npm\node_modules\@deepseek-ai\dsh\lib\bin.js` → `%ProgramFiles%\nodejs\node_modules\…` → `Get-Command dsh` 同级 `node_modules\…`），不含本机硬编码，因此**不需要改变**。**校正**：矩阵早前写的「漏掉自定义 npm prefix、应追加 `npm prefix -g`」是原描述高估 —— 旧实现根本没有该候选（`grep 'npm prefix'` 旧新两边均为 0），新实现与旧实现逐行一致，不得据此新增行为 | bin/dsh-restart.ps1:1154-1170（三条候选 1161,1162,1163-1167） | scripts/dsh-restart.ps1::Get-DshEntry | 不需要改变（保持三条候选与顺序；CONTRACT §3.6 只允许把本机事实参数化，不许加判定） | parity:M-11 断言三条候选存在且顺序不变，并断言**不含** `npm prefix -g`（防止把本行的校正误读成要求） |
| M-12 | 默认值矩阵（`profile=web` / `port=3080` / `bindHost=127.0.0.1` / `taskName=DSH Restart` / `stateDir=%LOCALAPPDATA%\dsh-restart` / `readySec=90` / `verifyReadySec=150` / `graceSec=3` / `portFreeSec=30`）→ **必须作为 config 默认值原样保留**（CONTRACT §4：默认值 = 本机今天的行为） | bin/dsh-restart.ps1:34-50,81 | lib/config.js | config 默认值 | parity:M-12 断言 9 个默认值逐一相等；`node -e` 打印 config 默认值贴证据 |
| M-13 | 新增两个参数（**唯一允许的增量**）：`-ResultFile <path>` 分离模式结果落盘、`-NoWait` 不停留前台（避免宿主死后子进程被连带清理） | bin/dsh-restart.ps1:563-606（`Write-Terminal` 把终态落盘，是「结果要能被取回」的现有等价物）、1994-2004（`-ViaTask` 立即返回，是「不停留前台」的现有等价物）；参数本身为契约新增（CONTRACT §3.2） | scripts/dsh-restart.ps1@param + lib/runner.js | 新增 | parity:M-13 断言两参数存在且不被任何既有分支消费；本机分离跑一次后 `-ResultFile` 内容可 `JSON.parse` |
| M-14 | 名字与工具面（包 `@brainzombie/dsh-restart-win`、CLI `dsh-restart-win`、工具前缀 `win_restart`、cordis row id `dsh-restart-win`） | bin/dsh-restart.cmd:1-18（旧 CLI shim，被 `dsh-restart-win` 取代）；命名为契约新增（CONTRACT §1） | package.json / cordis.patch.yml / lib/tools.js | 新增 | `dsh --profile web --dump-config` 可见 `dsh-restart-win` 行；工具名不与 `smart_restart` 冲突 |

---

## 14. 覆盖率自检（停止条件的机器可核部分）

### 14.1 README 功能小节 → 矩阵行

| README 小节 | 覆盖行 |
|---|---|
| 一句话现状 / 一、环境探测结论（6 条关键事实） | U-01, U-02, V-09, V-07, D-01, B-05, G-03 |
| 二、选型（5 个决策） | T-16, N-05, D-01, S-01, F-29 |
| 三、目录与文件（状态根 + 6 个文件 + _bak） | S-01..S-08, S-13, B-01..B-04, T-17 |
| 三、改脚本工作流（pack/check-encoding） | B-01, B-02, M-09 |
| 三、已知易踩的 PowerShell 坑（空数组解包） | U-09, D-02 |
| 四、快速上手（12 条命令示例） | P-12..P-31, X-01..X-26 |
| 四、退出码（0-10） | X-01..X-24（+ U-05 指出缺 11/12） |
| 五、符号链接权限（机器级阻塞项 + 两条修复） | G-03, G-04, X-17, V-14 |
| 六、与设计文档的偏差（5 条）+ 深度验证配方 | D-05, D-01, V-02..V-05, F-16, V-07 |
| 七、验收清单 1-16 | 1→ST-01..ST-13；2→G-03；3→V-09/X-18；4→F-16/X-16；5→F-21/F-22/F-25/F-28..F-35（重启主链，本机已 196 次 restarted-ok）；6→N-01..N-07；7→F-31/F-43/D-11；8→G-11/D-09；9→D-05/F-12；10→S-03/S-04；11→F-02/G-01；12→（未实现，矩阵**不含**该能力）；13→F-33；14→B-01/U-14；15→G-03；16→G-06 |
| 八、未验证项 / 已知限制（9 条） | P-27（TryCtrlC 未实测）、T-16（ViaTask 已后补实测）、N-04（投递已实测生效）、U-12（无看门狗） |
| 九、重启由用户执行 + 2026-09-12 事故复盘（3 处修复） | M-01, G-07, G-08, F-42, S-01, U-04 |

### 14.2 `bin/dsh-restart.ps1:33-85` param 块 → 矩阵行

`Profile`→P-01、`Port`→P-02、`BindHost`→P-03、`DshHome`→P-04、`StateDir`→P-05、
`ReadySec`→P-06、`VerifyReadySec`→P-07、`GraceSec`→P-08、`PortFreeSec`→P-09、
`WaitIdleSec`→P-10、`IdleMaxSec`→P-11、`Status`→P-12、`DryRun`→P-13、`Start`→P-14、
`Stop`→P-15、`Json`→P-16、`Fast`→P-17、`ForceUnverified`→P-18、`VerifyOnly`→P-19、
`Preflight`→P-20、`VerifyTempRoot`→P-21、`Session`→P-22、`Reason`→P-23、`Record`→P-24、
`RecordCommand`→P-25、`RecordWorkingDirectory`→P-26、`TryCtrlC`→P-27、`ViaTask`→P-28、
`ViaTaskInner`→P-29、`RegisterTask`→P-30、`UnregisterTask`→P-31、`TaskName`→P-32、
`DoNotTouchDshHome`→P-33。**共 33 个 param 条目 + 1 个脚本级约束（P-34）+ 1 个版本常量（P-35）+ 1 个点源守卫（P-36）。**

### 14.3 旧引擎函数清单 → 矩阵行（逐函数可核）

`Add-Step`→F-38 · `Write-Audit`→F-39 · `New-Utf8NoBom`→F-41 · `Get-NowIso`→F-40 ·
`Get-RegistryEnvLayer`/`Expand-EnvValue`/`Copy-EnvBlock`/`Get-RegistryEnvironmentBlock`→U-01 ·
`Sync-ProcessEnvironment`→U-02 · `Get-TaskXmlPath`→S-07 · `ConvertTo-XmlText`→T-09 ·
`Get-RestartTaskEngine`→T-01 · `New-RestartTaskXml`→T-03..T-08 · `Save-RestartTaskXml`→T-11 ·
`Register-RestartTask`→T-12 · `Invoke-ViaTask`→T-13 · `Test-Elevation`→ST-13/G-21 ·
`Get-TaskRegistered`→T-15 · `Get-Ps7RuntimeStatus`→F-04 · `Get-StatePath`→S-01..S-08 ·
`Write-Terminal`→F-40/S-03/S-04 · `Get-WebAuthUrlPath`→S-05 · `Get-JsonField`→S-05 ·
`Get-TokenFromUrl`→S-05 · `Get-HostAuthUrlRecord`→U-15 · `Read-WebAuthUrlRecord`→S-05 ·
`Save-WebAuthUrlRecord`→S-05 · `Test-WebAuthUrl`→S-05/ST-02 · `Resolve-WebAuthUrl`→ST-02 ·
`Get-AppendedText`→U-15 · `Wait-NewHostToken`→F-34 · `Test-PortListening`→D-01 ·
`Get-PortOwner`→D-02 · `Get-FreePort`→V-01 · `Test-PortBindable`→D-09/…
`Get-HttpStatusCode`→V-09 · `Test-HttpServing`→V-09/ST-03 · `Get-CimAvailable`→D-07 ·
`Get-HostCandidate`→D-03/D-04/D-05 · `Get-DshInstances`→F-08 · `Test-HostAlive`→D-06 ·
`Get-BootRecord`/`Save-BootRecord`→S-01 · `Resolve-Launch`→S-01/F-29 · `Resolve-DirectLaunch`→F-29 ·
`Test-LaunchPrereq`→G-07/G-08 · `Show-LaunchFailure`→F-42 · `Get-DshEntry`→M-11 ·
`Remove-VerifyInstance`→V-12 · `Copy-TreeWithLinks`→V-03 · `Test-SymlinkPrivilege`→G-03/G-04 ·
`Test-DeepVerify`→V-01..V-11 · `Invoke-DeepVerifyWithRetry`→V-13 · `Get-NewestSessionId`→N-02 ·
`Normalize-SessionId`→N-02/N-03 · `Write-PendingNotice`→N-04 · `Test-ConfigOperationGate`→G-09 ·
`Get-StaleEnvLockAdvice`→G-10 · `Wait-SessionIdle`→F-23 · `Invoke-TryCtrlC`→P-27 ·
`Format-KillOutput`→F-43 · `Test-StopPermission`→G-05/G-20 · `Stop-DshInstance`→G-19/F-25 ·
`Wait-PortFree`→G-11 · `Remove-OrphanDshChildren`→D-11/F-27 · `Get-ResidualChildren`→D-10/U-08 ·
`Start-DshInstance`→F-29/F-44/F-45/F-46/M-10 · `Wait-HostReady`→F-30/D-08 · `Get-MutexName`→F-02/U-10 ·
`Enter-RestartLock`→F-02 · `Exit-RestartLock`→F-03 · `Show-Status`→ST-01..ST-13/M-03 ·
`Invoke-RescueLaunch`→G-13..G-16。**旧引擎 73 个函数（`grep -c '^function '` = 73）全部有归属行。**

### 14.4 明确**不在**本矩阵的能力（避免下游误当回归）

1. **崩溃自愈看门狗**（README §八.4 / 验收 12）：旧引擎未实现，矩阵不含；插件也不许声称有。
2. **隧道/中继复核**（README §八.5）：未观测到，不含。
3. **状态目录轮转/清理**：无实现（U-12），只在 U-12 记录现状，不作为能力。
4. **UI/按钮类功能**：CONTRACT GOAL「不做」，不含。

### 14.5 目标符号锚点复核（可复跑，2026-11-14 12:50 实测通过）

本表的「插件目标位置」列不是愿望，而是已可机器核对的锚点。移植进度变化时复跑这四条即可：

```powershell
# ① 旧引擎函数名 73 个是否全部保留在目标脚本里（差集必须为空）
$old = Select-String scripts\..\..\dsh-restart\bin\dsh-restart.ps1 -Pattern '^function\s+([A-Za-z][\w-]*)' | % { $_.Matches[0].Groups[1].Value }
$new = Select-String .\scripts\dsh-restart.ps1 -Pattern '^function\s+([A-Za-z][\w-]*)' | % { $_.Matches[0].Groups[1].Value }
$old | ? { $new -notcontains $_ }      # → 期望无输出

# ② 33 个旧 param 是否都在（缺一个即功能丢失）
Select-String .\scripts\dsh-restart.ps1 -Pattern '^\s*\[(switch|string|int)\]\$(Profile|Port|BindHost|DshHome|StateDir|ReadySec|VerifyReadySec|GraceSec|PortFreeSec|WaitIdleSec|IdleMaxSec|Status|DryRun|Start|Stop|Json|Fast|ForceUnverified|VerifyOnly|Preflight|VerifyTempRoot|Session|Reason|Record|RecordCommand|RecordWorkingDirectory|TryCtrlC|ViaTask|ViaTaskInner|RegisterTask|UnregisterTask|TaskName|DoNotTouchDshHome|ResultFile|NoWait)\b'

# ③ 退出码 0-12 是否都还在（缺 3/11/12 是最容易漏的三个）
Select-String .\scripts\dsh-restart.ps1 -Pattern '\bexit\s+(\d+)' -AllMatches |
  % { $_.Matches } | % { $_.Groups[1].Value } | Sort-Object -Unique

# ④ 终态词表 26 个是否都还在（含动态拼接的三个）
Select-String .\scripts\dsh-restart.ps1 -Pattern 'restarted-ok|status|verify-only-ok|dry-run|stopped|task-registered|task-register-failed|task-unregistered|via-task-dispatched|via-task-failed|recorded|locked|engine-requires-pwsh|invalid-args|config-invalid|verify-only-failed|verify-failed|gate-blocked|stop-failed|port-busy|ready-failed|verify-required|launch-prereq-failed|stop-refused|rescued-after-abort|aborted'
```

**首次实测结果（2026-11-14 12:50，目标脚本 134,794 字节 / 78 个函数）**：

| 锚点 | 结果 |
|---|---|
| 旧函数名 73 个 | **73/73 全部存在**，新增 5 个辅助（`Write-Diag`/`Write-DiagWarn`/`Get-LastFailDetail`/`Get-ResultEnvelope`/`Write-EngineResult`） |
| param | 33/33 旧参数 + `-ResultFile` + `-NoWait` 全部存在 |
| 退出码 | `0,1,2,3,4,5,6,7,8,9,10,11,12` 全部出现（`exit 3` 在 `if ($dumpOk -eq $false) { …; exit 3 }` 行内，用 `\bexit\s+3` 才搜得到） |
| 终态词表 | 26 个全部存在（含 `rescued-after-abort:`、`aborted:`、`task-registered`/`task-register-failed` 三处动态拼接） |

> 该快照只证明**符号存在**，不证明行为等价 —— 行为等价由 `test/parity.mjs`（qa-verifier）与本表「验证方式」列的运行证据共同判定。

## 15. 机器事实与反硬编码（MP 组）

背景：本机把 DSH Desktop 装在非默认目录（`<盘>:\<目录>\`），且 `git-bash` 的 PATH 会把 `netstat`
解析到别处。两次真实事故都出在「猜」上：App 停着 + 装在非默认位置 → 引擎报「找不到可执行文件」；
宿主停掉后判定退化 → 退化成 `web` 分支 → 整条重启链走错。这一节把「不猜」写成可执行断言。

| 能力ID | 能力（参数/开关/步骤） | 旧实现位置 | 插件目标位置 | 可配置化处理 | 验证方式 |
|---|---|---|---|---|---|
| MP-01 | 桌面版可执行文件从**系统登记处**反查：卸载登记（HKCU/HKLM `Uninstall\*` 的 `DisplayIcon`/`InstallLocation`）、`App Paths`、开始菜单/桌面 `.lnk` 的 `TargetPath`；全部落空才 fail-closed，绝不扫盘 | 无旧实现（旧引擎只认 web 端口） | scripts/dsh-restart.ps1::Get-DesktopInstallPaths | 无需配置 | parity:MP-01 断言三条来源都在、且函数体里没有字面量盘符路径 |
| MP-02 | `<StateDir>\machine.json` 是**第一候选**（先于运行中实例 / 启动档案 / 默认位置）；文件缺失或坏掉时返回 `$null` 继续探测，绝不抛 | 无旧实现 | scripts/dsh-restart.ps1::Get-MachineConfig + Resolve-DesktopAppPath | `-StateDir` / `%DSH_RESTART_HOME%` 决定位置 | parity:MP-02 断言读取点存在、优先级高于 `running-instance`、缺配置不致命 |
| MP-03 | 系统工具一律走绝对路径：`Get-SystemTool netstat/taskkill/schtasks/robocopy/cmd` → `%SystemRoot%\System32`，找不到才退回裸名 | 本机：无旧实现（裸名调用，无解析器） | scripts/dsh-restart.ps1::Get-SystemTool | 无需配置 | parity:MP-03 断言四种工具都经解析器；`Get-SystemTool` 体里出现 `System32` |
| MP-04 | `-Status -Json` 的 `status` 增加安装事实：`desktopApp` / `desktopAppSource` / `runtimeDir` / `appRoot` / `pnpm` / `nodeExe`（外部工具不必自己猜路径） | 无旧实现 | scripts/dsh-restart.ps1::Show-Status | 只读，无副作用 | parity:MP-04 断言五个键写入；本机实跑：`src=machine-config`、`runtimeDir` 与实例一致 |
| MP-05 | `scripts/dsh-plugin-install.ps1`：插件安装/修复通道。所有机器事实取自引擎 `-Status -Json`，动作全部委托引擎；解析引擎时只认 `.ps1`（`.cmd` 垫片交给 `pwsh -File` 会 `exit=64`）；`-Report` 落 UTF-8 报告 | 本机：原 `plugin-install.ps1`（不在仓库，写死安装根与 node 路径） | scripts/dsh-plugin-install.ps1 | `-Profile` / `-DshHome` / `-NodeExe` / `-PnpmMjs` / `-Engine` / `-StateDir` 覆盖 | parity:MP-05 静态断言 + 本机实跑：`-CensusOnly` / `-WhatIfPlan` / `-CheckShadowed` 全部走通 |
| MP-06 | `scripts/dsh-config.ps1`：一次探测把 `machine.json` 落盘（`-Show` 预览 / `-Reset` 删除 / `-DesktopApp` 手工指定） | 无旧实现 | scripts/dsh-config.ps1 | 全部参数可选 | parity:MP-06 静态断言；本机实跑 `-Show` 与写入，`machine.json` 字段与实例实测一致 |
| MP-07 | 回归入口：`scripts/probe-plugin-install.ps1` 只读验证续跑通知契约（AST 抽函数 → 临时目录跑三次 → 键序 / ISO-Z / attempts=0 / 无 BOM / 无 .tmp 残留 / 调用点仍在停机之前）；README 记录两条脚本 | 本机：原 `_probe-plugin-install.ps1`（指向已删除的 plugin-install.ps1） | scripts/probe-plugin-install.ps1；README.zh.md §5.5 / §5.6 | 无参数 | parity:MP-07 静态断言；本机实跑 `RESULT: ALL PASS` |

| MP-08 | 活动台账 `activity.json`：拿到重启锁后每推进一个阶段写一次，等待循环里每 2 秒刷新心跳；`-Status` 直接读它报「现在有没有人在干活」 | 无旧实现（旧版只有终态一行，无法区分「在跑」与「卡死」） | scripts/dsh-restart.ps1（`Write-Activity` / `Get-ActivityPath` / `Show-Status`）；README.zh.md §10 / §13 | 只由引擎写；只读动作不写 | parity:MP-08 静态断言；本机实跑：`-VerifyOnly` 期间台账 2s 一跳（43 轮 / 59s），`-Status` 同屏显示「进行中：verify 的 deep-verify」 |
| MP-09 | 冷启动宿主形态判定：`auto` 的判据顺序为「运行中宿主 → `machine.json` 的 hostKind → 启动档案 → web」，并把来源写进 `status.hostKindSource` | 无旧实现（旧版只有「有没有进程」+「启动档案里有没有 exe 字面量」，冷启动必然落到 web） | scripts/dsh-restart.ps1（`Resolve-HostKind` / `Resolve-DesktopProfileName` / `Show-Status`） | 只读，无副作用 | parity:MP-09 静态断言；本机实跑四个场景：无宿主+无档案+`machine.json=desktop` → `desktop`；`machine.json=web` 不被旧档案的 exe 口径推翻 → `web`；全无 → `web` |
| MP-10 | 一次动作一个预算：拿锁后算总预算，就绪等待 / 桌面就绪等待 / 桌面深验证三层都受同一截止时刻封顶；HTTP 探测器不再把一个读超时翻倍 | 无旧实现（旧版每层各自计一个 90s/150s，一个失败的重启可以合法地静默耗掉 7 分钟以上） | scripts/dsh-restart.ps1（`Set-ActionBudget` / `Get-BudgetLeftSec` / 三个等待循环 / `Invoke-HttpProbe -Retries 1`） | 只读动作不设上限 | parity:MP-10 静态断言；本机实跑：accept-但不回的端口探测 10.19s → 5.18s；死端口 1.50s |

> 说明：`-DesktopApp <path>` 也是引擎参数，显式给出时优先级最高（用户已给出唯一确定的事实），
> 探测链整体短路。`scripts/dsh-plugin-install.ps1` 与 `scripts/dsh-config.ps1` 每次运行都会顺带刷新
> `machine.json`，因此「配置过期」不是需要人工维护的状态。

---

## 16. 工作区存储预检（WS 组，2026-11-24 新增）

| 能力ID | 能力（参数/开关/步骤） | 旧实现位置(旧仓库 file:line) | 插件目标位置 | 可配置化处理 | 验证方式 |
|---|---|---|---|---|---|
| WS-01 | 存储预检：解析 `<DshHome>\storages\*.json`，并把 `workspace.json` 按 workspace 域 schema 逐条校验（ISO-8601 字符串、重复会话、`workspaceIds` 与表一致） | 无旧实现（旧版没有存储闸门；一条记录不合规就让整个 workspace 域 FAILED） | scripts/dsh-restart.ps1::Test-StoragePreflight | 不变（只读判定） | parity:WS-01 静态断言；本机实跑：正常 workspace.json → `ok=true, 1 file, 0 errors`；伪造 fixture（数字 epoch + 非法 ISO + 重复会话）→ 3 个错误全部命中；`-Status` 的 `storage` 块 29ms |
| WS-02 | fail-closed 闸门：重启/验证在停机前跑预检，失败 `exit 3 storage-invalid`；`-DryRun` 只报告；`-ForceStorage` 显式豁免 | 无旧实现（坏存储只能等宿主启动失败才暴露） | scripts/dsh-restart.ps1::Test-StorageGate；scripts/dsh-restart.ps1@param | param（`-ForceStorage`） | parity:WS-02 静态断言；本机实跑：`-Preflight -DshHome <坏 fixture>` → rc=3、1.4s、未拉起任何实例；`-DryRun` 同 fixture → storage step=fail + warn 但不中止 |
| WS-03 | 花名册重建：只保留 cwd 匹配且非子代理的会话，补回磁盘上未登记的主会话，ISO 写回，落盘前 schema 复验 + 固定备份 | 无旧实现（2026-11-24 的外部重建脚本写数字 epoch，把整个 workspace 域打挂） | scripts/workspace-store-doctor.mjs | param（`--reconcile [--apply]`） | parity:WS-03 静态断言；本机实跑 dry-run：default 266→245、tools 82→50、Mnemon 289→1，attached 0 |

> 说明：WS-01/WS-02 跑在**停机之前**；损坏时旧实例保持不动，修复走 `scripts/workspace-store-doctor.mjs`（宿主退出后 `--fix --apply` 或 `--reconcile --apply`）。
