# dsh-restart-win

**Windows 专用、先验证后停机的 DSH 宿主重启引擎。** 它先在一个临时 home + 空闲端口上真启一个一次性实例，证明这次的配置组合能起得来，才允许碰正在服务的那个实例；停机由计划任务或分离进程执行，宿主死掉不会带走执行者。

`@brainzombie/dsh-restart-win` · Windows 10/11 · Node ≥ 20 · DSH 0.2.x · MIT

[English](README.md) | 中文

---

## 1. 它到底是什么

一个 DSH 宿主插件，把「安全重启」这件事拆成五个可验证的步骤：

1. **发现**：以 `netstat -ano -p TCP` 的端口监听者为权威找出宿主进程，不用 WMI/CIM，也不做命令行模糊匹配。
2. **证明**：在隔离 home 里用空闲端口真启一个新实例，只认 `401`/`200` 为就绪（`404` 表示端口已绑但路由未注册，不算）。
3. **门禁**：预检不通过就停在原地——旧实例不动，返回非零退出码并说明原因。
4. **停机 + 拉起**：写续跑通知 → 停旧实例 → 等端口真的可 bind → 重建环境块 → 拉起 → 核对端口归属与父链。
5. **收尾**：任何失败都落一条审计记录；中止发生在停机之后时尽力抢救拉起一次。

它是**引擎**，不是按钮。四个宿主工具和一条 CLI 都把命令交给同一个 PowerShell 脚本 `scripts/dsh-restart.ps1`，参数、退出码、终态词与状态文件保持旧引擎的语义。

---

## 2. 与市场上的重启插件有什么不同

市场上的重启方案多数是「按钮 + 立即重启」或「进程外看门狗 + 失败重试」。下面 13 个是 2026-11 在 GitHub `dsh-plugin` 话题下按 stars 能检索到的同类项目：

| 项目 | 形态 | 与本插件的关系 |
|---|---|---|
| `anweat/dsh-restart`（npm `dsh-restart`） | 可配置重启方式 + 重启后继续提示词 + 看门狗 | 能力重叠（续跑、看门狗）；包名与本插件不同 |
| npm `dsh-restart-guard` | 宿主进程外看门狗，失败重启并上报 IM/webhook | 互补：它在进程外守着，本插件在被重启的进程内发起 |
| `edusrez/dsh-smart-restart` | 重启检测 + 唤醒 agent + systemd 单位 + canary | 互补：本插件负责 Windows 侧的验证与停机，它负责重启后回到会话 |
| `893413974-bit/dsh-setting-restart` | 设置页一键重启 | 形态不同（UI 按钮） |
| `xiaolu511/dsh-hot-restart` | 窗口内按钮重启并自动重开 | 形态不同（UI 按钮） |
| `luoshuizhiwei/dsh-desktop-restart` | 桌面端重启按钮 + 停机时长 | 形态不同（UI 按钮） |
| `1123762794/dsh-web-restart` | 侧栏一键重启 web | 形态不同（UI 按钮） |
| `PPsz-qqq/dsh-restart-button` | 会话头重启按钮 + 等待任务结束 | 形态不同（UI 按钮） |
| `xichen-62/dsh-power-menu` | 桌面端电源菜单（关闭/重启） | 形态不同（UI 菜单） |
| `keyiadiannao/dsh-power-button` | 侧栏电源按钮 + 自有重启引擎 | 形态不同（UI 按钮） |
| `regrevia/dsh-unlag` | 桌面刷新按钮 | 不同能力 |
| `hulibuld/dsh-refresh-restart` | 刷新/重启按钮 | 形态不同（UI 按钮） |
| `fakechris/dsh-harness-ops` | A/B 快照升级 + 守护拉起 + doctor | 能力相邻（自愈），路线是快照升级 |

区别集中在五处：

| | 按钮类 | 看门狗类 | 本插件 |
|---|---|---|---|
| 停机前是否证明新组合能起来 | 否 | 否 | **是**：隔离 home + 空闲端口真启一次 |
| 进程发现依据 | 记 pid 或进程名 | 记 pid | **端口监听者**，并核对父子链 |
| 未验证时是否允许停机 | 允许 | 允许 | **拒绝**（`-Fast` 缺 `-ForceUnverified` → 退出码 10） |
| 执行者是否脱离宿主进程树 | 否 | 是 | **是**：分离 supervisor 或计划任务 |
| 可脚本化只读面 | 通常无 | 部分 | **有**：`-Status -Json` 单 JSON + 稳定退出码表 |

