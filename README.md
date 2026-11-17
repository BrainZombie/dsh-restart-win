# dsh-restart-win

**A Windows-only, verify-before-you-stop restart engine for a DSH host.** It boots a throw-away instance in a temporary home on a free port, proves that this configuration can come up, and only then touches the instance that is serving you. The stop and the launch run from a detached supervisor or a scheduled task, so the host dying cannot take the executor with it.

`@brainzombie/dsh-restart-win` · Windows 10/11 · Node ≥ 20 · DSH 0.2.x · MIT

English | [中文](README.zh.md)

---

## 1. What this is

A DSH host plugin that turns "restart safely" into five verifiable steps:

1. **Discover** — the authority for "which process is the host" is the port listener from `netstat -ano -p TCP`, not WMI/CIM and not command-line matching.
2. **Prove** — boot a real instance in an isolated home on a free port. Only `401`/`200` counts as ready (`404` means the port is bound but routes are not registered yet).
3. **Gate** — if the preflight fails, nothing moves: the old instance is untouched, the call returns a non-zero exit code with a reason.
4. **Stop and launch** — write the resume notice → stop the old instance → wait until the port is actually bindable → rebuild the environment block → launch → verify port ownership and the parent chain.
5. **Close out** — every outcome writes an audit record; if the abort happened after the stop, try one rescue launch.

It is an engine, not a button. The four host tools and the CLI all drive the same PowerShell script, `scripts/dsh-restart.ps1`, and keep the old engine's parameters, exit codes, terminal words and state files.

---

## 2. How it differs from the restart plugins already out there

Most restart options are "a button that restarts immediately" or "a watchdog outside the process that retries". These are the 13 projects that GitHub's `dsh-plugin` topic returned by stars in 2026-11:

| Project | Shape | Relation to this plugin |
|---|---|---|
| `anweat/dsh-restart` (npm `dsh-restart`) | Configurable restart + post-restart prompt resume + watchdog | Overlapping (resume, watchdog); different package name |
| npm `dsh-restart-guard` | Out-of-process watchdog, restarts and reports to IM/webhook | Complementary: it watches from outside, this plugin initiates from inside |
| `edusrez/dsh-smart-restart` | Restart detection + agent wake-up + systemd unit + canary | Complementary: this plugin owns the Windows-side verification and stop, it owns returning to the session |
| `893413974-bit/dsh-setting-restart` | Settings-page one-click restart | Different shape (UI button) |
| `xiaolu511/dsh-hot-restart` | In-window button, restarts and reopens | Different shape (UI button) |
| `luoshuizhiwei/dsh-desktop-restart` | Desktop restart button + downtime readout | Different shape (UI button) |
| `1123762794/dsh-web-restart` | Sidebar one-click web restart | Different shape (UI button) |
| `PPsz-qqq/dsh-restart-button` | Session-header restart button + waits for tasks | Different shape (UI button) |
| `xichen-62/dsh-power-menu` | Desktop power menu (shut down / restart) | Different shape (UI menu) |
| `keyiadiannao/dsh-power-button` | Sidebar power button + its own restart engine | Different shape (UI button) |
| `regrevia/dsh-unlag` | Desktop refresh button | Different capability |
| `hulibuld/dsh-refresh-restart` | Refresh/restart button | Different shape (UI button) |
| `fakechris/dsh-harness-ops` | A/B snapshot upgrades + supervised launch + doctor | Adjacent (self-healing), via snapshot upgrades |

The differences concentrate in five places:

| | Button-style | Watchdog-style | This plugin |
|---|---|---|---|
| Proves the new configuration boots before stopping | No | No | **Yes** — isolated home, free port, one real boot |
| Process discovery | Remembered pid or name | Remembered pid | **Port listener**, with parent-chain verification |
| Stops without verification | Yes | Yes | **Refuses** (`-Fast` without `-ForceUnverified` → exit code 10) |
| Executor leaves the host process tree | No | Yes | **Yes** — detached supervisor or scheduled task |
| Scriptable read-only surface | Usually none | Partial | **Yes** — single-JSON `-Status -Json`, stable exit codes |

It does not provide "return to the previous conversation after the restart": the host does that by consuming `<DshHome>\.smart-restart\pending-notice.json` (which is what a plugin like `dsh-smart-restart` does). This plugin only guarantees the notice is written **before** the stop.

---

## 3. Requirements

| Item | Requirement | Notes |
|---|---|---|
| OS | Windows 10 / 11 | The engine targets Windows only; elsewhere there is no PowerShell and the tools fail with an explicit error |
| PowerShell | `pwsh` 7.4+ | A verified restart needs `Start-Process -Environment`. With only 5.1, `-Status` / `-DryRun` / `-Stop` / `-Start` / `-Fast` work, and any action that needs deep verification aborts before the stop with exit code 2 `engine-requires-pwsh` |
| Node.js | ≥ 20 | The host's own runtime; the detached launcher `lib/delayed-spawn.mjs` runs on the same `node` |
| DSH | 0.2.x (`>=0.2.1-rc.1 <0.3.0-0`) | See `dsh.compatibility` in `package.json` |
| Rights | Able to terminate the host process | Usually no elevation for a host started by the same user; the scheduled task registers as `HighestAvailable` |

---

## 4. Install

### 4.1 Check the patch against your profile first (no install needed)

```powershell
dsh --profile web --dump-config --patch .\cordis.patch.yml
```

This only composes the layer stack: it overlays the patch on the target profile's configuration and prints the result. It **changes no configuration and needs no restart**. Exit code 0 plus a `dsh-restart-win` row in the output means this patch resolves for this profile.

