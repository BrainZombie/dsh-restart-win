# 从旧引擎迁移到 @brainzombie/dsh-restart-win

读者是「已经在一台 Windows 机器上跑着旧 `dsh-restart` 引擎、现在要换到插件」的人，以及半年后回来维护的自己。

本文里的 `<old-repo>` 指你现在放旧引擎的那个目录（里面有 `bin\dsh-restart.ps1`、`dsh-restart.cmd`、`README.md`），`<repo>` 指本插件仓库。

---

## 1. 迁移前先确认三件事

| 检查 | 命令 | 期望 |
|---|---|---|
| 旧引擎还能跑 | `dsh-restart -Status` | 打印状态，退出码 0 |
| 状态目录在哪 | 看 `-Status` 输出的 `stateDir` 行 | 通常是 `%LOCALAPPDATA%\dsh-restart` |
| 有没有注册计划任务 | `schtasks /Query /TN "DSH Restart"` | 有则记下它的名字，迁移后继续用 |

迁移不会删除旧目录、不会删除状态目录、不会删除计划任务。任何一步出问题都能切回去。

---

## 2. 本机切换：五步

### 第 1 步：把旧仓库冻结为归档

```powershell
# 1) 确认没有未提交的改动（如果旧目录也是 git 仓库）
git -C <old-repo> status --short

# 2) 改名归档（保留可执行性，但它不再是真源）
Rename-Item -LiteralPath <old-repo> -NewName ((Split-Path <old-repo> -Leaf) + '-archive')

# 3) 可选：把归档目录设为只读，避免以后误改
attrib +R <old-repo>-archive\*.* /S
```

冻结的含义：**新维护只改插件仓库**。归档目录继续可用（它的 `dsh-restart.cmd` 还在），只是不再接受修改；需要回退时直接用它（见 §6）。

### 第 2 步：把插件装进 profile

如果你已经把仓库克隆到本机（`<repo>`），用安装脚本一步到位：

```powershell
cd <repo>
pwsh -NoProfile -File .\install.ps1 -Profile web
```

它会执行 `dsh plugin --profile web add <repo>`，在 `%LOCALAPPDATA%\dsh-restart\bin\dsh-restart-win.cmd` 写 CLI shim，并把该目录加入用户 PATH。

只想要依赖、不装 shim（比如 PATH 由你管），直接加 GitHub 源：

```powershell
# 当前分发方式（本插件未发布到 npm）
dsh plugin --profile web add github:BrainZombie/dsh-restart-win

# 钉住某个提交
dsh plugin --profile web add github:BrainZombie/dsh-restart-win#<sha>
```

已经用 `pnpm link` 手动装过的，加 `-SkipPluginAdd` 只装 shim。想先看它要做什么，加 `-WhatIf`。

**装完还要激活**：`dsh plugin add` 只写 `node_modules` 与 `dependencies`；宿主按 profile 的层树组装插件，层树的来源之一就是 `dsh.profile.bundles` 的显式列表。`install.ps1` 的第 3 步会替你追加（写前确认本包声明了 `dsh.bundle.patch`、改前备份、写完回读断言名字恰好 1 次且其他条目顺序未变）；**手工 `dsh plugin add` 装的**则要自己打开 `%USERPROFILE%\.dsh\profiles\<profile>\package.json`，把 `"@brainzombie/dsh-restart-win"` 追加到 `dsh.profile.bundles` **末尾**（原有条目一个都不能删；顺序不影响本插件）。少了这一步，宿主启动时会打印 `skipping profile bundle "@brainzombie/dsh-restart-win"`，会话里也不会出现工具。完整片段与自检见 README 的安装小节。

### 第 3 步：让 PATH 上的 `dsh-restart` 由插件提供

插件的 CLI 名是 `dsh-restart-win`（与市场上的 `dsh-restart` 包区分）。两种做法：

**A. 直接用新名字（推荐）**

```powershell
dsh-restart-win -Status -Json
```