它不提供「重启后自动回到原会话」：那一步由宿主侧消费 `<DshHome>\.smart-restart\pending-notice.json` 完成（[`dsh-pending-notice-waker`](https://github.com/BrainZombie/dsh-pending-notice-waker) 做的正是这件事，见 §10.1）。本插件只保证在停机**之前**把这条通知写好。

---

## 3. 环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| 操作系统 | Windows 10 / 11 | 引擎只面向 Windows；在其它平台上没有可用的 PowerShell，工具会直接报错 |
| PowerShell | `pwsh` 7.4+ | 验证型重启需要 `Start-Process -Environment`。只有 5.1 时，`-Status`/`-DryRun`/`-Stop`/`-Start`/`-Fast` 可用，需要深度验证的动作会以退出码 2 `engine-requires-pwsh` 在停机前中止 |
| Node.js | ≥ 20 | 宿主自身的运行环境；分离执行器 `lib/delayed-spawn.mjs` 也用宿主同款 `node` 拉起 |
| DSH | 0.2.x（`>=0.2.1-rc.1 <0.3.0-0`） | 见 `package.json` 的 `dsh.compatibility` |
| 权限 | 能终止宿主进程 | 同一个用户启动的宿主通常无需提权；计划任务按 `HighestAvailable` 注册 |

---

## 4. 安装

### 4.1 先验证 patch 与 profile 兼容（不装也能验）

```powershell
dsh --profile web --dump-config --patch .\cordis.patch.yml
```

这条只做层栈合成：把 patch 叠到目标 profile 的配置上并打印结果，**不改任何配置、不需要重启**。退出码 0 且输出里能看到 `dsh-restart-win` 那一行，就说明这个 patch 能被这个 profile 解析。

它不会激活插件。真正的激活是下面 4.2 / 4.3 加进 profile，再由你在 4.4 重启宿主。

### 4.2 加进 profile

```powershell
# 从 GitHub 仓库安装（当前的分发方式）
dsh plugin --profile web add github:BrainZombie/dsh-restart-win

# 想钉住某个提交（可复现安装）
dsh plugin --profile web add github:BrainZombie/dsh-restart-win#<sha>

# 或者直接指向本机的克隆目录
dsh plugin --profile web add <repo>
```

> 当前**未发布到 npm**：`dsh plugin --profile web add @brainzombie/dsh-restart-win` 只有在将来上架 npm 之后才可用。在那之前请用上面的 GitHub 形式。

`dsh plugin add` 会把参数转发给该 profile 目录下的 pnpm，并在 profile 的 `package.json` 里留下依赖。插件通过自身的 `cordis.patch.yml` 插入 `dsh-restart-win` 行。

**还要激活：把包名加进 `dsh.profile.bundles`。** `dsh plugin add` 只把包装进 `node_modules` 与 `dependencies`；宿主启动时按 profile 的层树组装插件，而层树只由三处构成：`dsh.profile.bundles` 的显式列表、profile 自己的 `cordis.patch.yml`、启动器的 `--patch`。少了这一步，宿主会打印 `skipping profile bundle "@brainzombie/dsh-restart-win"`，或者干脆没有本插件的工具。

打开 `%USERPROFILE%\.dsh\profiles\<profile>\package.json`，把包名追加到 `dsh.profile.bundles` 数组**末尾**（追加即可，顺序不影响本插件）：

```jsonc
// %USERPROFILE%\.dsh\profiles\<profile>\package.json
"dsh": {
  "profile": {
    "bundles": [
      /* ...原有条目全部保留... */,
      "@brainzombie/dsh-restart-win"
    ]
  }
}
```

不要替换或清空既有列表：`@deepseek-ai/dsh-base`、`@deepseek-ai/dsh-web-app` 以及你已装的所有插件都在里面。如果 profile 里还没有 `dsh.profile` 段，先按模板把基线抄进去再加本插件（`web` profile 的基线是 `["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]`）。

### 4.3 用 install.ps1 一次装完（推荐）

```powershell
cd <repo>
pwsh -NoProfile -File .\install.ps1 -Profile web
```

脚本做四件事，全部幂等：

1. 校验仓库完整性（`package.json` 的 `name` 与 `bin`、`scripts\dsh-restart.ps1` 必须存在）；
2. 执行 `dsh plugin --profile <p> add <repo>`（已声明则跳过，`-Force` 强制重跑）；
3. **激活**：把包名追加进 profile 的 `dsh.profile.bundles`。写之前先确认本包确实声明了 `dsh.bundle.patch`（把非 bundle 的包写进列表会让整个 profile 起不来），改前备份原 `package.json`，写完回读断言「该名字恰好 1 次 / 其他 bundle 相对顺序未变 / 顶层键与 dependencies 条数未变」；已包含则跳过；
4. 在 `%LOCALAPPDATA%\dsh-restart\bin\dsh-restart-win.cmd` 写一个 ASCII 的 CLI shim，并把该目录加入**用户** PATH（`-SkipPathUpdate` 只写 shim 不改 PATH）。

第 3 步就是你不用手改 `dsh.profile.bundles` 的原因；手工用 `dsh plugin add` 装的人仍要按 4.2 末段自己补这一步。

常用开关：`-SkipPluginAdd`（你已 `pnpm link` 装好依赖：跳过 `dsh plugin add`，激活与 shim 照做）、`-ShimDir <path>`、`-WhatIf`（只打印计划，零写入）。任何一步失败都以退出码 1 报错，不静默降级。

`install.ps1` **不会**替你重启宿主。

### 4.4 重启宿主（由你本人执行）

新的工具面要等宿主重新启动后才会注册。重启这一步请你自己完成：在会话里触发一次重启，或关掉宿主再启动。

### 4.5 装完自检

两条都要成立，缺一条工具就不会出现：

```powershell
# 1) 层树里有这个包名（没有就回 4.2 末段补）
(Get-Content "$env:USERPROFILE\.dsh\profiles\web\package.json" -Raw |
  ConvertFrom-Json).dsh.profile.bundles

# 2) 合成后的层栈里有这一行
dsh --profile web --dump-config | Select-String 'dsh-restart-win'
```

再验引擎与工具：

```powershell
dsh-restart-win -Status -Json            # 应输出单个 JSON 对象，退出码 0
dsh-restart-win -Preflight               # 深度验证（耗时长，会真启一个临时实例）
```

宿主重启后，会话里应能看到四个 `win_restart*` 工具。

---

### 4.6 DSH Desktop（Electron）宿主

引擎同样驱动 DSH Desktop（`DeepSeek Harness.exe`）。它与 `dsh web` 有四处硬差异，重启器必须按这四处建模：

| | `dsh web` | DSH Desktop |
|---|---|---|
| 宿主进程 | `node.exe ... dsh\lib\bin.js web` | Electron 的 **Node 模式子进程**（`--expose-internals ...\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js`），进程名 `DeepSeek Harness.exe` |
| 端口 | 固定（`--port 3080`） | `--port 0`：**每次启动都随机** |
| 停机 | 杀端口监听者 | 杀 Electron **主进程**整棵树；只杀子进程会把壳留在 host crash 对话框 |
| 隔离验证 | 临时 home 里起 `dsh web` | 临时 home 里直接起同一个 Electron 宿主入口（App 有单实例锁，再开一个 `DeepSeek Harness.exe` 只会聚焦旧窗口） |

`hostKind`（配置键 / 工具参数 / `-HostKind`）取值 `auto`（默认）、`web`、`desktop`。装到桌面版 profile 时，在用户层把该行指向 desktop：

```yaml
# %USERPROFILE%\.dsh\profiles\desktop\cordis.patch.yml
- id: dsh-restart-win
  config:
    profile: desktop      # 插件自身的默认值是 `web`
```

`desktop` 模式下，引擎按「命令行 + 父进程链」四要素发现宿主，用 `netstat` 反查真实端口，写续跑通知后 `taskkill /T /F` 杀 Electron 主进程整棵树，重放记录的可执行文件，再等一个**新的**宿主子进程、且它监听的端口回 `401`/`200`。`-Status` 会给出 `hostKind`、`mainPid`、`resolvedPort`、`configuredPort`、`portSource`、`instanceShape`；`-Port` 退化为期望值（`status.portSource = "netstat"`）。冷启动前先记录一次 App 路径：

```powershell
dsh-restart-win -Record -RecordCommand '"C:\<app>\DeepSeek Harness.exe"' -RecordWorkingDirectory "$env:USERPROFILE"
```

桌面版上的 `-Preflight` 直接以 Node 模式起 Electron 宿主入口（隔离 home），不碰正在运行的 App，验证的是同一套插件栈。

每次桌面版重启在**碰旧实例之前**还有两道检查：`gui-smoke` 用临时 `--user-data-dir` 真起一次
Electron **主进程**（只验隔离宿主入口，证明不了壳自己的启动期校验能过），要求它拉起宿主；随后
`watchdog` 往同一个临时 userData 写一份带该主进程 `shell pid` 的崩溃记录，要求
`Wait-DesktopHostReady` 在秒级内以 `reason=main-crashed` 失败并透传原始 `Error:` 行。第二步注入的
是崩溃**记录**而不是真崩溃 —— 但读它的是生产函数、进程是真的、userData 是隔离的。`-Preflight`
下看门狗没反应会在停机前中止；普通重启只记 warn。


### 4.7 右栏面板

包里带一个客户端半端（`client.js`，通过 manifest 的 `dsh.client` 声明），桌面版和 web 版都会在右栏长出一个 **DSH 重启** 标签页：

- **状态**：宿主形态、实测端口 vs 配置端口、Electron 主进程 pid、宿主 pid、HTTP 探针、profile、版本，以及带复制按钮的鉴权访问地址；每 8 秒自动刷新。
- **动作**：刷新、演练、深度验证、安全重启、只停、只拉；`restart` / `stop` 需要点两次确认。
- **回显**：分离执行的动作用 `runId` 跟进，面板逐条渲染引擎的 `steps`，再给结论、退出码和结果文件；`runId` 存在 `localStorage`，宿主重启后面板会接着轮询同一个 run。
- **历史**：最近五条 `restart-history.jsonl`。

面板只打同源的 `/dsh-restart-win/api/*`（沿用宿主的会话认证；写操作必须证明 `Origin`）。路由内部直接复用 agent 调用的那四个工具实现，不存在第二套逻辑。没有 web server 的宿主加载不了本插件（`inject: ['tools', 'webServer']`），这与其他面板插件的取舍一致。

客户端半端随包分发，**重启一次宿主**就会出现，不需要构建。


### 4.8 远程停止（反向代理域名下的兜底入口）

经反向代理域名（例如 tailscale serve 出来的 `https://<host>.ts.net`）访问时，会话输入框右侧的原生停止方块在部分会话上「点了没反应」：`ui-conversation` 的 `scopedConversation()` 取不到会话作用域时会同步抛错，而 `stop()` 把它 `catch` 掉了，于是既没有请求也没有报错。宿主侧的取消通路本身是好的，所以这里补一个直连它的悬浮入口。

**什么时候出现**：页面主机名**不是回环**（`localhost`、`127.0.0.1`、`[::1]` 都不出现），且命中 `GET /dsh-restart-win/api/meta` 返回的 `trustedHosts`（`.suffix`、`*.suffix`、整串主机名三种写法）；拿不到 `meta` 时退回「主机名以 `.ts.net` 结尾」。因此本机直连时不打扰，经代理访问时才有。

**面板内容**：

- 右侧 34px 圆钮 `⏹`，点开是「进行中的会话」列表（默认每 5 秒刷新）。
- 列表来自 `GET /dsh-restart-win/api/sessions`：宿主对每个 live session 取最近 400 条事件，最后一个 turn 事件是 `turn/start` 而没有配对的 `turn/end` 才算 `running`。**不再用「浏览器打开过的会话」冒充运行中**——那个接口（`/archived-sessions/active-session`）只表示当前页面打开过谁。
- 标题经 `/archived-sessions/sidebar-state` 的 `titles` 懒补（侧栏那个接口比 `/archived-sessions/sessions` 快一个数量级），拿不到时显示 `session…末四位` 并保留完整 id 在 `title` 属性里。
- 停止按钮 `POST /api/session/cancel`，信封必须是
  `{"type":"client-request","rpcId":"…","method":"session/cancel","payload":{"args":{"request":{"sessionId":"…"}}}}`；
  按 `result.ok` 与 `result.value.accepted` 区分「已停止」「该会话当前没有进行中的回合」「停止失败（附 error.message/code）」。
- 没有进行中的会话时给出明确空态文案。

**API 契约（前端只用这四个，不自己发明运行态字段）**：

| 端点 | 方法 | 用途 | 形状 |
| --- | --- | --- | --- |
| `/archived-sessions/active-session` | GET | 「当前页面打开过哪些会话」——**不等于在跑**，只用它做快速首屏 | `{"activeSessionIds":["…"]}` |
| `/archived-sessions/sidebar-state` | GET | 会话标题映射，用来把短 id 换成标题；比 `/archived-sessions/sessions` 快一个数量级 | `{"titles":{"<sessionId>":"<标题>"}}` |
| `/dsh-restart-win/api/sessions` | GET | 宿主侧真实运行态：每个 live session 最近 400 条事件里最后一个 `turn/start`/`turn/end` | `{"ok":true,"items":[{"sessionId","cwd","createdAt","parentSession","running","turn","runningSince","lastTurnEvent","lastEventAt"}]}` |
| `/api/session/cancel` | POST | 取消该会话当前回合 | 见下 |

取消走的 RPC 信封（字段名写错会被 gateway 依次回 `gateway/bad-request` / `gateway/arguments-invalid`）：

```json
{"type":"client-request","rpcId":"…","method":"session/cancel","payload":{"args":{"request":{"sessionId":"…"}}}}
```

成功响应：`{"type":"server-response","rpcId":"…","result":{"ok":true,"value":{"accepted":true}}}`。`accepted:false` 表示「该会话当前没有进行中的回合」，不是失败。

**怎么验**（改完宿主模块必须重启，模块是启动时 import 的）：

```powershell
# 1) 端点通不通（本机直连，cookie 用宿主自己的；从 tailnet 域名访问时浏览器会自动带上）
curl.exe -s --noproxy '*' http://127.0.0.1:<port>/dsh-restart-win/api/sessions

# 2) 起一个长跑探针，再点停止，确认回合真的被取消
#    session_bridge_create -> 让它跑 Start-Sleep 600，然后点面板里的「停止」
#    用 session_bridge_status 看 openTurn 是否变 no / idle

# 3) 刷新页面、重启宿主后各看一次：⏹ 是否还在、是否只有一个（面板 id 唯一，
#    mount 前会先移除同 id 旧节点）
```

**边界**：只扫描每个会话最近 400 条事件，历史很长但最新就是 `turn/start` 的会话能正确识别；极长的静默回合若中间没有任何事件且起点被挤出 400 条窗口，会被当成空闲——属于可接受的观测误差，停止按钮只是兜底，不替代原生入口。


### 4.8 两种安装布局：`app.asar` 与解包后的 `resources\app`

有些补丁/bridge 工具会把 `resources\app.asar` 解成真实目录 `resources\app\dsh`。引擎两种都认：先看 asar 文件，没有再找 `resources\app\dsh`，发现、深度验证、共享投影重建都按实际存在的那一种走。`-Status` 在两种布局下都能报出实例；不会再因为「app.asar 不存在」就判定桌面运行时缺失。

## 5. 五个工具

五个工具的输入都先过白名单校验再拼 argv 数组（从不拼 shell 字符串），非法值直接返回错误而不是回退到默认值。`tools` 配置可以逐个关掉（`restart` / `status` / `preflight` / `result` / `install`）。

### 5.1 `win_restart`

发起重启（或 start / stop / dry-run / record / 计划任务管理）。**重启类动作分离执行**：工具立即返回 `{ started, runId, resultFile }`，引擎在 `restartDelayMs`（默认 1500 ms）之后才动宿主，保证这次调用的结果先落盘。

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `action` | string 枚举 | `restart` | `restart` 安全完整重启；`start` 只拉起；`stop` 只停机；`status` 只读快照；`dry_run` 演练；`record` 记录启动命令；`task_register` / `task_unregister` 管理计划任务；`preflight` / `verify_only` 长时隔离验证 |
| `fast` | boolean | false | 跳过深度验证。存在运行实例时，引擎仍会拒绝停机，除非同时给 `forceUnverified` |
| `forceUnverified` | boolean | false | 显式承担「未验证就停机」的风险（仅与 `fast` 同用有意义） |
| `viaTask` | boolean | false | 由计划任务执行重启，脱离宿主进程树 |
| `dryRun` | boolean | false | 演练；仅对 `action=restart` 有效，等价于引擎的 `-DryRun` |
| `tryCtrlC` | boolean | false | 停机前先尝试一次优雅 Ctrl+C |
| `waitIdleSec` | integer | 0 | 重启前等待会话空闲的秒数（0 = 不等） |
| `idleMaxSec` | integer | 300 | 空闲等待的硬上限 |
| `delayMs` | integer | 配置 `restartDelayMs` | 分离动作：引擎触碰宿主前的延迟 |
| `profile` / `port` / `bindHost` | string / integer / string | 配置值 | 覆盖本次调用的 profile、端口、探针地址 |
| `hostKind` | string enum | 配置值 | `auto` / `web` / `desktop`；desktop 下端口实测、停机杀 Electron 主进程树 |
| `dshHome` / `stateDir` | string | 配置值 | 覆盖 DSH 家目录 / 引擎状态目录 |
| `taskName` | string | 配置值 | 计划任务名 |
| `pwshPath` | string | 自动 | 指定 PowerShell 可执行文件（默认 `pwsh`，回落 `powershell.exe`） |
| `readySec` / `verifyReadySec` / `graceSec` / `portFreeSec` | integer | 90 / 150 / 3 / 30 | 各项等待预算 |
| `session` | string | 当前会话 | 续跑通知要投递到的会话 id |
| `reason` | string | 引擎默认 | 写进续跑通知的原因文本 |
| `recordCommand` | string | — | `action=record` 必填：启动宿主的完整命令 |
| `recordWorkingDirectory` | string | — | `action=record`：启动时的工作目录 |
| `verifyTempRoot` | string | `%TEMP%` | 隔离验证实例的临时根 |

输出（`ok`、`action`、`started`、`state` ∈ `ok`/`failed`/`running`、`runId`、`resultFile`、`exitCode`、`summary`、`error`、`delayMs`、`detail`）。`state=running` 表示已排程，用 `win_restart_result` 取结论。

### 5.1.1 `install_plugin`

走安全安装通道（§5.5.1），是 `plugin_manager` 的替代品：后者直接对运行中的 profile 调 pnpm。参数：`action`（必填）、
`spec`、`bundle`、`healthSec`、`reason`、`profile`、`dshHome`、`stateDir`、`pwshPath`。

- `status` / `plan` / `repair_scope` / `check_shadowed`：只读或单步修复，随时可调。
- `install`：**长调用、前台执行**——`-Status` 判断宿主是否在跑 → `-Stop` → 脚本 `-OnDemand -Confirm`（快照、pnpm、落盘检查、查遮蔽、失败回滚）→ `-Start`。宿主在中间会停一次，当前会话会断。

输出：`ok`、`action`、`state` ∈ `ok`/`failed`、`runId`、`reportFile`、`exitCode`、`summary`、`error`、`detail`（`install` 时 `detail.steps` 逐阶段列出 stop / install / start 的结果，`detail.report` 是脚本的机器可读报告）。

### 5.2 `win_restart_status`

只读快照，前台执行，不改任何东西。参数：`profile`、`port`、`bindHost`、`dshHome`、`stateDir`、`pwshPath`。

输出：`ok`、`state`、`result`、`version`、`exitCode`、`durationMs`、`hostUrl`、`targetPid`、`warnings[]`、`status`（引擎 `status` 富对象原样透传：`instances` / `http` / `serving` / `bootRecord` / `lastRestart` / `marker` / `launchUrl` 等）、`stateDir`、`logPath`、`error`、`stderrTail`。

### 5.3 `win_restart_preflight`

长时隔离验证：符号链接权限探针 + 在临时 home 里真启一个一次性实例。**不碰生产实例**，分离执行并立即返回 `{ started, runId, resultFile }`。

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `mode` | string 枚举 | `preflight` | `preflight` 或 `verify_only`；两者在引擎里走同一分支，行为等价（见 §8） |
| `delayMs` | integer | 配置 `restartDelayMs` | 启动前的延迟 |
| `verifyTempRoot` | string | `%TEMP%` | 隔离实例的临时根 |
| `profile` / `port` / `bindHost` / `dshHome` / `stateDir` / `pwshPath` | — | 配置值 | 同 `win_restart` |
| `readySec` / `verifyReadySec` / `graceSec` / `portFreeSec` | integer | 90 / 150 / 3 / 30 | 等待预算 |

输出：`ok`、`started`、`state` ∈ `running`/`failed`、`mode`、`runId`、`resultFile`、`delayMs`、`error`、`detail`（含 `verifyTimeoutMs`）。结论用 `win_restart_result` 读。

### 5.4 `win_restart_result`

按 `runId`（或 `stateDir` 内显式 `resultFile`）读回分离任务的结果，四态：`ok` / `failed` / `running` / `unknown`。

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `runId` | string | — | `win_restart` / `win_restart_preflight` 返回的 id，形如 `20260101-120000-a1b2c3` |
| `resultFile` | string | — | 显式结果文件路径，必须位于 `stateDir` 之内 |
| `stateDir` | string | 配置值 | 该次运行用了非默认状态目录时指定 |
| `waitMs` | integer | 0 | 最多等待多久（上限 120000）；0 = 只读一次 |

输出：`ok`、`state`、`runId`、`resultFile`、`action`、`startedAt`、`finishedAt`、`exitCode`、`summary`、`ageMs`、`error`、`envelope`（引擎结果信封原样）。

---

## 5.5 插件安装 / 修复：`scripts\dsh-plugin-install.ps1`

装插件最容易踩的三个坑（都在本机真实发生过）：运行中 `pnpm add` 把宿主打断、pnpm 顺手清掉
`<DSH_HOME>\profiles\node_modules`（宿主的共享投影，清掉之后 App 连基础包都 import 不到）、
第三方插件把旧版 `@deepseek-ai/*` 提升进 profile 遮蔽 App 自带版本。这个脚本把「停机 → 装 →
查遮蔽 → 拉起 → 健康校验」固定成一条链路，任一步失败就回滚快照。

它**没有自己的路径知识**：引擎路径、安装根、profile、node、pnpm 全部由
`dsh-restart-win -Status -Json` 给出（见 §8 的 `status.desktopApp` / `runtimeDir` / `pnpm` / `nodeExe`）。

```powershell
# 只看现在有哪些会话在写（不停机、不改文件）
pwsh -NoProfile -File .\scripts\dsh-plugin-install.ps1 -CensusOnly

# 先看计划，再执行；-Detach 通过 WMI 脱离宿主进程树
pwsh -NoProfile -File .\scripts\dsh-plugin-install.ps1 -Spec '@scope/some-plugin@1.2.3' -WhatIfPlan
pwsh -NoProfile -File .\scripts\dsh-plugin-install.ps1 -Spec '@scope/some-plugin@1.2.3' -Confirm -Detach -Bundle

# 单项修复（等价于引擎的 -CheckShadowed / -RepairSharedScope）
pwsh -NoProfile -File .\scripts\dsh-plugin-install.ps1 -CheckShadowed -Confirm
pwsh -NoProfile -File .\scripts\dsh-plugin-install.ps1 -RepairSharedScope -Confirm
```

`-Report <path>` 把机器可读结果写成 UTF-8 JSON（调用方不必解析控制台）。`-Engine` / `-Profile` /
`-DshHome` / `-NodeExe` / `-PnpmMjs` 可覆盖自动解析；每次运行都会顺带刷新
`<StateDir>\machine.json`（见 §5.6）。

### 5.5.1 `install_plugin`：让 agent 走这条路，而不是 `plugin_manager`

DSH 自带的 `plugin_manager` 工具（`dsh-plugin-manager/tools`）直接调 pnpm 打运行中的 profile，
正是本节开头那三个坑的来源，而且它和 pnpm 之间没有任何可插入的钩子。所以本插件另外注册了一个
**`install_plugin`** 工具，把同一条安全链路暴露给模型：

| 动作 | 做什么 |
| --- | --- |
| `status` | 只读：机器事实 + 活跃会话（等价 `-CensusOnly`） |
| `plan` | 只读：给定 spec 的完整步骤（等价 `-WhatIfPlan`） |
| `install` | 停宿主 → `-OnDemand` 安装 → 拉起；`detail.steps` 逐阶段回报 |
| `repair_scope` | 重建共享投影（等价引擎 `-RepairSharedScope`） |
| `check_shadowed` | 移走遮蔽基础包（等价引擎 `-CheckShadowed`） |

分工是刻意划开的：**工具负责停机与拉起**，脚本用 `-OnDemand` 只做快照、pnpm、落盘检查、查遮蔽与回滚，
所以脚本不会对已经停掉的宿主再 `-Stop` 一次（那会以非零码退出）。`install` 是长调用，宿主会在中间停一次，
当前会话会断；`status` / `plan` / `check_shadowed` 随时可调，不改任何东西。

`plugin_manager` 保持原样不动——这一步只是给 agent 一条明确的替代路径，观察一轮后再决定是否重定向。
想在某个 profile 关掉它：`tools.install: false`。

## 5.6 机器事实：`scripts\dsh-config.ps1`

引擎找 DSH Desktop 可执行文件的顺序是：`<StateDir>\machine.json` → 本次已解析 → 运行中的实例 →
启动档案 → 默认安装位置 → **系统登记处反查**（卸载登记 / `App Paths` / 开始菜单与桌面快捷方式）。
最后那一步是为「App 装在非默认目录、又正好停着」准备的 —— 本机实测过这种状态：固定候选全落空，
`-Start` 直接 fail-closed。

```powershell
# 探测并写入 machine.json（-Show 只预览，-Reset 删除）
pwsh -NoProfile -File .\scripts\dsh-config.ps1 -Show
pwsh -NoProfile -File .\scripts\dsh-config.ps1
# 装在意想不到的位置时，直接告诉它
pwsh -NoProfile -File .\scripts\dsh-config.ps1 -DesktopApp 'D:\Apps\DeepSeek Harness\DeepSeek Harness.exe'
```

引擎参数 `-DesktopApp <path>` 优先级最高（显式给出即短路全部探测）。`machine.json` 缺失或损坏时
引擎会退回探测链，不会因为这个文件报错。

---

## 6. 命令行 `dsh-restart-win`

`bin/dsh-restart-win.mjs` 是引擎的命令行双胞胎：没有配置层，没有额外校验，参数与退出码就是引擎自己的。stdout/stderr 直接继承，长任务会实时打印。

```powershell
dsh-restart-win -Status -Json
dsh-restart-win -Preflight -ResultFile "$env:TEMP\preflight.json"
dsh-restart-win -DryRun
```

安装脚本生成的 `%LOCALAPPDATA%\dsh-restart\bin\dsh-restart-win.cmd` 只是把 node 转发到这个入口。

### 6.1 引擎开关全表

| 开关 | 值 | 作用 |
|---|---|---|
| `-Status` | — | 只读状态 |
| `-DryRun` | — | 演练，不做副作用 |
| `-Start` | — | 只拉起（冷启动），不写续跑通知 |
| `-Stop` | — | 只停机（不与 `-Start` 同用） |
| `-Json` | — | stdout 输出单个 JSON 对象 |
| `-Fast` | — | 跳过深度验证 |
| `-ForceUnverified` | — | 与 `-Fast` 同用，显式接受未验证停机 |
| `-VerifyOnly` | — | 只跑深度验证 |
| `-Preflight` | — | 与 `-VerifyOnly` 等价 |
| `-Record` | — | 写启动档案 |
| `-RegisterTask` / `-UnregisterTask` | — | 注册 / 删除计划任务 |
| `-TryCtrlC` | — | 停机前尝试优雅 Ctrl+C |
| `-ViaTask` | — | 交给计划任务执行（立即返回） |
| `-ViaTaskInner` | — | 计划任务内部标记；引擎里没有消费它的分支，仅为兼容保留 |
| `-ResultFile` | path | 把最终结果 JSON 写到该文件（任何终态都写） |
| `-NoWait` | — | 收尾不停留：跳过等新 boot token 的 20 s，只做一次非阻塞扫描 |
| `-Profile` | string | DSH profile（默认 `web`） |
| `-HostKind` | `auto` / `web` / `desktop` | 宿主形态；`auto` 检测 DSH Desktop，否则按 `dsh web` |
| `-RepairSharedScope` | — | 从已安装的 `app.asar` 重建 `<DSH_HOME>\profiles\node_modules`（桌面宿主解析 `@deepseek-ai/*` 用的基础包投影）后退出。App 打不开、崩溃日志里基础包全是 `ERR_MODULE_NOT_FOUND` 时用它。加 `-DryRun` 只报源布局与当前文件数，**不写盘** |
| `-CheckShadowed` | — | 把 profile 里版本与 App 自带不一致的 `@deepseek-ai/*` 移进 `.stale-packages`（这类遮蔽会让 `settings` 服务起不来：App 报 *Web RPC failed*，6 个插件一直 pending） |
| `-Port` | int | 宿主端口（默认 `3080`，同时决定互斥体名） |
| `-BindHost` | string | 探针地址（默认 `127.0.0.1`）。它**不影响**宿主监听地址，见 §8 |
| `-DshHome` | path | DSH 家目录（默认 `%DSH_HOME%`，否则 `%USERPROFILE%\.dsh`） |
| `-StateDir` | path | 状态目录（默认 `%DSH_RESTART_HOME%`，否则 `%LOCALAPPDATA%\dsh-restart`） |
| `-ReadySec` / `-VerifyReadySec` / `-GraceSec` / `-PortFreeSec` | int | 90 / 150 / 3 / 30 秒 |
| `-WaitIdleSec` / `-IdleMaxSec` | int | 空闲等待与硬上限（0 / 300） |
| `-Session` | string | 续跑通知的目标会话；`auto` 取最新会话 |
| `-Reason` | string | 续跑通知的原因文本 |
| `-RecordCommand` / `-RecordWorkingDirectory` | string | `-Record` 的启动命令与工作目录 |
| `-TaskName` | string | 计划任务名（默认 `DSH Restart`） |
| `-VerifyTempRoot` | path | 隔离验证实例的临时根（默认 `%TEMP%`） |
| `-DoNotTouchDshHome` | — | 兼容保留的开关：引擎里没有任何分支消费它，行为等于不写 |

---

## 7. 配置

配置写在 `cordis.patch.yml` 的插件行 `config` 下（也可以用宿主提供的插件配置界面改）。默认值等于旧引擎在 Windows 上的既有行为。

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `profile` | string | `web` | 被重启的 DSH profile |
| `hostKind` | string | `auto` | 宿主形态：`auto` 检测 DSH Desktop，`web` / `desktop` 钉死 |
| `port` | integer | `3080` | 宿主端口，也是互斥体名与进程发现的依据 |
| `bindHost` | string | `127.0.0.1` | 探针与状态展示用的地址。**改它不会改变宿主监听地址**（见 §8） |
| `dshHome` | string | `''` | 空 = `%DSH_HOME%`，再回落 `%USERPROFILE%\.dsh` |
| `stateDir` | string | `''` | 空 = `%DSH_RESTART_HOME%`，再回落 `%LOCALAPPDATA%\dsh-restart`。保持默认才能继续用旧日志、启动档案与续跑通知 |
| `taskName` | string | `DSH Restart` | 计划任务名（`-ViaTask` / `-RegisterTask` / `-UnregisterTask` 用） |
| `pwshPath` | string | `''` | 空 = 自动：`pwsh` 优先，回落 `powershell.exe` |
| `readySec` | integer | `90` | 重启后就绪等待上限 |
| `verifyReadySec` | integer | `150` | 隔离验证实例的就绪上限 |
| `graceSec` | integer | `3` | 优雅停机宽限 |
| `portFreeSec` | integer | `30` | 等端口释放的上限 |
| `restartDelayMs` | integer | `1500` | 工具先返回，再等这么久才动宿主 |
| `toolTimeoutMs` | integer | `30000` | 前台短任务超时 |
| `verifyTimeoutMs` | integer | `600000` | 分离验证任务的预算（`win_restart_result` 等待时也受它约束） |
| `trustedHosts` | string[] | `[]` | 面板 API 除回环外额外接受的 `Host`：精确 hostname 或 `*.suffix` 通配。经反向代理（如 `tailscale serve`，`Host: <主机>.tailnet.ts.net`）访问 GUI 时必须配；默认只认回环 |
| `injectHostEnv` | boolean | `true` | 拉起宿主时是否把 `DSH_UC_PROFILE_NODE_MODULES` / `NPM_CONFIG_LEGACY_PEER_DEPS` 注入子进程（见 7.1）；`false` 时以 `DSH_RESTART_INJECT_HOST_ENV=0` 通知引擎跳过 |
| `tools.restart` | boolean | `true` | 是否注册 `win_restart` |
| `tools.status` | boolean | `true` | 是否注册 `win_restart_status` |
| `tools.preflight` | boolean | `true` | 是否注册 `win_restart_preflight` |
| `tools.result` | boolean | `true` | 是否注册 `win_restart_result` |

非法配置会让插件在加载时就失败并指明字段（`dsh-restart-win config: <field>: ...`），不会静默回落到默认值。

### 7.1 拉起宿主时注入的两个环境变量

拉起宿主之前，引擎把两个变量写进**那份即将被拉起的进程环境**：

| 变量 | 值 | 为什么存在 |
|---|---|---|
| `DSH_UC_PROFILE_NODE_MODULES` | `<DshHome>\profiles\node_modules` | 本机插件装在 profile 的 `node_modules` 下；不显式指路时，更新检查器可能把包装进 `node_modules` 却**不写** `package.json` 与 `pnpm-lock.yaml`，下次装包就丢 |
| `NPM_CONFIG_LEGACY_PEER_DEPS` | `true` | rc 版宿主的 peer 范围常年对不上；不开这个开关，临时目录里的 `npm` 取包会以 ERESOLVE 失败 |

三条要点：

1. **只写进程作用域。** 变量写在引擎自己的进程环境里，由 `Start-Process` 交给新宿主；不写用户级、不写系统级，宿主退出后没有残留，也不会影响你终端里的 npm。
2. **可以关掉。** 配置 `injectHostEnv: false`（默认 `true`）时，插件以 `DSH_RESTART_INJECT_HOST_ENV=0` 启动引擎，引擎跳过这两条注入并记一条 `skip` 步骤。换到一台不需要这两个 workaround 的机器时用它；默认值等于旧行为。
3. **自检没有污染系统**（两条都应输出空）：

```powershell
[Environment]::GetEnvironmentVariable('NPM_CONFIG_LEGACY_PEER_DEPS', 'User')
[Environment]::GetEnvironmentVariable('DSH_UC_PROFILE_NODE_MODULES', 'User')
```

---

## 8. 三个必须知道的接口事实

1. **`-Preflight` 与 `-VerifyOnly` 等价。** 旧版 help 文本暗示 `-Preflight` 额外做符号链接预检，实际两者都做、走同一分支。文档如实写等价，不为「看起来有区别」制造差异。
2. **`-BindHost` 不参与启动命令。** 宿主绑哪个地址由启动档案（`boot-record.json`）或默认启动计划决定；`-BindHost` 只影响探针 URL 与状态显示。想改监听地址要改启动档案，不是改这个配置。
3. **`-DoNotTouchDshHome` 是死参数。** 它被声明、被接受、没有任何分支消费，行为等于「不写」。为兼容旧命令行保留。

`-Status -Json` 的 `status` 里另有四个「安装事实」字段，供外部工具直接使用（不必自己推导安装根）：

| 字段 | 含义 |
|---|---|
| `desktopApp` | 解析到的 DSH Desktop 可执行文件（桌面版；web 版为空串） |
| `desktopAppSource` | 这个路径从哪来：`explicit` / `machine-config` / `resolved` / `running-instance` / `boot-record` / `default-location` / `registry/shortcut` |
| `runtimeDir` / `appRoot` | 运行时代码目录（asar 或解包后的 `resources\app\dsh`）与安装根 |
| `pnpm` / `nodeExe` | 装插件要用的 pnpm 入口与应用自带的 node（`pnpm` 是按布局算出来的候选路径） |
| `pnpmResolved` / `cliCmd` | 上面那个候选里**实际存在**的 pnpm.mjs，以及安装自带的 `dsh.cmd`（官方布局在 `resources\runtime` 下，解包后桥把 pnpm 放到 `resources\app\runtime` 下 —— 外部工具直接用这两个字段，不要自己拼） |

引擎里的系统工具（`netstat` / `taskkill` / `schtasks` / `robocopy` / `cmd`）一律经 `Get-SystemTool`
解析到 `%SystemRoot%\System32`，不依赖调用方 PATH —— 从 git-bash、精简 PATH 的计划任务里调用时行为一致。

`-Json` / `-ResultFile` 的信封里还有一个 `phases` 键，记录这次调用各阶段花了多少毫秒
（`pre-check` / `host-kind` / `instances` / `instances-2` / `cim` / `history` / `probe:<端口>` /
`http-probe` / `auth-file` / `auth-log` / `auth-url` / `total`）。同名点（同一端口的多次探测）累加，
不是覆盖 —— 所以明细之和与 `total` 对得上。它只在机器接口下产生，人读模式零开销；
14 个必选字段与层级不变，读不到 `phases` 的旧消费方不受影响。

### 8.1 桌面宿主的多个监听端口，引擎挑了哪一个

DSH Desktop 的宿主是 `--port 0` 起的，起来之后可能同时监听好几个面。本机实测的一次：

| 端口 | 回应 | 是什么 |
|---|---|---|
| 3082 | `200` | 宿主给本机开的默认面（就是 `-Status` 的 `http`） |
| 4173 | `200` | `dsh-browser` 的浏览器调试协议 —— 也是 200，但不是宿主的 HTTP 面 |
| 48691 | `401` | 宿主自身的面板面（要 token，所以不带 token 就是 401） |
| 48696 | `404` | 兜底路由还挂着的空壳 |

引擎按 **401 > 200 > 303 > 其他** 的优先级逐个探，命中就停，结果写进 `instances[].probe`
（每个端口的实测状态、毫秒、阶段）。`401` 排在第一是因为「端口绑好、认证层要 token」说明服务
是活的；`4173` 这种同为 200 的调试面只能靠「已经选定了就别再换」避开，不能靠猜端口号。
等新一轮重启时，宿主会在随机端口上先回 `404`、隔一秒才变 `401`/`200`，所以只有「端口通了但给了
状态码」的候选才会在 700ms 后重问一次 —— 连不上的端口不会翻倍等待。

2026-11-27 两次真机修（都不是推演）：

- `content-type: application/json` 的 `404` 是宿主的路由**兜底面**（几毫秒就答），永远不是宿主面。
  它现在排在所有兜底候选的最后，并且**不管本轮有没有选中就绪面**都会被学进 `aux-ports.json`。
  在此之前，真面偶尔读超时一次就让它赢了：`-Status` 报的是 `48xxx+14/404` 而不是活着的 `401` 面。
- 没有任何面就绪、且至少有一个端口「连上了但一个字没回」时，这一组会再探一遍，然后才退回 404。
  忙起来的宿主长的就是这个样子：socket 连上，读超时。第二遍只发生在本来就要报坏消息的路径上
  （实测 5.7s 换来正确答案；健康路径仍是 0.8s）。

`probe` 里每个条目还有 `stage`，它区分「没选它」的三种情况：

| `stage` | 含义 |
|---|---|
| `http` | 真探了，`status` 是当时的状态码 |
| `skipped` | 已知不是宿主的面（上次实测学到的，`known: "aux"`），本次没探 |
| `unprobed` | 本次没探，留给 `instances-2` 补探（第一轮命中 200 就停了） |
| `budget-exhausted` | 探针总预算用完，后面的端口没探 |

学到的附件端口存在 `%LOCALAPPDATA%\dsh-restart\aux-ports.json`，按 Electron 主进程 pid 归属 ——
App 重启后 pid 变了，旧结论一律作废。`401` 面永不被当作附件面（它可能就是宿主自己的面）。

---

## 9. 退出码与终态词

退出码与 `result` 词是既有可脚本化接口，未做任何改动。`-Json` 下它们在信封的 `exitCode` / `result` 字段里，同时进程退出码一致。

| 退出码 | `result` 词 | 含义 |
|---|---|---|
| 0 | `restarted-ok` | 重启成功 |
| 0 | `status` | 只读状态返回 |
| 0 | `verify-only-ok` | 预检 / 深度验证通过 |
| 0 | `dry-run` | 演练完成（不产生副作用） |
| 0 | `stopped` | 停机完成，或本来就没有目标实例 |
| 0 | `task-registered` | 计划任务已注册 / 更新 |
| 0 | `task-unregistered` | 计划任务已删除 |
| 0 | `via-task-dispatched` | 已交给计划任务，立即返回 |
| 0 | `recorded` | 启动档案已写入 |
| 0 | `rescued-after-abort:<原因>` | 中止发生在停机之后，抢救拉起成功 |
| 1 | `aborted:<首行异常>` | 未捕获异常（终态仍记录） |
| 1 | `task-register-failed` | 计划任务注册失败 |
| 1 | `task-unregistered` | `schtasks /Delete` 失败（任务不存在或权限不足）；信封同时带 ok=false |
| 2 | `locked` | 已有另一个重启在跑（不排队、不重试） |
| 2 | `engine-requires-pwsh` | 该动作需要 pwsh 7.4+，在停机前中止 |
| 2 | `invalid-args` | 参数组合非法（例如 `-Stop` 与 `-Start` 同用） |
| 3 | `config-invalid` | `--dump-config` 组合校验失败，旧实例未动 |
| 4 | `verify-only-failed` | 预检 / 深度验证失败，日志保留 |
| 4 | `verify-failed` | 重启前的深度验证失败，旧实例未动 |
| 5 | `gate-blocked` | 配置操作门禁命中（transaction / lock 文件） |
| 6 | `stop-failed` | 停机失败（含权限边界） |
| 7 | `port-busy` | 端口未释放，放弃启动 |
| 8 | `ready-failed:<原因>` | 拉起后未就绪，已回收本次启动链；原因 ∈ `port-owner-mismatch` / `exited` / `timeout` |
| 9 | `via-task-failed` | 任务未注册或触发失败 |
| 10 | `verify-required` | 有实例但未验证就要停机，拒绝执行 |
| 11 | `launch-prereq-failed` | 拉起前置检查失败，在停机之前中止 |
| 12 | `stop-refused` | 端口占用者不是 node / dsh / bun，拒绝停机 |

`ready-failed:` 的三个原因词、`rescued-after-abort:` 与 `aborted:` 的前缀都是逐字契约，日志与排障脚本依赖它们。

---

## 10. 状态目录与文件

默认状态目录 `%LOCALAPPDATA%\dsh-restart`（可用 `stateDir` 改；保持默认才能复用既有文件）。

| 文件 | 由谁写 | 用途 |
|---|---|---|
| `boot-record.json` | 引擎（`-Record`） | 启动档案：`recordedAt` / `command` / `cwd` / `profile` / `port` / `host` / `dshHome` / `note`；重启时按它重放命令 |
| `restart-history.jsonl` | 引擎 | 每次执行一条 JSON 审计记录（16 个字段：`ts` / `version` / `result` / `rc` / `profile` / `port` / `target_pid` / `new_pid` / `url` / `session` / `reason` / `host` / `user` / `steps` / `warnings` / `audit`）。**不轮转** |
| `dsh-restart.log` | 引擎 | 每次执行一行人类可读终态 |
| `activity.json` | 引擎（只要拿到重启锁就写） | **活动台账**：`pid` / `version` / `action` / `hostKind` / `profile` / `port` / `step` / `note` / `elapsedSec` / `updatedAt`。进程每推进一步就重写，等待循环里每 2 秒刷新心跳。它回答的是「现在有没有人在干活、在等什么、等了多久」—— 文件很旧或 `processAlive:false` 就等于没人在跑（不是卡死）。`-Status` 直接读它，`status.activity` 里也带同一份 |
| `web-auth-url.txt` | 引擎 | 访问地址缓存：`url` / `token` / `pid` / `port` / `profile` / `savedAt` / `source`。含真实 token，按凭据对待 |
| `host.<hostKind>.out.log` / `.err.log` | 引擎 | 被拉起宿主的 stdout / stderr（追加 banner 后重定向）。按宿主形态分文件：桌面 App 会在整个生命周期里占着自己的日志句柄，共用一个名字会让另一侧的拉起失败 |
| `dsh-restart.task.xml` | 引擎（`-RegisterTask`） | 计划任务定义，UTF-16LE 带 BOM（`schtasks` 的要求） |
| `machine.json` | `scripts\dsh-config.ps1`（引擎参数 `-DesktopApp` 也会短路它） | 机器事实：`desktopApp` / `appRoot` / `runtimeDir` / `pnpm` / `nodeExe` / `profile` / `hostKind` / `dshHome`。引擎解析 DSH Desktop 可执行文件时**最先**读它；判定宿主形态（`-HostKind auto`）时它是**比启动档案更权威**的落盘事实 —— 冷启动（DSH 还没起来）靠它才不会把一台桌面版机器误判成 `web`；缺失或损坏则退回探测链，不影响启动 |
| `dsh-plugin-install-<时间戳>.log` / `.json` / `.snapshot\` | `scripts\dsh-plugin-install.ps1` | 插件安装/修复的执行日志、机器可读结果、以及安装前的 `package.json` + `pnpm-lock.yaml` 快照（回滚依据） |
| `fallback\` | 引擎 | 上述日志 / 历史写失败时的第二落点 |
| `runs\<runId>.pending.json` | 插件 | 分离任务的登记记录（动作、延迟、引擎脚本、pwsh 来源、宿主 pid、launcher pid） |
| `runs\<runId>.request.json` | 插件 | 分离执行器的启动请求（delay、runId、execPath、完整 argv） |
| `runs\<runId>.launch.json` | 插件 | 执行器的回执（enginePid、delay、是否成功、引擎退出码） |
| `runs\<runId>.result.json` | 引擎 | `-ResultFile` 落盘的结果信封，`win_restart_result` 读它 |

另外两个位置：

| 路径 | 用途 |
|---|---|
| `<DshHome>\.smart-restart\pending-notice.json` | 续跑通知 `{sessionId, reason, when}`，UTF-8 无 BOM，**停机之前**写，宿主启动时消费后删除 |
| `<DshHome>\.smart-restart\marker.json` | 宿主写的 pid / lastBootAt / dshVersion，引擎**只读** |
| `<VerifyTempRoot>\dsh-verify.<8hex>` | 隔离验证实例的临时 home；失败时保留日志供排障 |

### 10.1 配对使用：`dsh-pending-notice-waker`

`pending-notice.json` 是一张交接单，得有人来消费。消费方就是
[`dsh-pending-notice-waker`](https://github.com/BrainZombie/dsh-pending-notice-waker)——
一个宿主启动后延迟 `delaySec` 秒跑一次、跑完就退的 bundle。

| | 引擎（本仓库） | waker |
|---|---|---|
| 职责 | 把宿主停掉、再拉起来 | 把被中断的会话唤醒一次 |
| 时机 | **停机之前** | **启动之后** |
| 产出 | `pending-notice.json`（UTF-8 无 BOM，先写 `.tmp` 再改名） | `.smart-restart` 下的 `inbox/` / `archive/` / `throttle.json` / `waker.log` |
| 缺了对方 | 重启照常，但会话不会自己回来，得手动点开 | 等一个没人写的文件，正常情况下一条日志都不会有 |

两个包在包级别互不依赖、也互不附带，所以**装本引擎不会顺带装 waker**。想让「重启完回到原会话」闭环，两个都要装：

```powershell
# 引擎（本仓库）
pwsh -File .\install.ps1
# waker
pwsh -File <dsh-restart-win>\scripts\dsh-plugin-install.ps1 -Spec link:<path-to>\dsh-pending-notice-waker -Confirm -Bundle
# 已发布后可直接：-Spec dsh-pending-notice-waker
```

waker 拿到通知后的顺序：先 rename 进 `inbox/`（处理中的文件不会被新通知覆盖）→ `sessionId` 为空（`no-session-id`）、超过 `maxAgeHours`（`stale`）、同会话 60 分钟内已唤醒两次（`throttled`）则只归档 → 会话是死的就 `agents.resume`、活的就 `agents.get` → `agent.followup(...)` 投递唤醒文案 → 归档 `done`。resume 失败累加 `attempts`（写回 `inbox/` 那份）满 3 次归档 `failed-attempts`；报 `not found` 直接归档 `dropped` 不重试。任何异常都不向宿主冒泡。

两个实测要紧的点：

- **唤醒时必须挂回 preset。** `agents.resume({ resumeSessionId })` 只恢复会话、不恢复 agent preset，官方工具组整批不会组合进来，唤醒出来的会话只剩第三方插件工具——本机实测少 **39 个工具**、调 `pwsh` 直接 `Error: unknown tool "pwsh"`。waker **≥ 0.2.0** 会读持久化 header，用 `setup` 钩子把预设挂回去，和 `dsh-api-session-controller` / `dsh-acp` / `dsh-subagent` 走的是同一个入口。依赖这个行为就钉 `>= 0.2.0`。
- **这个症状天生是间歇的。** `agents.get(sessionId)` 命中时会直接短路掉 resume，所以 GUI 已经打开过的会话醒来是完整的；只有「宿主刚起来、GUI 还没打开、waker 抢先救活死会话」那一次才会降级。看到唤醒后的会话「少了一半工具」，先查这里。

waker 自己的配置（`enabled` / `delaySec` / `maxAgeHours` / `prompt`）见它仓库的 README；默认 `true` / `6` / `24`，唤醒文案内置，会在通知带 `resultPath` 时追加一行 `安装结果：<resultPath>`。

---

## 11. 前置条件与权限

| 前置 | 为什么 | 怎么满足 |
|---|---|---|
| **符号链接创建权限** | 宿主冷启动与隔离验证都要建 junction / symlink；建不了时预检在**旧实例还在**的阶段就失败（退出码 4），不会造成半个实例 | 打开 Windows 开发者模式，或以管理员身份运行一次 |
| **pwsh 7.4+** | `Start-Process -Environment` 是注入隔离环境的前提 | 安装 PowerShell 7；只有 5.1 时验证型动作会以退出码 2 中止 |
| **能终止宿主进程** | 停机用 `taskkill`；权限不足时报 `stop-failed` 并打印根因 | 用启动宿主的同一个用户运行；跨用户 / 服务上下文启动的宿主需要相应权限 |
| **计划任务（只在用 `-ViaTask` / `-RegisterTask` 时）** | 让执行者脱离宿主进程树 | `dsh-restart-win -RegisterTask`；任务按 `HighestAvailable` 注册 |
| **`%DSH_HOME%`**（可选） | 多套 DSH 家目录时区分状态 | 设环境变量或在配置里写 `dshHome` |

---

## 12. 安全边界

这个插件会**杀掉并重启你正在用的 DSH 宿主**。上一句话的后果必须自己承担，所以边界写在这里：

1. **重启由你本人执行。** 插件提供工具，agent 可以在你授权下调它；但真正让宿主消失的那一瞬间，会话会断。不要把它当成「后台静默操作」，第一次请盯着屏幕跑。
2. **它必须拥有杀进程的权限。** 停机走 `taskkill`，没有「软着陆」保证；`-TryCtrlC` 只是停机前的一次尝试，默认关闭。
3. **它先验证再停机，但不保证业务正确。** 深度验证证明的是「这个 profile 组合能起来并返回 401/200」，不证明你的数据、会话或插件状态完好。
4. **它不提升自己。** 不请求 UAC、不写系统级配置、不改用户级环境变量（只写用户 PATH，且仅在你运行 `install.ps1` 时）。计划任务按既有权限运行。
5. **它不联网。** 所有判断基于本机端口、进程、文件与 HTTP 探针。
6. **`web-auth-url.txt` 里有真实 token。** 别把它贴进 issue、日志或截图。
7. **`restart-history.jsonl` 不会自动清理。** 长期使用会一直长；需要时自己归档。

---

## 13. 故障排查

先看四个地方：工具返回的 `error`（或 CLI 的 stderr）、`<stateDir>\activity.json`（**有没有人在干活**）、`<stateDir>\dsh-restart.log` 的最后一行、`<stateDir>\restart-history.jsonl` 的最后一条。

**「点了重启，命令行一动不动，好像没反应」。** 先读 `activity.json`：

- `processAlive:true` 且 `ageSec` 很小 → 引擎在跑，正在 `step` 里说的那一步等（本工具最长的一段是 `deep-verify`：要复制 profile 再拉起一个一次性宿主，本机实测 70 s 起步；其次是 `ready`：等新宿主打好端口，约 40-60 s）。`-Status` 会把同一句打包成「当前动作」一行，人读模式带颜色。
- `processAlive:false`（或文件根本不存在）→ 没有引擎在跑，它已经退出了。看 `dsh-restart.log` 最后一行拿终态词。

CLI 直接跑（`dsh-restart-win -Start`）时每一行阶段输出都会实时打出来；`-Json` / 工具通道下人类可读文字走 **stderr**（stdout 只能有一个 JSON 对象），所以重定向到文件时看不到是正常的 —— 用 `activity.json` 和终态词判断进度。

**冷启动（开机后 DSH 还没起来）时宿主形态判错。** `-HostKind auto` 的判据顺序是「运行中的宿主 → `machine.json` 的 `hostKind` → 启动档案 → web」。三种来源哪个生效会写在 `status.hostKindSource`（`running-instance` / `machine.json` / `boot-record` / `default` / `explicit`）。若这台机器其实是桌面版却报 `web`，跑一次 `scripts\dsh-config.ps1` 把机器事实写进 `machine.json`，或显式 `-HostKind desktop`。

**一次动作最多等多久。** 引擎在拿锁之后算一个总预算（`-Json` 的 `steps` 里有一行 `budget`），所有等待层都引用同一个截止时刻：桌面版重启约 `portFreeSec + readySec + graceSec + 60` 秒，web 版再加两轮深度验证（`2 × verifyReadySec + 60`）。超出即明确失败，不会各层各自重新计时。

**App 报「应用无法启动 / Web RPC failed」，但宿主其实在监听。** 装第三方插件时 pnpm 可能把旧版 `@deepseek-ai/dsh-settings`（或其它基础包）提升到 profile 的 `node_modules`，遮蔽 App 自带版本；`settings` 服务因此永远不注册，欢迎窗口的 RPC 失败。执行 `dsh-restart-win -CheckShadowed`（引擎在每次拉起前也会自动检查，把旧版本移进 `.stale-packages`）。

**App 完全打不开，宿主崩溃日志里基础包全是 `ERR_MODULE_NOT_FOUND`。** 桌面宿主从 `<DSH_HOME>\profiles\node_modules` 解析 `@deepseek-ai/*`（那是 `app.asar\dsh\node_modules` 的投影），profile 里跑一次 `pnpm install` 可能把它清掉。执行 `dsh-restart-win -RepairSharedScope` 从已安装的 `app.asar` 重建；引擎在拉起 App 前也会自动修一次。全新空白 profile 也会复现，所以这不是 profile 损坏。

| 现象 / 退出码 | 原因 | 处理 |
|---|---|---|
| 2 `locked` | 已有一个重启在跑（互斥体 `Local\dsh-restart-p<port>`） | 等它结束；确认没有卡死的引擎进程 |
| 2 `engine-requires-pwsh` | 当前 PowerShell 不支持该动作所需能力 | 装 pwsh 7.4+，或用 `pwshPath` 指过去 |
| 2 `invalid-args` | `-Stop` 与 `-Start` 同用，或 `-ResultFile` 不可写 | 改参数组合；检查结果文件目录 |
| 3 `config-invalid` | `--dump-config` 组合校验失败 | 按日志里那条失败原因修 profile；权限类报错不算配置错误，不会走到这里 |
| 4 `verify-failed` / `verify-only-failed` | 隔离实例起不来 | 看保留的 `dsh-verify.*` 目录里的日志；常见原因是 `node_modules` 缺失或符号链接权限 |
| 5 `gate-blocked` | 有未完成的配置事务或锁文件 | 先处理 `*.transaction` / `RECOVERY_REQUIRED*`；日志里会提示残留锁的回收命令 |
| 6 `stop-failed` | 权限不足，或进程没被杀掉 | 看日志里的 `Access is denied` 段与两条出路；必要时用同用户或提权终端 |
| 7 `port-busy` | 旧实例停了但端口仍被占用 | 找占用者（`netstat -ano -p TCP`），确认后手动清理 |
| 8 `ready-failed:timeout` | 新宿主在预算内没就绪 | 调大 `readySec`；看 `host.<hostKind>.err.log`（web 宿主上是 `host.web.err.log`） |
| 8 `ready-failed:exited` | 新宿主起来又立刻退出 | 看 `host.<hostKind>.err.log` / `.out.log` 尾部；多为启动命令或 profile 问题 |
| 8 `ready-failed:port-owner-mismatch` | 端口上的监听者不是本次启动的进程 | 检查是否有包装器脚本；引擎会沿父链核对 |
| 9 `via-task-failed` | 计划任务未注册或触发失败 | 先 `-RegisterTask`，再 `-ViaTask` |
| 10 `verify-required` | `-Fast` 遇到运行中的实例 | 去掉 `-Fast` 做完整验证，或显式加 `-ForceUnverified` |
| 11 `launch-prereq-failed` | 启动命令的第一个词解析不到，或 cwd 的 `package.json` 把它定义成本地脚本 | 用 `-Record` 写入一条可执行的启动命令；修好后再重启 |
| 12 `stop-refused` | 端口占用者不是 node / dsh / bun | 确认那是什么进程；这个保护是为了不误杀 |
| 0 `rescued-after-abort:` | 中止发生在停机之后，已尽力拉回 | 宿主已恢复，但请核对日志里的中止原因 |
| 工具返回 `state=unknown` | `runId` 不存在或结果文件还没写 | `win_restart_result` 带 `waitMs` 再读，或确认 `stateDir` 一致 |

深度验证长（默认预算 150 s × 最多两次尝试，加上隔离 home 的组装），`win_restart_preflight` 返回 `running` 是正常的：用 `win_restart_result` 轮询，或读 `activity.json` 的 `step` / `note` 看它走到哪一步（等待循环里每 2 秒刷新一次心跳）。

---

## 14. 已验证与未验证

**在本仓库的自动化里跑过、有输出可复跑的部分**：参数表（35 个，新增 `-ResultFile` / `-NoWait`）、退出码字面量集合、`-Json` 单对象信封、`-Status` / `-DryRun` / `-Preflight` 实跑、`-ResultFile` 落盘与不可写路径、`-Stop -Start` 冲突路径、人读模式无 JSON 行、`scripts/check-encoding.ps1` 在 pwsh 7 与 Windows PowerShell 5.1 下 `errors=0`、`install.ps1` 的幂等与 `-WhatIf`、`npm test`、四个工具在无宿主环境下加载、`win_restart_status` 打通真实引擎、CLI 与引擎退出码一致、分离执行 < 5 s 返回并在延迟后落 `ok`、引擎 stdout 不进宿主 stdio。

**换一台机器能不能跑，有一次实证**：在全新克隆上（仓库用 `.gitattributes` 把换行锁成 `eol=lf`）跑 `npm test`——退出码 0，selftest 77 通过、parity 243/243 行全部断言、integration 16 通过 + 1 跳过；引擎在新克隆里仍是 UTF-8 BOM + LF，`scripts\check-encoding.ps1` 通过。所以「从 GitHub 克隆下来就能跑」不是承诺，是跑过的结果。安装侧的激活步骤也在 fixture profile 上实测过：备份原 manifest、追加到末尾、其他 bundle 相对顺序不变、二次运行跳过、包没真正装进 profile 时**拒绝**写 `dsh.profile.bundles`（避免「列了但没装」这种静默失败）。

**没有在本仓库的自动化里执行的部分**（它们会停掉宿主、需要管理员、或需要真实实例；逻辑从原引擎逐行移植，未改判定）：

| 未验证项 | 为什么没跑 | 你自己怎么验一次 |
|---|---|---|
| 完整重启（默认动作） | 会杀掉当前宿主，中断正在跑的会话 | 在你能接受中断的时候跑 `dsh-restart-win -DryRun` 确认计划，再跑一次真重启 |
| `-Stop` 对活动实例 | 同上 | 选一个空闲时段；先 `-DryRun` 看计划 |
| `-RegisterTask` / `-UnregisterTask` | 会写系统计划任务，可能需要管理员 | `dsh-restart-win -RegisterTask`，然后 `schtasks /Query /TN "DSH Restart"` 核对 |
| `-ViaTask` 分发 | 依赖上面那条先成立 | 注册后跑 `-ViaTask`，看 `schtasks` 里的上次结果 |
| `-TryCtrlC` | 需要可交互的宿主控制台，默认关闭 | 只在明确知道后果时开 |
| `-ForceUnverified` | 它的语义就是承担风险 | 不建议常规使用 |

所以：把「未验证」当成「没试过」，不是「有问题」；但也别在关键时段第一次就跑真重启。

---

## 15. 开发与测试

```powershell
npm test                                  # node --check + 单测/契约测试
node test/parity.mjs                      # 把 docs/parity-matrix.md 的每一行断言成「有实现 + 有证据」
pwsh -NoProfile -File scripts\check-encoding.ps1
powershell.exe -NoProfile -File scripts\check-encoding.ps1
```

编码规则（两个引擎都要能解析同一个文件）：

- `.ps1` 必须 **UTF-8 BOM + LF**；无 BOM 时 Windows PowerShell 5.1 会按本地代码页解析含中文的脚本并报大量语法错误。
- `scripts/dsh-restart.task.xml` 必须 **UTF-16LE 带 BOM**（`schtasks` 的要求）。
- `.cmd` shim 必须**纯 ASCII + CRLF**（`cmd.exe` 按 OEM 代码页读文件）。

仓库结构：

```
lib/index.js              插件入口：配置归一化 → 取工具定义 → 注册 / 卸载
lib/config.js             配置与调用参数的归一化、白名单校验（纯函数，fail-closed）
lib/paths.js              pwsh / 引擎脚本 / dshHome / stateDir / runs 目录解析
lib/runner.js             argv 构建、前台执行、分离执行、run 记录读写
lib/tools.js              四个工具的定义（参数、输出 schema、render、execute）
lib/delayed-spawn.mjs     分离执行器：等 restartDelayMs，再拉起引擎并等它结束
bin/dsh-restart-win.mjs   CLI：把参数原样转给引擎
scripts/dsh-restart.ps1   引擎（唯一可执行真源）
scripts/dsh-restart.task.xml  计划任务模板（占位符版）
scripts/check-encoding.ps1    编码 / 换行 / 双引擎 Parser 校验
install.ps1               装 profile + 写 PATH shim
test/selftest.mjs         单测与契约测试
test/probe-hostport.ps1   真 socket 验证 -Status 的选面（从引擎里抽出 Resolve-HostPort /
                          Invoke-HttpProbe 原样执行，对面是两个真实的 HTTP 面）
docs/parity-matrix.md     功能对照表（每行有旧实现位置、目标位置、验证方式）
docs/migration.md         从旧引擎切换与回退
```

CI（`.github/workflows/ci.yml`）：Ubuntu 跑 Node 单测与 `node --check`；Windows 跑双引擎 `check-encoding`、对每个 `.ps1` 做 `Parser::ParseFile`、`npm test` 与 `test/parity.mjs`。

---

## 16. 卸载与回退

```powershell
# 1. 从 profile 移除插件（下一次宿主启动后不再注册工具）
#    安装来源是 GitHub 时，依赖名仍然是这个包名
dsh plugin --profile web remove @brainzombie/dsh-restart-win

# 2. 再从 dsh.profile.bundles 里删掉 "@brainzombie/dsh-restart-win" 这一项
#    只做第 1 步的话，下次启动会打印 skipping profile bundle 并继续报错

# 3. 删掉 PATH shim（可选）
Remove-Item "$env:LOCALAPPDATA\dsh-restart\bin\dsh-restart-win.cmd"

# 4. 删掉计划任务（只有注册过才需要）
dsh-restart-win -UnregisterTask
```

状态目录默认**不删**：`%LOCALAPPDATA%\dsh-restart` 里的日志、启动档案与历史是资产，删了等于丢掉续跑与排障依据。确认不再需要时再整目录删除。

回退到旧引擎：[docs/migration.md](https://github.com/BrainZombie/dsh-restart-win/blob/main/docs/migration.md) 给出了「旧目录冻结归档 → 插件接管 → 需要时切回」的完整步骤，以及旧命令到新工具 / 新 CLI 的逐条对照。

---

## 17. 许可证

MIT，版权 BrainZombie。见 [LICENSE](LICENSE)。