It does not activate the plugin. Activation is 4.2 / 4.3 below, followed by the host restart you perform in 4.4.

### 4.2 Add it to a profile

```powershell
# from the GitHub repository (the current distribution channel)
dsh plugin --profile web add github:BrainZombie/dsh-restart-win

# pin a commit (reproducible install)
dsh plugin --profile web add github:BrainZombie/dsh-restart-win#<sha>

# or point at a local checkout
dsh plugin --profile web add <repo>
```

> This version is **not published to npm**: `dsh plugin --profile web add @brainzombie/dsh-restart-win` only works once the package is on npm. Until then, use one of the GitHub forms above.

`dsh plugin add` forwards its arguments to pnpm inside that profile directory and records the dependency in the profile's `package.json`. The plugin inserts its own `dsh-restart-win` row through its `cordis.patch.yml`.

**It also has to be activated: append the package to `dsh.profile.bundles`.** `dsh plugin add` only puts the package into `node_modules` and `dependencies`. At startup the host composes the tree from the profile's layer stack, which has exactly three sources: the explicit `dsh.profile.bundles` list, the profile's own `cordis.patch.yml`, and the launcher's `--patch`. Without this step the host prints `skipping profile bundle "@brainzombie/dsh-restart-win"`, or simply never loads the plugin's tools.

Open `%USERPROFILE%\.dsh\profiles\<profile>\package.json` and append the package name to the **end** of `dsh.profile.bundles` (append; order does not affect this plugin):

```jsonc
// %USERPROFILE%\.dsh\profiles\<profile>\package.json
"dsh": {
  "profile": {
    "bundles": [
      /* ...keep every existing entry... */,
      "@brainzombie/dsh-restart-win"
    ]
  }
}
```

Never replace or empty the existing list: `@deepseek-ai/dsh-base`, `@deepseek-ai/dsh-web-app` and every plugin you already have live there. If the profile has no `dsh.profile` section yet, copy the baseline first and then add this plugin (for the `web` profile the baseline is `["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]`).

### 4.3 One-shot install with install.ps1 (recommended)

```powershell
cd <repo>
pwsh -NoProfile -File .\install.ps1 -Profile web
```

Four idempotent steps:

1. validate the checkout (`package.json` `name` and `bin`, plus `scripts\dsh-restart.ps1`, must exist);
2. run `dsh plugin --profile <p> add <repo>` (skipped when the dependency is already declared; `-Force` re-runs it);
3. **activate**: append the package name to the profile's `dsh.profile.bundles`. Before writing it confirms this package really declares `dsh.bundle.patch` (a non-bundle name in that list breaks the whole profile), backs up the original `package.json`, then re-reads and asserts "the name appears exactly once / the other bundles keep their order / the top-level keys and the dependency count are unchanged". Skipped when the name is already there;
4. write an ASCII CLI shim to `%LOCALAPPDATA%\dsh-restart\bin\dsh-restart-win.cmd` and add that directory to the **user** PATH (`-SkipPathUpdate` writes the shim only).

Step 3 is why you do not have to edit `dsh.profile.bundles` by hand; anyone who installed with a manual `dsh plugin add` still has to do it, as described at the end of 4.2.

Useful switches: `-SkipPluginAdd` (you already ran `pnpm link`: skips `dsh plugin add`; activation and the shim still run), `-ShimDir <path>`, `-WhatIf` (print the plan, write nothing). Any failed step exits with code 1 and a message; nothing degrades silently.

`install.ps1` does **not** restart the host for you.

### 4.4 Restart the host (you do this)

The new tools are registered when the host starts. Perform that restart yourself: trigger one from a session, or close the host and start it again.

### 4.5 Self-check

Both checks must hold — miss one and the tools will not appear:

```powershell
# 1) the package is in the layer tree (if not, go back to the end of 4.2)
(Get-Content "$env:USERPROFILE\.dsh\profiles\web\package.json" -Raw |
  ConvertFrom-Json).dsh.profile.bundles

# 2) the composed layer stack contains the row
dsh --profile web --dump-config | Select-String 'dsh-restart-win'
```

Then check the engine and the tools:

```powershell
dsh-restart-win -Status -Json            # one JSON object, exit code 0
dsh-restart-win -Preflight               # deep verification (slow; boots a throw-away instance)
```

After the host restarts, the four `win_restart*` tools should be visible in a session.

---

### 4.6 DSH Desktop (Electron) hosts

The engine also drives the DSH Desktop shell (`DeepSeek Harness.exe`), whose shape differs from `dsh web` in four ways a restarter must respect:

| | `dsh web` | DSH Desktop |
|---|---|---|
| Host process | `node.exe ... dsh\lib\bin.js web` | an Electron **Node-mode child** (`--expose-internals ...\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js`), process name `DeepSeek Harness.exe` |
| Port | fixed (`--port 3080`) | `--port 0`: **random on every launch** |
| Stop | kill the port listener | kill the Electron **main** process tree; killing the child alone leaves the shell on a host-crash dialog |
| Isolated verification | `dsh web` in a temporary home | the same Electron host entry in a temporary home (the app holds a single-instance lock, so a second `DeepSeek Harness.exe` only focuses the window) |

`hostKind` (config key, per-call argument, or `-HostKind`) selects `auto` (default), `web`, or `desktop`. On a desktop profile, point the row at that profile in the user layer:

```yaml
# %USERPROFILE%\.dsh\profiles\desktop\cordis.patch.yml
- id: dsh-restart-win
  config:
    profile: desktop      # the plugin's own default is `web`
```