同时把旧 shim 从 PATH 上摘掉。旧引擎的 `dsh-restart.cmd` 可能在旧仓库根、它的 `bin\` 子目录，或你当初自己放进的 PATH 目录里；`install.ps1` 不会删除它，留着会让 `dsh-restart` 继续指向旧归档。

```powershell
# 先看清楚 `dsh-restart` 现在解析到哪个文件，再决定删不删
Get-Command dsh-restart -All | Select-Object Source
```

**B. 保留旧命令名，但转发到插件**

在同一目录写一个 `dsh-restart.cmd`，内容只有一行转发（纯 ASCII、CRLF）：

```bat
@ECHO OFF
REM Legacy alias: forwards to the plugin CLI.
dsh-restart-win %*
```

这样你所有旧脚本、快捷方式里的 `dsh-restart ...` 会直接落到插件上，参数与退出码原样透传。

### 第 4 步：状态目录与状态文件继续可用

`install.ps1` 与插件默认 `stateDir = %LOCALAPPDATA%\dsh-restart`（引擎里是 `%DSH_RESTART_HOME%` 优先）。保持默认即可继续读写这些既有文件：

| 文件 | 迁移后 |
|---|---|
| `boot-record.json` | 原样使用，重启时按它重放启动命令 |
| `restart-history.jsonl` | 继续追加，不截断、不改字段 |
| `dsh-restart.log` | 继续追加 |
| `web-auth-url.txt` | 继续使用（含真实 token，位置与结构不变） |
| `dsh-restart.task.xml` | 继续使用；`-RegisterTask` 会按当前配置重写它 |
| `host.out.log` / `host.err.log` | 继续追加 |
| `<DshHome>\.smart-restart\pending-notice.json` | 继续由插件在停机前写入 |

新增的只有 `<stateDir>\runs\` 目录：每次分离执行的 `pending` / `request` / `launch` / `result` 四个记录。旧引擎没有这个概念，它不读这些文件，所以混用期间也不冲突。

### 第 5 步：重启宿主（由你本人执行）

工具面要等宿主重新启动后注册。**这一步不要交给 agent 代做**：它会中断会话，你要在旁边。

重启后自检：

```powershell
dsh --profile web --dump-config          # 有 dsh-restart-win 条目
dsh-restart-win -Status -Json            # 单个 JSON、退出码 0
dsh-restart-win -Preflight               # 深度验证通过（耗时长）
```

会话里应能看到四个工具：`win_restart`、`win_restart_status`、`win_restart_preflight`、`win_restart_result`。

---

## 3. 旧命令 → 新入口对照

左列是旧引擎的命令行，中列是插件的 CLI（参数同名、退出码相同），右列是工具面。

| 旧命令 | 新 CLI | 新工具 |
|---|---|---|
| `dsh-restart -Status` | `dsh-restart-win -Status` | `win_restart_status` |
| `dsh-restart -Status -Json` | `dsh-restart-win -Status -Json` | `win_restart_status`（`status` 字段） |
| `dsh-restart`（默认完整重启） | `dsh-restart-win` | `win_restart`（`action: "restart"`） |
| `dsh-restart -DryRun` | `dsh-restart-win -DryRun` | `win_restart`（`action: "restart"`, `dryRun: true`） |
| `dsh-restart -Start` | `dsh-restart-win -Start` | `win_restart`（`action: "start"`） |
| `dsh-restart -Stop` | `dsh-restart-win -Stop` | `win_restart`（`action: "stop"`） |
| `dsh-restart -Fast` | `dsh-restart-win -Fast` | `win_restart`（`fast: true`） |
| `dsh-restart -Fast -ForceUnverified` | `dsh-restart-win -Fast -ForceUnverified` | `win_restart`（`fast: true`, `forceUnverified: true`） |
| `dsh-restart -VerifyOnly` | `dsh-restart-win -VerifyOnly` | `win_restart_preflight`（`mode: "verify_only"`） |
| `dsh-restart -Preflight` | `dsh-restart-win -Preflight` | `win_restart_preflight`（`mode: "preflight"`） |
| `dsh-restart -Record -RecordCommand "<cmd>" -RecordWorkingDirectory "<dir>"` | 同左 | `win_restart`（`action: "record"`, `recordCommand`, `recordWorkingDirectory`） |
| `dsh-restart -RegisterTask` | `dsh-restart-win -RegisterTask` | `win_restart`（`action: "task_register"`） |
| `dsh-restart -UnregisterTask` | `dsh-restart-win -UnregisterTask` | `win_restart`（`action: "task_unregister"`） |
| `dsh-restart -ViaTask` | `dsh-restart-win -ViaTask` | `win_restart`（`viaTask: true`） |
| `dsh-restart -WaitIdleSec 60` | `dsh-restart-win -WaitIdleSec 60` | `win_restart`（`waitIdleSec: 60`） |
| `dsh-restart -TryCtrlC` | `dsh-restart-win -TryCtrlC` | `win_restart`（`tryCtrlC: true`） |
| `dsh-restart -Session auto -Reason "..."` | 同左 | `win_restart`（`session`, `reason`） |
| `dsh-restart -TaskName "..."` | `dsh-restart-win -TaskName "..."` | `win_restart`（`taskName`） |
| `dsh-restart -VerifyTempRoot <dir>` | 同左 | `win_restart` / `win_restart_preflight`（`verifyTempRoot`） |
| `dsh-restart -Port 3099` | `dsh-restart-win -Port 3099` | 工具参数 `port` 或配置 `port` |
| `dsh-restart -BindHost 0.0.0.0` | 同左 | 工具参数 `bindHost` 或配置 `bindHost`（**不改变宿主监听**，见 §4） |
| `dsh-restart -DoNotTouchDshHome` | `dsh-restart-win -DoNotTouchDshHome` | 无对应参数（死参数，行为等于不写） |
| `dsh-restart -ViaTaskInner`（任务内部用） | 不需要手动传 | 无工具入口 |
| — | `dsh-restart-win -ResultFile <path>` | 插件内部使用；CLI 也可以自己传 |
| — | `dsh-restart-win -NoWait` | 插件内部使用（分离执行时跳过 20 s 收尾等待） |

工具面与 CLI 的差别只有一处：**工具面把「会停掉宿主」的动作分离执行**。`win_restart` 的重启 / 拉起 / 停机，以及 `win_restart_preflight` 的两种模式，会立即返回 `{ started, runId, resultFile }`，引擎在 `restartDelayMs`（默认 1500 ms）之后才动宿主；结论用 `win_restart_result` 按 `runId` 读回（`ok` / `failed` / `running` / `unknown`）。CLI 是同步的，和旧命令行一样等它跑完。

---

## 4. 行为变化清单

| 变化 | 影响谁 | 怎么改 |
|---|---|---|
| **`-Json` 变成单个固定信封** | 解析旧 `-Status -Json` 的脚本 | 旧状态字段全部原样移到 `.status` 下；顶层是 `ok` / `result` / `exitCode` / `version` / `steps[]` / `warnings[]` / `targetPid` / `newPid` / `hostUrl` / `error` / `durationMs` / `stateDir` / `logPath` |
| 诊断信息改走 stderr | 把 stdout 整段当 JSON 解析的脚本 | 这本来就是正确用法，现在更安全：stdout 只有一个 JSON 文档 |
| 不再有 `pack.ps1` 与「安装副本同步」 | 你原来的改脚本流程 | 改完插件仓库里的脚本：`pwsh -File scripts\check-encoding.ps1` → `npm test` → 提交。源仓库就是真源，没有第二份副本要同步 |
| CLI 名是 `dsh-restart-win` | 旧脚本、快捷方式 | 见 §2 第 3 步：改调用名，或写一行 `dsh-restart.cmd` 转发 |
| 分离执行多了 `runs\` 记录 | 状态目录的读者 | 忽略即可；`win_restart_result` 会读它们 |
| 版本字段跟随插件版本（`package.json` 的 `version`，当前 `0.1.0`） | 用版本做判断的脚本 | 不要按版本判断能力，按退出码与 `result` 词判断 |
| PATH shim 位置 | 手工维护 PATH 的人 | `%LOCALAPPDATA%\dsh-restart\bin\dsh-restart-win.cmd`；`-ShimDir` 可改 |

`-Json` 迁移示例（PowerShell）：

```powershell
# 旧：$s = dsh-restart -Status -Json | ConvertFrom-Json; $s.instances
# 新：
$e = dsh-restart-win -Status -Json | ConvertFrom-Json
if ($e.ok -and $e.result -eq 'status') { $e.status.instances } else { $e.error }
```

```bash
# jq 版本
dsh-restart-win -Status -Json | jq -r '.status.instances[0].pid'
```

---

## 5. 环境变量

引擎按这些变量决定默认值，行为与旧版一致：

| 变量 | 作用 | 迁移影响 |
|---|---|---|
| `DSH_HOME` | 宿主家目录 | 不变 |
| `DSH_RESTART_HOME` | 状态目录（优先于 `%LOCALAPPDATA%\dsh-restart`） | 设过就继续生效 |
| `DSH_SESSION_ID` | `-Session` 的默认值 | 不变 |
| `DSH_RESTART_DEBUG` | 打印 argv 改写细节与异常转储 | 排障时用，平时不要设 |
| `DSH_UC_PROFILE_NODE_MODULES` | 拉起宿主前注入，指向 `<DshHome>\profiles\node_modules`；不指路时更新检查器可能把包装进 `node_modules` 却不写 `package.json` / `pnpm-lock.yaml` | 只写**进程级**，不改用户级变量 |
| `NPM_CONFIG_LEGACY_PEER_DEPS` | 拉起宿主前注入，供更新器在临时目录取包；不开时 `npm` 会以 ERESOLVE 失败 | 同上 |

这两条是默认行为，不是硬编码：它们在 `Start-DshInstance` 里写进将被拉起的宿主进程环境，宿主退出后不残留。**怎么关**：把配置 `injectHostEnv` 设为 `false`（默认 `true`），插件就会以 `DSH_RESTART_INJECT_HOST_ENV=0` 启动引擎，引擎跳过这两条注入并记一条 `skip` 步骤——换到一台不需要这两个 workaround 的机器时用它。细节见 README 的配置小节。

---

## 6. 回退到旧引擎

任何一步不满意，五分钟内切回去：

```powershell
# 1) 从 profile 移除插件（依赖名即包名，与安装来源无关：github: 装进来的也用它）
dsh plugin --profile web remove @brainzombie/dsh-restart-win