With `desktop`, the engine discovers the host by command line **and** parent chain (four identity checks), reverse-looks the real port from `netstat`, writes the resume notice, stops the Electron main tree with `taskkill /T /F`, relaunches the recorded executable, and waits for a **new** host child whose listening port answers `401`/`200`. `-Status` reports `hostKind`, `mainPid`, `resolvedPort`, `configuredPort`, `portSource` and `instanceShape`; `-Port` becomes a hint (`status.portSource = "netstat"`). Record the app once so a cold start knows what to launch:

```powershell
dsh-restart-win -Record -RecordCommand '"C:\<app>\DeepSeek Harness.exe"' -RecordWorkingDirectory "$env:USERPROFILE"
```

`-Preflight` on a desktop profile boots the Electron host entry directly (Node mode + isolated home), so it validates the same plugin stack without touching the running app.


### 4.7 The sidebar panel

The package ships a client half (`client.js`, declared through `dsh.client` in the manifest), so a desktop or web host grows a **DSH 重启 / DSH restart** tab in the right sidebar:

- **Status**: host shape, resolved vs configured port, Electron main pid, host pid, HTTP probe, profile, version, and the authenticated launch URL with a copy button. Refreshes every 8 s.
- **Actions**: refresh, dry run, deep preflight, safe restart, stop only, start only. `restart` and `stop` ask for a second click.
- **Output**: a detached run is followed by `runId`; the panel renders the engine's `steps` line by line, then the summary, exit code and result file. The `runId` is kept in `localStorage`, so the panel resumes polling after the host restarts.
- **History**: the last five `restart-history.jsonl` records.