# 2) 再从 dsh.profile.bundles 里删掉 "@brainzombie/dsh-restart-win"
#    只做第 1 步的话，启动时仍会打印 skipping profile bundle

# 3) 把归档改回原名
Rename-Item -LiteralPath <old-repo>-archive -NewName (Split-Path <old-repo> -Leaf)

# 4) 若 §2 第 3 步用过转发 shim，删掉它，让旧 dsh-restart.cmd 重新生效
Remove-Item "$env:LOCALAPPDATA\dsh-restart\bin\dsh-restart-win.cmd"

# 5) 重启宿主（由你本人执行）
```

回退不需要动状态目录：两种实现写的是同一批文件。混用期间唯一需要担心的是并发——新旧两版共用同一个互斥体名 `Local\dsh-restart-p<port>`，所以即使两者同时被调用，也只会有一个真的执行。

计划任务同理：任务名默认都是 `DSH Restart`，回退后 `-RegisterTask` 会把任务重写成旧引擎的路径；想两边都留着，用 `-TaskName` 给其中一个换名。

---

## 7. 迁移时最容易踩的四个坑

1. **忘了重启宿主。** 插件装好了但工具不出现，十次有九次是宿主还是老进程。`dsh --profile web --dump-config` 能看到条目 ≠ 工具已经注册。
2. **把 `bindHost` 当成监听地址。** 它只影响探针 URL 与状态显示；宿主绑哪个地址由 `boot-record.json` 里的启动命令决定。想换监听地址，改启动档案或在启动命令里加参数，然后重启。
3. **用 Windows PowerShell 5.1 跑验证型重启。** 会以退出码 2 `engine-requires-pwsh` 停在停机之前（这是设计如此，不是坏了）。装 pwsh 7.4+，或用 `pwshPath` / 配置项指过去。
4. **删掉了 `restart-history.jsonl`。** 它是审计与排障的唯一时间线。迁移前后都不要动它；真嫌大就归档而不是删除。

---

## 8. 装到 DSH Desktop（Electron）profile

桌面版与 `dsh web` 不是同一种宿主：它由 Electron 主进程 spawn 一个 Node 模式子进程（命令行含 `dsh-desktop-host\lib\index.js`），用 `--port 0` 启动（端口每次随机），真正的关闭是杀主进程整棵树。插件用 `hostKind` 区分：

```powershell
# 1) 装进桌面版 profile（插件的默认 profile 是 web，装法不变）
pwsh -NoProfile -File .\install.ps1 -Profile desktop

# 2) 在用户层把这一行指向 desktop（写进 %USERPROFILE%\.dsh\profiles\desktop\cordis.patch.yml）
#    - id: dsh-restart-win
#      config:
#        profile: desktop

# 3) 记录一次 App 路径，冷启动时引擎才知道拉什么
dsh-restart-win -Record -RecordCommand '"C:\<app>\DeepSeek Harness.exe"' -RecordWorkingDirectory $env:USERPROFILE

# 4) 重启宿主后自检
dsh-restart-win -Status -Json      # status.hostKind=desktop, status.port=实测端口, status.mainPid=Electron 主进程
dsh-restart-win -Preflight         # 以 Node 模式起 Electron 宿主入口（隔离 home），不碰运行中的 App
```

三条与 web 侧不同的注意点：

1. **端口不是配置。** `-Port` / `port` 只是期望值；`status.portSource = "netstat"` 时以实测为准。
2. **不要用 `taskkill` 只杀宿主子进程。** 会把 App 留在 host crash 对话框；引擎杀的是主进程整棵树（先写续跑通知）。
3. **`--profile desktop` 的 `--dump-config` 会被 CLI 拒绝**，组合校验改由深度验证负责（真的起一个隔离宿主）。