The panel talks to `/dsh-restart-win/api/*` on the same origin (the host's session auth applies; mutating calls must prove their `Origin`). The routes delegate to the same four tool implementations the agent calls — no second code path. A host without a web server cannot load the plugin (`inject: ['tools', 'webServer']`), which is the same trade-off other panel plugins make.

The client half is part of the package, so it appears after one host restart; no build step is involved.


## 5. The four tools

Every argument is whitelist-validated before it reaches an argv array (a shell string is never built); an invalid value returns an error instead of falling back to a default. Each tool can be switched off through `tools`.

### 5.1 `win_restart`

Start a restart (or start / stop / dry-run / record / scheduled-task management). **Restart-class actions run detached**: the tool returns `{ started, runId, resultFile }` immediately and the engine touches the host only after `restartDelayMs` (default 1500 ms), so this call's result is already on disk.

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `action` | string enum | `restart` | `restart` safe full restart; `start` launch only; `stop` stop only; `status` read-only snapshot; `dry_run` rehearse; `record` save the launch command; `task_register` / `task_unregister` manage the scheduled task; `preflight` / `verify_only` long isolated verification |
| `fast` | boolean | false | Skip deep verification. With a running instance the engine still refuses to stop unless `forceUnverified` is also set |
| `forceUnverified` | boolean | false | Explicitly accept stopping an instance that was not deep-verified (only meaningful with `fast`) |
| `viaTask` | boolean | false | Let the scheduled task perform the restart, leaving the host process tree |
| `dryRun` | boolean | false | Rehearse; valid only with `action=restart`, equivalent to the engine's `-DryRun` |
| `tryCtrlC` | boolean | false | Try one graceful Ctrl+C before terminating |
| `waitIdleSec` | integer | 0 | Seconds to wait for the session to go idle (0 = do not wait) |
| `idleMaxSec` | integer | 300 | Hard cap on the idle wait |
| `delayMs` | integer | config `restartDelayMs` | Detached actions: delay before the engine touches the host |
| `profile` / `port` / `bindHost` | string / integer / string | config values | Per-call override of profile, port, probe address |
| `hostKind` | string enum | config value | `auto` / `web` / `desktop`; desktop discovers the random port and stops the Electron main tree |
| `dshHome` / `stateDir` | string | config values | Per-call override of the DSH home and the engine state directory |
| `taskName` | string | config value | Scheduled-task name |
| `pwshPath` | string | auto | PowerShell executable (default `pwsh`, then `powershell.exe`) |
| `readySec` / `verifyReadySec` / `graceSec` / `portFreeSec` | integer | 90 / 150 / 3 / 30 | Wait budgets |
| `session` | string | current session | Session id the resume notice is addressed to |
| `reason` | string | engine default | Reason text stored in the resume notice |
| `recordCommand` | string | — | Required for `action=record`: the exact command that started the host |
| `recordWorkingDirectory` | string | — | `action=record`: the working directory the host was started in |
| `verifyTempRoot` | string | `%TEMP%` | Temp root for the isolated verification instance |

Output: `ok`, `action`, `started`, `state` ∈ `ok`/`failed`/`running`, `runId`, `resultFile`, `exitCode`, `summary`, `error`, `delayMs`, `detail`. `state=running` means scheduled; read the verdict with `win_restart_result`.

### 5.2 `win_restart_status`

Read-only snapshot, runs in the foreground, changes nothing. Parameters: `profile`, `port`, `bindHost`, `dshHome`, `stateDir`, `pwshPath`.

Output: `ok`, `state`, `result`, `version`, `exitCode`, `durationMs`, `hostUrl`, `targetPid`, `warnings[]`, `status` (the engine `status` object passed through unchanged: `instances` / `http` / `serving` / `bootRecord` / `lastRestart` / `marker` / `launchUrl` …), `stateDir`, `logPath`, `error`, `stderrTail`.

### 5.3 `win_restart_preflight`

Long isolated verification: symlink-privilege probe plus a real throw-away boot in a temporary home. **Nothing production is touched.** Runs detached and returns `{ started, runId, resultFile }` immediately.

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `mode` | string enum | `preflight` | `preflight` or `verify_only`; the engine handles both in one branch, so they are equivalent (see §8) |
| `delayMs` | integer | config `restartDelayMs` | Delay before the isolated run starts |
| `verifyTempRoot` | string | `%TEMP%` | Temp root for the isolated instance |
| `profile` / `port` / `bindHost` / `dshHome` / `stateDir` / `pwshPath` | — | config values | As in `win_restart` |
| `readySec` / `verifyReadySec` / `graceSec` / `portFreeSec` | integer | 90 / 150 / 3 / 30 | Wait budgets |

Output: `ok`, `started`, `state` ∈ `running`/`failed`, `mode`, `runId`, `resultFile`, `delayMs`, `error`, `detail` (includes `verifyTimeoutMs`). Read the verdict with `win_restart_result`.

### 5.4 `win_restart_result`

Read back a detached run by `runId` (or an explicit `resultFile` inside `stateDir`). Four states: `ok` / `failed` / `running` / `unknown`.

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `runId` | string | — | Id returned by `win_restart` / `win_restart_preflight`, e.g. `20260101-120000-a1b2c3` |
| `resultFile` | string | — | Explicit result file; must live inside `stateDir` |
| `stateDir` | string | config value | Set when that run used a non-default state directory |
| `waitMs` | integer | 0 | Wait up to this many milliseconds (max 120000); 0 = read once |

Output: `ok`, `state`, `runId`, `resultFile`, `action`, `startedAt`, `finishedAt`, `exitCode`, `summary`, `ageMs`, `error`, `envelope` (the engine envelope as written).

---

## 6. The command line: `dsh-restart-win`

`bin/dsh-restart-win.mjs` is the CLI twin of the engine: no config layer, no extra validation, exactly the engine's switches and exit codes. Stdio is inherited, so a long run prints live.

```powershell
dsh-restart-win -Status -Json
dsh-restart-win -Preflight -ResultFile "$env:TEMP\preflight.json"
dsh-restart-win -DryRun
```

The `%LOCALAPPDATA%\dsh-restart\bin\dsh-restart-win.cmd` shim that `install.ps1` writes just forwards to this entry point through `node`.

### 6.1 Every engine switch

| Switch | Value | Effect |
|---|---|---|
| `-Status` | — | Read-only status |
| `-DryRun` | — | Rehearse without side effects |
| `-Start` | — | Launch only (cold start); writes no resume notice |
| `-Stop` | — | Stop only (mutually exclusive with `-Start`) |
| `-Json` | — | Emit a single JSON object on stdout |
| `-Fast` | — | Skip deep verification |
| `-ForceUnverified` | — | With `-Fast`, explicitly accept an unverified stop |
| `-VerifyOnly` | — | Deep verification only |
| `-Preflight` | — | Equivalent to `-VerifyOnly` |
| `-Record` | — | Write the launch record |
| `-RegisterTask` / `-UnregisterTask` | — | Register / delete the scheduled task |
| `-TryCtrlC` | — | Try one graceful Ctrl+C before terminating |
| `-ViaTask` | — | Let the scheduled task do it (returns immediately) |
| `-ViaTaskInner` | — | Marker used by the scheduled task; no branch consumes it, kept for compatibility |
| `-ResultFile` | path | Write the final result JSON there (every terminal outcome) |
| `-NoWait` | — | Do not linger at the end: skip the 20 s boot-token wait and scan once |
| `-Profile` | string | DSH profile (default `web`) |
| `-HostKind` | `auto` / `web` / `desktop` | Host shape; `auto` detects DSH Desktop and otherwise stays on `dsh web` |
| `-RepairSharedScope` | — | Rebuild `<DSH_HOME>\profiles\node_modules` (the base-package projection the desktop host resolves `@deepseek-ai/*` from) out of the installed `app.asar`, then exit. Use it when the app no longer starts and its crash log lists base packages as `ERR_MODULE_NOT_FOUND` |
| `-CheckShadowed` | — | Move any `@deepseek-ai/*` inside the profile whose version differs from the app's own copy into `.stale-packages` (that shadowing makes the `settings` service never register: the app shows *Web RPC failed* and six plugins stay pending) |
| `-Port` | int | Host port (default `3080`; also names the mutex) |
| `-BindHost` | string | Probe address (default `127.0.0.1`). It does **not** change the host's listen address — see §8 |
| `-DshHome` | path | DSH home (default `%DSH_HOME%`, else `%USERPROFILE%\.dsh`) |
| `-StateDir` | path | State directory (default `%DSH_RESTART_HOME%`, else `%LOCALAPPDATA%\dsh-restart`) |
| `-ReadySec` / `-VerifyReadySec` / `-GraceSec` / `-PortFreeSec` | int | 90 / 150 / 3 / 30 seconds |
| `-WaitIdleSec` / `-IdleMaxSec` | int | Idle wait and its cap (0 / 300) |
| `-Session` | string | Target session for the resume notice; `auto` picks the newest one |
| `-Reason` | string | Reason text in the resume notice |
| `-RecordCommand` / `-RecordWorkingDirectory` | string | Launch command and working directory for `-Record` |
| `-TaskName` | string | Scheduled-task name (default `DSH Restart`) |
| `-VerifyTempRoot` | path | Temp root for the isolated verification instance (default `%TEMP%`) |
| `-DoNotTouchDshHome` | — | Compatibility switch: no branch consumes it, so it behaves as a no-op |

---

## 7. Configuration

Configuration lives under the plugin row's `config` in `cordis.patch.yml` (or in the host's plugin settings UI). The defaults are exactly the behaviour the engine already had on Windows.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `profile` | string | `web` | DSH profile being restarted |
| `hostKind` | string | `auto` | Host shape: `auto` detects DSH Desktop, `web` / `desktop` pin it |
| `port` | integer | `3080` | Host port; also the mutex name and the discovery key |
| `bindHost` | string | `127.0.0.1` | Address used for probes and status display. **Changing it does not change the host's listen address** (see §8) |
| `dshHome` | string | `''` | Empty = `%DSH_HOME%`, then `%USERPROFILE%\.dsh` |
| `stateDir` | string | `''` | Empty = `%DSH_RESTART_HOME%`, then `%LOCALAPPDATA%\dsh-restart`. Keep the default to reuse existing logs, boot records and resume notices |
| `taskName` | string | `DSH Restart` | Scheduled-task name (used by `-ViaTask` / `-RegisterTask` / `-UnregisterTask`) |
| `pwshPath` | string | `''` | Empty = auto: `pwsh` first, then `powershell.exe` |
| `readySec` | integer | `90` | Wait budget for the restarted host to become ready |
| `verifyReadySec` | integer | `150` | Readiness budget for the isolated verification instance |
| `graceSec` | integer | `3` | Graceful stop grace period |
| `portFreeSec` | integer | `30` | Wait budget for the port to be released |
| `restartDelayMs` | integer | `1500` | The tool returns first, then waits this long before touching the host |
| `toolTimeoutMs` | integer | `30000` | Foreground short-task timeout |
| `verifyTimeoutMs` | integer | `600000` | Budget for a detached verification run (also bounds how long `win_restart_result` waits) |
| `trustedHosts` | string[] | `[]` | Extra `Host` authorities the dashboard API accepts besides loopback: exact hostnames or `*.suffix` wildcards. Needed when the GUI is reached through a reverse proxy such as `tailscale serve` (`Host: <host>.tailnet.ts.net`); loopback-only stays the default |
| `injectHostEnv` | boolean | `true` | Whether to inject `DSH_UC_PROFILE_NODE_MODULES` / `NPM_CONFIG_LEGACY_PEER_DEPS` into the child process that becomes the host (see 7.1); `false` starts the engine with `DSH_RESTART_INJECT_HOST_ENV=0` so it skips them |
| `tools.restart` | boolean | `true` | Register `win_restart` |
| `tools.status` | boolean | `true` | Register `win_restart_status` |
| `tools.preflight` | boolean | `true` | Register `win_restart_preflight` |
| `tools.result` | boolean | `true` | Register `win_restart_result` |

An invalid value fails plugin load with the field name (`dsh-restart-win config: <field>: ...`); nothing silently falls back to a default.

### 7.1 The two environment variables injected when launching the host

Before launching the host, the engine writes two variables into the environment of **the process it is about to start**:

| Variable | Value | Why it exists |
|---|---|---|
| `DSH_UC_PROFILE_NODE_MODULES` | `<DshHome>\profiles\node_modules` | Plugins live under the profile's `node_modules`; without an explicit pointer the update checker can install a package into `node_modules` **without** updating `package.json` and `pnpm-lock.yaml`, so the next install drops it |
| `NPM_CONFIG_LEGACY_PEER_DEPS` | `true` | The rc host's peer ranges rarely agree; without this flag `npm` fetching packages in a temporary directory fails with ERESOLVE |

Three things to know:

1. **Process scope only.** The values are set in the engine's own process environment and reach the new host through `Start-Process`. Nothing is written at user or machine level, so nothing survives the host and the npm in your own terminal is unaffected.
2. **You can turn it off.** With `injectHostEnv: false` (default `true`) the plugin starts the engine with `DSH_RESTART_INJECT_HOST_ENV=0`; the engine skips both injections and records a `skip` step. Use it on a machine that does not need these workarounds — the default reproduces the old behaviour.
3. **Check that nothing leaked into the system** (both must print nothing):

```powershell
[Environment]::GetEnvironmentVariable('NPM_CONFIG_LEGACY_PEER_DEPS', 'User')
[Environment]::GetEnvironmentVariable('DSH_UC_PROFILE_NODE_MODULES', 'User')
```

---

## 8. Three interface facts you must know

1. **`-Preflight` and `-VerifyOnly` are equivalent.** The old help text implied `-Preflight` did an extra symlink preflight; both actually run the same branch and both probe the symlink privilege. The documentation states the equivalence and does not invent a difference.
2. **`-BindHost` is not part of the launch command.** Which address the host binds is decided by the launch record (`boot-record.json`) or the default launch plan; `-BindHost` only affects the probe URL and the status display. To change the listen address, change the launch record, not this setting.
3. **`-DoNotTouchDshHome` is a dead parameter.** It is declared, accepted, and no branch consumes it, so it behaves as a no-op. It stays for command-line compatibility.

---

## 9. Exit codes and terminal words

Exit codes and `result` words are an existing scriptable interface and have not changed. With `-Json` they appear as `exitCode` / `result` in the envelope, and the process exit code matches.

| Exit code | `result` word | Meaning |
|---|---|---|
| 0 | `restarted-ok` | Restart succeeded |
| 0 | `status` | Read-only status returned |
| 0 | `verify-only-ok` | Preflight / deep verification passed |
| 0 | `dry-run` | Rehearsal completed (no side effects) |
| 0 | `stopped` | Stop completed, or there was no target instance |
| 0 | `task-registered` | Scheduled task registered / updated |
| 0 | `task-unregistered` | Scheduled task deleted |
| 0 | `via-task-dispatched` | Handed to the scheduled task, returned immediately |
| 0 | `recorded` | Launch record written |
| 0 | `rescued-after-abort:<reason>` | Abort happened after the stop; rescue launch succeeded |
| 1 | `aborted:<first exception line>` | Uncaught exception (the terminal outcome is still recorded) |
| 1 | `task-register-failed` | Scheduled-task registration failed |
| 1 | `task-unregistered` | `schtasks /Delete` failed (task missing or access denied); the envelope also carries ok=false |
| 2 | `locked` | Another restart is already running (no queueing, no retry) |
| 2 | `engine-requires-pwsh` | This action needs pwsh 7.4+; aborted before the stop |
| 2 | `invalid-args` | Illegal argument combination (e.g. `-Stop` with `-Start`) |
| 3 | `config-invalid` | `--dump-config` combination check failed; the old instance was untouched |
| 4 | `verify-only-failed` | Preflight / deep verification failed; logs are kept |
| 4 | `verify-failed` | Pre-restart deep verification failed; the old instance was untouched |
| 5 | `gate-blocked` | Configuration-operation gate hit (transaction / lock files) |
| 6 | `stop-failed` | Stop failed (including permission boundaries) |
| 7 | `port-busy` | Port was not released; launch abandoned |
| 8 | `ready-failed:<reason>` | Not ready after launch; this launch chain was collected. Reason ∈ `port-owner-mismatch` / `exited` / `timeout` |
| 9 | `via-task-failed` | Task not registered, or triggering it failed |
| 10 | `verify-required` | An instance exists and the restart is unverified: refused |
| 11 | `launch-prereq-failed` | Launch preflight failed; aborted before the stop |
| 12 | `stop-refused` | The port owner is not node / dsh / bun; stop refused |

The three `ready-failed:` reasons and the `rescued-after-abort:` / `aborted:` prefixes are literal contracts: logs and troubleshooting scripts depend on them.

---

## 10. State directory and files

Default state directory: `%LOCALAPPDATA%\dsh-restart` (override with `stateDir`; keep the default to reuse the existing files).

| File | Written by | Purpose |
|---|---|---|
| `boot-record.json` | engine (`-Record`) | Launch record: `recordedAt` / `command` / `cwd` / `profile` / `port` / `host` / `dshHome` / `note`; the restart replays this command |
| `restart-history.jsonl` | engine | One JSON audit record per execution (16 fields: `ts` / `version` / `result` / `rc` / `profile` / `port` / `target_pid` / `new_pid` / `url` / `session` / `reason` / `host` / `user` / `steps` / `warnings` / `audit`). **Never rotated** |
| `dsh-restart.log` | engine | One human-readable terminal line per execution |
| `web-auth-url.txt` | engine | Launch-URL cache: `url` / `token` / `pid` / `port` / `profile` / `savedAt` / `source`. Contains a real token — treat it as a credential |
| `host.<hostKind>.out.log` / `.err.log` | engine | stdout / stderr of the launched host (banner appended, then redirected). Separate files per host kind: the desktop app keeps its own log handle for its whole lifetime, so sharing one name makes the other kind's launch fail |
| `dsh-restart.task.xml` | engine (`-RegisterTask`) | Scheduled-task definition, UTF-16LE with BOM (`schtasks` requires it) |
| `fallback\` | engine | Second location when the log / history write fails |
| `runs\<runId>.pending.json` | plugin | Detached-run registration (action, delay, engine script, pwsh source, host pid, launcher pid) |
| `runs\<runId>.request.json` | plugin | Launcher request (delay, runId, execPath, full argv) |
| `runs\<runId>.launch.json` | plugin | Launcher receipt (enginePid, delay, success, engine exit code) |
| `runs\<runId>.result.json` | engine | The `-ResultFile` envelope; `win_restart_result` reads it |

Two other locations:

| Path | Purpose |
|---|---|
| `<DshHome>\.smart-restart\pending-notice.json` | Resume notice `{sessionId, reason, when}`, UTF-8 without BOM, written **before** the stop and deleted by the host once consumed |
| `<DshHome>\.smart-restart\marker.json` | pid / lastBootAt / dshVersion written by the host; the engine only reads it |
| `<VerifyTempRoot>\dsh-verify.<8hex>` | Temporary home of the isolated verification instance; logs are kept on failure |

---

## 11. Prerequisites and permissions

| Prerequisite | Why | How |
|---|---|---|
| **Symlink creation privilege** | The host's cold start and the isolated verification both create junctions/symlinks; without them the preflight fails **while the old instance is still running** (exit code 4), so no half-started instance is left behind | Turn on Windows Developer Mode, or run once as administrator |
| **pwsh 7.4+** | `Start-Process -Environment` is what injects the isolated environment | Install PowerShell 7; with only 5.1, verified actions abort with exit code 2 |
| **Permission to terminate the host process** | The stop uses `taskkill`; insufficient rights report `stop-failed` with the root cause | Run as the same user that started the host; a host started under another user or a service context needs matching rights |
| **Scheduled task (only for `-ViaTask` / `-RegisterTask`)** | Lets the executor leave the host process tree | `dsh-restart-win -RegisterTask`; the task registers as `HighestAvailable` |
| **`%DSH_HOME%`** (optional) | Distinguish state when several DSH homes exist | Set the variable, or configure `dshHome` |

---

## 12. Safety boundaries

This plugin **kills and restarts the DSH host you are using**. You own the consequences of that sentence, so here are the boundaries:

1. **You perform the restart.** The plugin supplies the tool; an agent may call it with your authorization, but the moment the host disappears the session is cut. Do not treat it as a silent background operation — watch the first one.
2. **It must be allowed to kill processes.** The stop goes through `taskkill`; there is no "soft landing" guarantee, and `-TryCtrlC` is only one attempt before termination, off by default.
3. **It verifies before it stops, but does not verify your business state.** Deep verification proves that this profile combination can come up and answer `401`/`200`; it does not prove your data, sessions or plugin state are intact.
4. **It does not elevate itself.** No UAC prompt, no system-wide configuration, no user-level environment variable changes (it writes the user PATH only when you run `install.ps1`). The scheduled task runs with the rights it already has.
5. **It is not networked.** Every decision comes from local ports, processes, files and HTTP probes.
6. **`web-auth-url.txt` holds a real token.** Do not paste it into issues, logs or screenshots.
7. **`restart-history.jsonl` is never cleaned up.** It grows for as long as you use it; archive it yourself when it matters.

---

## 13. Troubleshooting

Look at three places first: the tool's `error` (or the CLI's stderr), the last line of `<stateDir>\dsh-restart.log`, and the last record in `<stateDir>\restart-history.jsonl`.

**The app shows *应用无法启动/Web RPC failed* although the host is listening.** A third-party install can hoist an older `@deepseek-ai/dsh-settings` (or another base package) into the profile's `node_modules`, shadowing the app's copy; the `settings` service then never registers and the welcome window's RPC fails. Run `dsh-restart-win -CheckShadowed` (the engine also does it before every launch and moves the offenders to `.stale-packages`).

**The app no longer starts at all, and its host crash log lists base packages as `ERR_MODULE_NOT_FOUND`.** The desktop host resolves `@deepseek-ai/*` from `<DSH_HOME>\profiles\node_modules` — a projection of `app.asar\dsh\node_modules` — and a profile `pnpm install` can prune it. Run `dsh-restart-win -RepairSharedScope` (rebuilds it from the installed `app.asar`); the engine also repairs it automatically before it launches the app. A fresh empty profile fails the same way, so this is not a corrupted profile.

| Symptom / exit code | Cause | Action |
|---|---|---|
| 2 `locked` | A restart is already running (mutex `Local\dsh-restart-p<port>`) | Wait for it; make sure no engine process is stuck |
| 2 `engine-requires-pwsh` | The current PowerShell lacks a capability this action needs | Install pwsh 7.4+, or point `pwshPath` at it |
| 2 `invalid-args` | `-Stop` with `-Start`, or `-ResultFile` is not writable | Fix the argument combination; check the result-file directory |
| 3 `config-invalid` | The `--dump-config` combination check failed | Fix the profile per the logged reason; permission errors are not config errors and do not land here |
| 4 `verify-failed` / `verify-only-failed` | The isolated instance would not start | Read the logs in the kept `dsh-verify.*` directory; usual causes are a missing `node_modules` or missing symlink privilege |
| 5 `gate-blocked` | An unfinished configuration transaction or lock file | Clear `*.transaction` / `RECOVERY_REQUIRED*` first; the log prints the stale-lock recovery command |
| 6 `stop-failed` | Insufficient rights, or the process survived | Read the `Access is denied` section and its two ways out; retry from the same user or an elevated shell |
| 7 `port-busy` | The old instance is gone but the port is still held | Find the owner (`netstat -ano -p TCP`) and clear it deliberately |
| 8 `ready-failed:timeout` | The new host was not ready within budget | Raise `readySec`; read `host.<hostKind>.err.log` (on a web host: `host.web.err.log`) |
| 8 `ready-failed:exited` | The new host started and immediately exited | Read the tail of `host.<hostKind>.err.log` / `.out.log`; usually the launch command or the profile |
| 8 `ready-failed:port-owner-mismatch` | The listener on the port is not the process this run launched | Check for a wrapper script; the engine walks the parent chain |
| 9 `via-task-failed` | Task not registered, or triggering failed | `-RegisterTask` first, then `-ViaTask` |
| 10 `verify-required` | `-Fast` met a running instance | Drop `-Fast` and verify, or pass `-ForceUnverified` explicitly |
| 11 `launch-prereq-failed` | The first word of the launch command does not resolve, or the cwd `package.json` defines it as a local script | Write a runnable command with `-Record`, then restart |
| 12 `stop-refused` | The port owner is not node / dsh / bun | Identify that process; the guard exists to avoid killing the wrong thing |
| 0 `rescued-after-abort:` | Abort happened after the stop; a rescue launch already ran | The host is back — still check the abort reason in the log |
| tool returns `state=unknown` | The `runId` does not exist, or the result file is not written yet | Call `win_restart_result` with `waitMs`, or confirm `stateDir` matches |

Deep verification is slow (default budget 150 s × up to two attempts, plus assembling the isolated home). `win_restart_preflight` returning `running` is normal: poll with `win_restart_result`.

---

## 14. What is verified and what is not

**Exercised by this repository's automation, with output you can reproduce**: the parameter table (35 parameters; `-ResultFile` / `-NoWait` added), the exit-code literal set, the single-object `-Json` envelope, real `-Status` / `-DryRun` / `-Preflight` runs, `-ResultFile` on success and on an unwritable path, the `-Stop -Start` conflict path, human mode emitting no JSON line, `scripts/check-encoding.ps1` with `errors=0` under both pwsh 7 and Windows PowerShell 5.1, `install.ps1` idempotency and `-WhatIf`, `npm test`, the four tools loading without a host, `win_restart_status` against the real engine, the CLI matching the engine's exit code, a detached run returning in under 5 s and settling to `ok` after the delay, and engine stdout never entering host stdio.

**"Can it run on another machine" has one concrete data point**: on a fresh clone (the repository pins line endings with `.gitattributes` and `eol=lf`), `npm test` exited 0 — selftest 77 passed, parity asserted all 243 rows, integration 16 passed with 1 skipped — and the engine was still UTF-8 BOM + LF in that clone (`scripts\check-encoding.ps1` passed). So "clone it on another machine and it runs" is a measurement, not a promise. The install-side activation step was exercised against a fixture profile too: it backs the original manifest up, appends at the end, keeps the other bundles' relative order, skips on a second run, and **refuses** to write `dsh.profile.bundles` when the package is not actually present in the profile (that "listed but not installed" state is what the host otherwise skips silently).

**Not executed by this repository's automation** (they stop the host, need administrator rights, or need a live instance; the logic was ported line by line and the decision paths were not changed):

| Not verified | Why it was not run | How to check it once yourself |
|---|---|---|
| A full restart (the default action) | It kills the current host and interrupts running sessions | When an interruption is acceptable: `dsh-restart-win -DryRun` to confirm the plan, then one real restart |
| `-Stop` against a live instance | Same | Pick an idle window; `-DryRun` first |
| `-RegisterTask` / `-UnregisterTask` | Writes a system scheduled task, may need administrator rights | `dsh-restart-win -RegisterTask`, then check `schtasks /Query /TN "DSH Restart"` |
| `-ViaTask` dispatch | Depends on the previous row | After registering, run `-ViaTask` and read the task's last result |
| `-TryCtrlC` | Needs an interactive host console; off by default | Only enable it when you know the consequences |
| `-ForceUnverified` | Its semantics *are* accepting the risk | Not recommended as routine use |

So treat "not verified" as "not tried", not as "broken" — but do not make your first real restart happen during a critical window.

---

## 15. Development and tests

```powershell
npm test                                  # node --check + unit / contract tests
node test/parity.mjs                      # asserts every docs/parity-matrix.md row has an implementation and evidence
pwsh -NoProfile -File scripts\check-encoding.ps1
powershell.exe -NoProfile -File scripts\check-encoding.ps1
```

Encoding rules (both engines must parse the same file):

- `.ps1` must be **UTF-8 with BOM + LF**. Without the BOM, Windows PowerShell 5.1 parses a script containing Chinese as the local code page and reports dozens of syntax errors.
- `scripts/dsh-restart.task.xml` must be **UTF-16LE with BOM** (`schtasks` requires it).
- The `.cmd` shim must be **pure ASCII + CRLF** (`cmd.exe` reads it with the OEM code page).

Repository layout:

```
lib/index.js              plugin entry: normalize config → resolve tools → register / dispose
lib/config.js             config and call-argument normalization, whitelist validation (pure, fail-closed)
lib/paths.js              pwsh / engine script / dshHome / stateDir / runs directory resolution
lib/runner.js             argv builder, foreground runs, detached runs, run-record I/O
lib/tools.js              the four tool definitions (parameters, output schema, render, execute)
lib/delayed-spawn.mjs     detached launcher: wait restartDelayMs, then run the engine to completion
bin/dsh-restart-win.mjs   CLI: forwards arguments to the engine
scripts/dsh-restart.ps1   the engine (single source of executable truth)
scripts/dsh-restart.task.xml  scheduled-task template (placeholder form)
scripts/check-encoding.ps1    encoding / newline / dual-engine parser check
install.ps1               add to profile + write the PATH shim
test/selftest.mjs         unit and contract tests
docs/parity-matrix.md     capability matrix (source position, target, verification per row)
docs/migration.md         switching from the old engine and rolling back
```

CI (`.github/workflows/ci.yml`): Ubuntu runs the Node tests and `node --check`; Windows runs the dual-engine `check-encoding`, `Parser::ParseFile` over every `.ps1`, `npm test` and `test/parity.mjs`.

---

## 16. Uninstall and rollback

```powershell
# 1. remove the plugin from the profile (tools disappear on the next host start)
#    installed from GitHub, the dependency name is still the package name
dsh plugin --profile web remove @brainzombie/dsh-restart-win

# 2. also delete "@brainzombie/dsh-restart-win" from dsh.profile.bundles
#    step 1 alone leaves the host printing skipping profile bundle on every start

# 3. delete the PATH shim (optional)
Remove-Item "$env:LOCALAPPDATA\dsh-restart\bin\dsh-restart-win.cmd"

# 4. delete the scheduled task (only if you registered it)
dsh-restart-win -UnregisterTask
```

The state directory is **not** deleted by default: the logs, launch record and history under `%LOCALAPPDATA%\dsh-restart` are assets — deleting them throws away resume and troubleshooting evidence. Remove the whole directory only when you are sure.

Rolling back to the old engine: [docs/migration.md](https://github.com/BrainZombie/dsh-restart-win/blob/main/docs/migration.md) has the full sequence (freeze the old directory as an archive → let the plugin take over → switch back when needed) and a line-by-line table from old commands to the new tools and CLI.

---

## 17. License

MIT, copyright BrainZombie. See [LICENSE](LICENSE).
