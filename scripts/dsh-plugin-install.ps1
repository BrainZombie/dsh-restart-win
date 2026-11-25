#Requires -Version 7.0
<#
.SYNOPSIS
  dsh-restart-win 的插件安装通道：装一个插件而不把宿主弄坏。
  名字就叫安装，因为它主要干的就是安装/升级/移除；修复（重建共享投影、查遮蔽）是其中的单项开关。

.DESCRIPTION
  为什么需要它（2026-11 本机实测过三次同族事故）：
    * 运行中 `pnpm add` / `dsh plugin add` 会整棵树重建（prune + relink），宿主正握着里面的路径，
      重写到一半就以 ENOENT 整个进程退出；
    * pnpm 每次 install 都把 `<DSH_HOME>\profiles\node_modules` 当 extraneous 清掉 —— 那是桌面宿主
      解析 `@deepseek-ai/*` 的**共享投影**，清掉后 App 连基础包都 import 不到，直接打不开；
    * 第三方插件把 `@deepseek-ai/*` 当普通依赖提升进 profile，**遮蔽** App 自带的同名包，
      settings 服务永远不注册，界面只剩「Web RPC failed」。

  固定顺序（每一步都可单独跑，也可整条链跑）：
    闸门（会话空窗）→ 快照 → 停机 → pnpm add → 落盘检查 → 查遮蔽 → 拉起 → 健康校验
    任一步失败即回滚快照并拉起，把 Profile 拉回原状。

  所有路径都在运行时解析（`dsh-restart-win -Status -Json` 给出 exe / profile / node / pnpm），
  不接受任何一条写死的安装路径；解析失败就明确报错，不猜。

.EXAMPLE
  .\dsh-plugin-install.ps1 -CensusOnly
.EXAMPLE
  .\dsh-plugin-install.ps1 -Spec '@scope/some-plugin@1.2.3' -WhatIfPlan
.EXAMPLE
  .\dsh-plugin-install.ps1 -Spec '@scope/some-plugin@1.2.3' -Confirm -Detach
.EXAMPLE
  .\dsh-plugin-install.ps1 -RepairScope -Confirm      # 只重建共享投影
.EXAMPLE
  .\dsh-plugin-install.ps1 -CheckShadowed             # 只查遮蔽
.EXAMPLE
  .\dsh-plugin-install.ps1 -Spec './x.tgz' -OnDemand -Confirm   # 宿主由 agent 先停好，装完不拉起
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
  # 要装的 spec：npm 名 / 带版本 / github: / 本地目录 / link: 路径
  [Parameter(ParameterSetName = 'Install')]
  [string]$Spec = '',

  # 只做一件修复事（与 -Spec 互斥）
  [Parameter(ParameterSetName = 'Repair')]
  [Alias('RepairSharedScope')]
  [switch]$RepairScope,
  [Parameter(ParameterSetName = 'Repair')]
  [switch]$CheckShadowed,

  # 会话空窗闸门
  [string]$SessionId = $(if ($env:DSH_SESSION_ID) { $env:DSH_SESSION_ID } else { '' }),
  [int]$QuietSec = 20,
  [int]$WaitQuietSec = 180,
  [switch]$Force,

  # 宿主由调用方（agent 的 install_plugin 工具）负责停机与拉起：
  #   - 不做会话空窗闸门（调用方已停宿主，不存在「会话还在跑」）；
  #   - 不再 & engine -Stop / -Start（宿主要已经停了，-Stop 会失败退出）；
  #   - 不写续跑通知（`-Detach` 默认要写，这里由调用方决定）。
  # 健康校验仍照做：只读端口探测，宿主没起来就报 unhealthy，不当成功。
  [Parameter(ParameterSetName = 'Install')]
  [switch]$OnDemand,

  # 动作
  [switch]$CensusOnly,
  [switch]$Confirm,
  [switch]$Detach,
  [switch]$WhatIfPlan,

  # 判定与修复
  [int]$HealthSec = 30,
  [switch]$Bundle,
  [switch]$SkipHealth,

  # 覆盖自动解析（一般不需要）
  [string]$Profile = '',
  [string]$DshHome = '',
  [string]$NodeExe = '',
  [string]$PnpmMjs = '',
  # pnpm 单次运行的上限。宿主已经停了，pnpm 卡住就等于整台机器一直关着，所以必须有上限：
  # 2026-11-25 实测 lockfile 17:50:38 就写完了，进程到 18:06 仍 0% CPU 挂着不退。
  [int]$PnpmTimeoutSec = 600,
  [string]$StateDir = '',
  [string]$Engine = '',

  [string]$Reason = '',
  [string]$TaskName = '',
  # 机器可读报告落盘（UTF-8，无 BOM）：调用方不用去解析控制台输出
  [string]$Report = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# ---------------------------------------------------------------- 解析（不写死任何安装路径）

function Get-Field {
  # StrictMode 2.0 下访问不存在的属性会抛异常；读引擎 JSON 一律走这里。
  param($Object, [string]$Name, $Default = $null)
  if ($null -eq $Object) { return $Default }
  $prop = $Object.PSObject.Properties[$Name]
  if ($prop -and $null -ne $prop.Value) { return $prop.Value }
  return $Default
}

function Invoke-EngineJson {
  # 引擎的机器接口：stdout 是单个 JSON（契约 §3.3），stderr 是给人看的诊断。
  param([string[]]$EngineArgs)
  $pwshExe = (Get-Process -Id $PID).Path
  $tmp = Join-Path $env:TEMP ('dsh-plugin-install-status-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    $line = (@('-NoProfile', '-NonInteractive', '-File', ('"' + $script:Engine + '"'), '-Json') +
      @($EngineArgs | ForEach-Object { '"' + $_ + '"' }) +
      @('-ResultFile', ('"' + $tmp + '"'))) -join ' '
    Write-Verbose ('invoke: ' + $pwshExe + ' ' + $line)
    # 不用 `& $pwsh --flag` 直接拼数组：PowerShell 会把 -Json/-Status 当成**本进程**的参数绑定
    # （参数名撞车时直接绑错或报错），必须交给一个独立的命令行。
    $proc = Start-Process -FilePath $pwshExe -ArgumentList $line -PassThru -WindowStyle Hidden -Wait
    $lost = -not (Test-Path -LiteralPath $tmp)
    if ($lost) { $script:LastProbe = ('exit=' + $proc.ExitCode + ' file=' + $tmp + ' line=' + $line) ; return $null }
    $raw = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
    if (-not $raw) { $script:LastProbe = ('empty=' + $tmp); return $null }
    return ($raw | ConvertFrom-Json)
  }
  catch { return $null }
  finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
}

function Resolve-Engine {
  <#
    只要**引擎脚本**（.ps1），不要 PATH 上的 CLI 垫片：垫片是 .cmd，拿它当 -File 参数交给 pwsh
    会得到 exit=64（"启动参数不合法"）。搜索顺序：环境变量 → 本包 scripts\ → PATH 上垫片旁
    （%LOCALAPPDATA%\dsh-restart\bin\ 下的引擎副本）。
  #>
  $envEngine = [string]$env:DSH_RESTART_ENGINE
  if ($envEngine -and (Test-Path -LiteralPath $envEngine)) { return $envEngine }
  $near = Join-Path $PSScriptRoot 'dsh-restart.ps1'
  if (Test-Path -LiteralPath $near) { return $near }
  $shim = Get-Command dsh-restart-win -ErrorAction SilentlyContinue
  if ($null -ne $shim -and $shim.Source) {
    $beside = Join-Path (Split-Path $shim.Source -Parent) 'dsh-restart.ps1'
    if (Test-Path -LiteralPath $beside) { return $beside }
  }
  throw '找不到引擎脚本 dsh-restart.ps1：用 -Engine 指定，或把它放在本脚本同级目录'
}

function Get-DshFacts {
  <#
    一次 -Status -Json 拿到宿主形态、安装根、profile、pnpm 与 node。
    dsh-restart-win 的 desktop 分支会实测端口、并从运行中的宿主 / 启动档案推导安装位置，
    所以「这台机器上 dsh 装在哪」以它为准 —— 本脚本不自己再写一套推导。
  #>
  $probeArgs = @('-Status')
  if ($Profile) { $probeArgs += @('-Profile', $Profile) }
  if ($DshHome) { $probeArgs += @('-DshHome', $DshHome) }
  $st = Invoke-EngineJson -EngineArgs $probeArgs
  if (-not $st) { throw ('无法从 dsh-restart-win -Status -Json 取得机器事实（引擎不可用或输出不可解析）：' + [string]$script:LastProbe) }
  # 富对象在信封的 status 键下（契约 §3.3）；直接调用方若只拿到扁平结构也能用。
  $rich = $st
  if ($st.PSObject.Properties['status'] -and $st.status) { $rich = $st.status }
  $probeProfile = [string](Get-Field $rich 'profile' '')
  $probeHome = [string](Get-Field $rich 'dshHome' '')
  $facts = [ordered]@{
    hostKind     = [string](Get-Field $rich 'hostKind' '')
    profile      = $(if ($Profile) { $Profile } elseif ($probeProfile) { $probeProfile } else { 'desktop' })
    dshHome      = $(if ($DshHome) { $DshHome } elseif ($probeHome) { $probeHome } else { Join-Path $env:USERPROFILE '.dsh' })
    appRoot      = ''
    pnpm         = ''
    nodeExe      = ''
    nodeBin      = ''
    resolvedPort = (Get-Field $rich 'resolvedPort' 0)
    desktopApp   = [string](Get-Field $rich 'desktopApp' '')
    runtimeDir   = [string](Get-Field $rich 'runtimeDir' '')
    nodeFromHost = [string](Get-Field $rich 'nodeExe' '')
    pnpmFromHost = [string](Get-Field $rich 'pnpm' '')
  }
  $inst = $null
  $instances = @(Get-Field $rich 'instances' @())
  if ($instances.Count -gt 0) { $inst = $instances[0] }
  if ($inst) {
    if ($inst.PSObject.Properties['appRoot'] -and $inst.appRoot) { $facts.appRoot = [string]$inst.appRoot }
    if ($inst.PSObject.Properties['pnpm'] -and $inst.pnpm) { $facts.pnpm = [string]$inst.pnpm }
    if ($inst.PSObject.Properties['nodeBin'] -and $inst.nodeBin) { $facts.nodeBin = [string]$inst.nodeBin }
  }
  # 宿主没在跑时 instances 为空：从 -Status 给出的 desktopApp / 解析到的 exe 推导安装根
  if (-not $facts.appRoot -and $facts.desktopApp) { $facts.appRoot = Split-Path -Path $facts.desktopApp -Parent }
  # 优先用引擎给的「实际存在的那一个」：官方布局在 resources\runtime 下，解包后的桥把 pnpm
  # 放到 resources\app\runtime 下，两个都试过再报错（2026-11-22 本机实测：直接拼官方路径会失败）。
  $facts.pnpm = $facts.pnpmFromHost
  if (-not $facts.pnpm) { $facts.pnpm = [string](Get-Field $rich 'pnpmResolved' '') }
  if (-not $facts.pnpm -and $facts.appRoot) {
    $facts.pnpm = Join-Path $facts.appRoot 'resources\runtime\primary-runtime\dependencies\pnpm\bin\pnpm.mjs'
  }
  $facts.nodeExe = $facts.nodeFromHost
  if ($NodeExe) { $facts.nodeExe = $NodeExe }
  if (-not $facts.nodeExe -and $facts.nodeBin) {
    $cand = Join-Path $facts.nodeBin 'node.exe'
    if (Test-Path -LiteralPath $cand) { $facts.nodeExe = $cand }
  }
  if (-not $facts.nodeExe) {
    $facts.nodeExe = [string](Get-Command node -ErrorAction SilentlyContinue).Source
  }
  if (-not $facts.nodeExe) { throw '找不到 node.exe：宿主未运行且 PATH 上没有 node；用 -NodeExe 指定' }
  if (-not (Test-Path -LiteralPath $facts.nodeExe)) { throw ('node.exe 不可用：' + $facts.nodeExe) }
  if ($PnpmMjs) { $facts.pnpm = $PnpmMjs }
  if (-not $facts.pnpm -or -not (Test-Path -LiteralPath $facts.pnpm)) {
    throw ('找不到 pnpm.mjs：' + $(if ($facts.pnpm) { $facts.pnpm } else { '(未解析)' }) + '；用 -PnpmMjs 指定')
  }
  $facts.profileDir = Join-Path $facts.dshHome ('profiles\' + $facts.profile)
  return [pscustomobject]$facts
}

$script:Engine = if ($Engine) { $Engine } else { Resolve-Engine }
if (-not (Test-Path -LiteralPath $script:Engine)) { throw ('引擎脚本不存在：' + $script:Engine) }
$Facts = [pscustomobject](Get-DshFacts)
$profileDir = $Facts.profileDir
$dshHome = $Facts.dshHome
$nodeExe = $Facts.nodeExe
$pnpmMjs = $Facts.pnpm
$stateDir = if ($StateDir) { $StateDir } elseif ($env:DSH_RESTART_HOME) { $env:DSH_RESTART_HOME } else { Join-Path $env:LOCALAPPDATA 'dsh-restart' }
$logPath = Join-Path $stateDir "dsh-plugin-install-$($script:Stamp).log"
# -Report 是调用方（install_plugin / 自动化）指定的结果路径：它拿不到子进程的 stamp，
# 只能按这个路径去读。默认名只在没人指定时用。
$resultPath = if ($Report) { $Report } else { Join-Path $stateDir "dsh-plugin-install-$($script:Stamp).json" }
$snapDir = Join-Path $stateDir "dsh-plugin-install-$($script:Stamp).snapshot"
$noticePath = Join-Path $dshHome '.smart-restart\pending-notice.json'

if (-not $Reason) { $Reason = if ($Spec) { "installed $Spec" } else { 'dsh-plugin-install' } }

# 控制台编码：本机是中文 Windows，宿主/终端是 UTF-8，而控制台默认 OEM 代码页（GBK），
# 中文会以乱码落到日志里；-Report 再把机器可读结果写成 UTF-8 文件。
try {
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch { }

function Get-Fact {
  # 机器事实对象的取值器：缺字段时给默认值，而不是在 StrictMode 下抛异常。
  param([string]$Name, $Default = '')
  return [string](Get-Field $Facts $Name $Default)
}

function Write-Log {
  param([string]$Message)
  $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
  if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
  Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
  Write-Host $line
}

function Set-MachineConfig {
  <#
    把这份机器事实落盘到 <StateDir>\machine.json。App 装在非默认目录、又正好停着时，
    引擎靠它才能找到 exe（否则只能靠用户 -Record 或登记处反查）。写失败不影响本次流程。
  #>
  param($Facts)
  try {
    if (-not $Facts.desktopApp -or -not (Test-Path -LiteralPath $Facts.desktopApp)) { return }
    $payload = [ordered]@{
      version     = 1
      writtenAt   = (Get-Date).ToString('o')
      hostKind    = [string]$Facts.hostKind
      profile     = [string]$Facts.profile
      dshHome     = [string]$Facts.dshHome
      appRoot     = [string]$Facts.appRoot
      desktopApp  = [string]$Facts.desktopApp
      desktopAppSource = 'dsh-repair'
      runtimeDir  = [string]$Facts.runtimeDir
      pnpm        = [string]$Facts.pnpm
      nodeExe     = [string]$Facts.nodeExe
    }
    $path = Join-Path $stateDir 'machine.json'
    [System.IO.File]::WriteAllText($path, (($payload | ConvertTo-Json -Depth 4) + "`n"), [System.Text.UTF8Encoding]::new($false))
  } catch { }
}

function Get-SpecPackageName {
  param([string]$Value)
  if ($Value -match '^(link:|file:)') {
    $path = $Value -replace '^(link:|file:)', ''
    $pj = Join-Path $path 'package.json'
    if (Test-Path -LiteralPath $pj) {
      try { return (Get-Content -LiteralPath $pj -Raw | ConvertFrom-Json).name } catch { }
    }
    return $null
  }
  # 裸本地目录（C:\tools\foo、.\foo）：按它的 package.json.name 解析。
  # 直接把路径当包名会让落盘检查永远找不到目录（实测：pnpm 装出 @local/some-plugin，
  # 检查器却拿本地目录名去 node_modules 里找）。
  if ([System.IO.Path]::IsPathRooted($Value) -or $Value -match '^\.{1,2}[\\/]') {
    if (Test-Path -LiteralPath $Value -PathType Container) {
      $pj = Join-Path $Value 'package.json'
      if (Test-Path -LiteralPath $pj) {
        try { return (Get-Content -LiteralPath $pj -Raw | ConvertFrom-Json).name } catch { }
      }
    }
    return $null
  }
  if ($Value -match '^(github:|git\+|https?:)') { return $null }
  if ($Value.StartsWith('@')) {
    $second = $Value.IndexOf('@', 1)
    if ($second -gt 0) { return $Value.Substring(0, $second) }
    return $Value
  }
  $at = $Value.IndexOf('@')
  if ($at -gt 0) { return $Value.Substring(0, $at) }
  return $Value
}

function Set-BundleEntry([string]$Pkg) {
  # 把包名挂进 dsh.profile.bundles（唯一激活开关）。改前备份到 profile 之外，改后回读断言。
  if (-not $Pkg) { return 'skipped-no-name' }
  $pjPath = Join-Path $profileDir 'package.json'
  if (-not (Test-Path -LiteralPath $pjPath)) { return 'no-profile-package-json' }
  $raw = Get-Content -LiteralPath $pjPath -Raw -Encoding UTF8
  $json = $raw | ConvertFrom-Json
  $bundles = @($json.dsh.profile.bundles)
  if ($bundles -contains $Pkg) { return 'already' }

  $backupRoot = Join-Path $env:USERPROFILE ('.dsh\profile-backups\' + $Facts.profile + '-' + $script:Stamp)
  New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
  Copy-Item -LiteralPath $pjPath -Destination (Join-Path $backupRoot 'package.json') -Force

  $m = [regex]::Match($raw, '"bundles"\s*:\s*\[')
  if (-not $m.Success) { return 'no-array' }
  $at = $m.Index + $m.Length
  $next = $raw.Substring(0, $at) + "`n      `"$Pkg`"," + $raw.Substring($at)

  $ok = $false
  try {
    $check = $next | ConvertFrom-Json
    $after = @($check.dsh.profile.bundles)
    $ok = ($after -contains $Pkg) -and
          ($after.Count -eq $bundles.Count + 1) -and
          ($check.name -eq $json.name) -and
          (@($check.dependencies.PSObject.Properties).Count -eq @($json.dependencies.PSObject.Properties).Count)
  }
  catch { $ok = $false }

  if (-not $ok) { return 'verify-failed' }
  [System.IO.File]::WriteAllText($pjPath, $next, [System.Text.UTF8Encoding]::new($false))
  return 'added'
}

<#
  会话空窗闸门。
  会话库是 <DshHome>\sessions\<workspace>\<sessionId>\session.v4.jsonl.zstd，
  正文是 zstd 压缩的，脚本不去解压：一次真实回合里这个文件会边跑边写，
  所以「mtime 安静 N 秒」足以判定该会话不在干活。
  局限：一个回合卡在长工具调用里、且工具不产生任何写入时，会被误判为空闲；
        所以闸门之外还有宿主健康校验与快照回滚兜底。
#>
function Get-SessionCensus {
  $root = Join-Path $dshHome 'sessions'
  $now = Get-Date
  $rows = [System.Collections.Generic.List[object]]::new()
  if (-not (Test-Path -LiteralPath $root)) { return $rows }
  $files = Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'session*.jsonl*' -ErrorAction SilentlyContinue
  foreach ($f in $files) {
    $age = ($now - $f.LastWriteTime).TotalSeconds
    if ($age -gt 3600) { continue }   # 一小时没动的不参与判定
    $id = Split-Path $f.DirectoryName -Leaf
    $rows.Add([pscustomobject]@{
        sessionId = $id
        workspace = Split-Path (Split-Path $f.DirectoryName -Parent) -Leaf
        ageSec    = [math]::Round($age, 1)
        busy      = ($age -lt $QuietSec)
        self      = ($SessionId -and ($id -eq $SessionId -or $id -eq "session-$SessionId"))
      })
  }
  return ($rows | Sort-Object ageSec)
}

function Show-Census {
  param($Rows)
  if (-not $Rows -or @($Rows).Count -eq 0) { Write-Host '  （没有活跃会话）'; return }
  foreach ($r in @($Rows)) {
    $tag = if ($r.self) { '自身' } elseif ($r.busy) { '在跑' } else { '安静' }
    Write-Host ("  {0,-6} {1,7:N1}s  {2}  {3}" -f $tag, $r.ageSec, $r.sessionId, $r.workspace)
  }
}

function Wait-InstallWindow {
  $deadline = (Get-Date).AddSeconds($WaitQuietSec)
  while ($true) {
    $rows = Get-SessionCensus
    $others = @($rows | Where-Object { $_.busy -and -not $_.self })
    if ($others.Count -eq 0) {
      Write-Log "闸门通过：除自身外没有会话在写（quiet=${QuietSec}s）"
      Show-Census $rows
      return $true
    }
    if ((Get-Date) -ge $deadline) {
      Write-Log "闸门超时：仍有 $($others.Count) 个会话在跑（等待 ${WaitQuietSec}s）"
      Show-Census $rows
      return $false
    }
    Write-Log ("闸门等待：{0} 个会话在跑，10s 后重试" -f $others.Count)
    Start-Sleep -Seconds 10
  }
}

function Get-AuthUrlPort {
  # 引擎每次成功拉起都会把新实例的访问地址写进 web-auth-url.txt（字段含 port）。
  # Desktop 实例是动态端口：写死 -Port 会把「已经起来了」误判成「不健康」。
  # 只认本次停机之后写入的那份，避免上个实例的旧文件冒充。
  $authFile = Join-Path $stateDir 'web-auth-url.txt'
  if (-not (Test-Path -LiteralPath $authFile)) { return $null }
  try {
    if ($script:StopTime) {
      if ((Get-Item -LiteralPath $authFile).LastWriteTime -lt $script:StopTime) { return $null }
    }
    $j = Get-Content -LiteralPath $authFile -Raw | ConvertFrom-Json
    if ($j.port) { return [int]$j.port }
  }
  catch { }
  return $null
}

function Get-DshListenPorts {
  # 兜底：找宿主进程自己的监听端口。判据是「可执行文件在安装根下」或进程名像 dsh/DeepSeek，
  # 不依赖某个具体的安装目录名（不同机器可能装在别处）。
  $found = [System.Collections.Generic.List[int]]::new()
  try {
    foreach ($c in (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
      if ($found.Contains([int]$c.LocalPort)) { continue }
      $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
      if (-not $p) { continue }
      $exe = ''
      try { $exe = [string]$p.Path } catch { }
      $underRoot = ($Facts.appRoot -and $exe -and $exe.StartsWith($Facts.appRoot, [System.StringComparison]::OrdinalIgnoreCase))
      if ($underRoot -or $p.ProcessName -like 'dsh*' -or $p.ProcessName -like 'DeepSeek*') {
        $found.Add([int]$c.LocalPort)
      }
    }
  }
  catch { }
  return $found
}

function Test-PortServesDsh([int]$p) {
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$p/" -TimeoutSec 3 -SkipHttpErrorCheck -ErrorAction Stop
    return ($r.StatusCode -in 200, 401, 403)
  }
  catch { return $false }
}

function Test-HostHealthy {
  if ($SkipHealth) { return $true }
  $deadline = (Get-Date).AddSeconds($HealthSec)
  while ((Get-Date) -lt $deadline) {
    $cand = [System.Collections.Generic.List[int]]::new()
    $authPort = Get-AuthUrlPort
    if ($authPort) { $cand.Add($authPort) }
    foreach ($p in (Get-DshListenPorts)) { if (-not $cand.Contains($p)) { $cand.Add($p) } }
    if ($Facts.resolvedPort -and -not $cand.Contains([int]$Facts.resolvedPort)) { $cand.Add([int]$Facts.resolvedPort) }

    foreach ($p in $cand) {
      $listen = $null
      try { $listen = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue } catch { }
      if (-not $listen) { continue }
      if (Test-PortServesDsh $p) {
        $script:HealthyPort = $p
        Write-Log ("健康校验命中端口 {0}（候选 {1}）" -f $p, ($cand -join ','))
        return $true
      }
    }
    Start-Sleep -Seconds 2
  }
  return $false
}

function Restore-Snapshot {
  foreach ($f in @('package.json', 'pnpm-lock.yaml')) {
    $snap = Join-Path $snapDir $f
    if (Test-Path -LiteralPath $snap) { Copy-Item -LiteralPath $snap -Destination (Join-Path $profileDir $f) -Force }
  }
  Push-Location -LiteralPath $profileDir
  try {
    $out = & $nodeExe $pnpmMjs install --prod --frozen-lockfile 2>&1
    foreach ($line in $out) { Write-Log ('  ' + [string]$line) }
    return ($LASTEXITCODE -eq 0)
  }
  finally { Pop-Location }
}

<#
  写续跑通知（停机之前调用）。
  契约：{ sessionId, reason, when(ISO8601 以 Z 结尾), attempts, extra{package,resultPath,logPath} }
  - 键序固定 sessionId → reason → when → attempts → extra；宿主的 waker 按这份契约读。
  - 先写同目录 pending-notice.json.tmp（UTF-8 无 BOM），再 Move-Item -Force 覆盖正式文件：
    waker 永远看不到半截 JSON；失败时清掉 .tmp，不留残渣。
#>
function Write-PendingNoticeSafe {
  if (-not $SessionId) {
    Write-Log '未拿到会话 id，跳过续跑通知'
    return
  }
  $tmpPath = $noticePath + '.tmp'
  try {
    $dir = Split-Path $noticePath -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $noticePkg = if ($pkgName) { $pkgName } elseif ($Spec) { Get-SpecPackageName $Spec } else { $null }
    $payload = [ordered]@{
      sessionId = $SessionId
      reason    = $Reason
      when      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
      attempts  = 0
      extra     = [ordered]@{
        package    = $noticePkg
        resultPath = $resultPath
        logPath    = $logPath
      }
    } | ConvertTo-Json -Compress -Depth 4
    [System.IO.File]::WriteAllText($tmpPath, $payload, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmpPath -Destination $noticePath -Force
    Write-Log "已写续跑通知 $noticePath（attempts=0，停机前写；waker 起来后消费）"
  }
  catch {
    if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue }
    Write-Log ('写续跑通知失败：' + $_.Exception.Message)
  }
}

$pkgName = if ($Spec) { Get-SpecPackageName $Spec } else { $null }

Write-Host ("机器事实：hostKind={0}  profile={1}  home={2}" -f $Facts.hostKind, $Facts.profile, $dshHome)
Write-Host ("  engine={0}" -f $script:Engine)
Write-Host ("  profileDir={0}" -f $profileDir)
Write-Host ("  node={0}" -f $nodeExe)
Write-Host ("  pnpm={0}" -f $pnpmMjs)
if ($Facts.appRoot) { Write-Host ("  appRoot={0}" -f $Facts.appRoot) }

# dsh-config：把探测到的机器事实落盘（引擎的 Resolve-DesktopAppPath 优先读它）。可选、失败不阻塞。
Set-MachineConfig -Facts $Facts

# ---------------------------------------------------------------- 只读/单项模式

if ($CensusOnly) {
  Write-Host "会话库 $(Join-Path $dshHome 'sessions')："
  Show-Census (Get-SessionCensus)
  Write-Host ''
  Write-Host ("判定：quiet=${QuietSec}s，自身 sessionId='" + $(if ($SessionId) { $SessionId } else { '(未指定)' }) + "'")
  if ($Report) {
    $census = @(Get-SessionCensus | ForEach-Object { [ordered]@{ sessionId = $_.sessionId; workspace = $_.workspace; ageSec = $_.ageSec; busy = $_.busy; self = $_.self } })
    (([ordered]@{ mode = 'census'; quietSec = $QuietSec; dshHome = $dshHome; sessions = $census } | ConvertTo-Json -Depth 5) + "`n") |
      Set-Content -LiteralPath $Report -Encoding utf8
    Write-Host ("报告 $Report")
  }
  return
}

if ($RepairScope -or $CheckShadowed) {
  $engineArgs = if ($RepairScope -or $RepairSharedScope) { @('-RepairSharedScope', '-Json') } else { @('-CheckShadowed', '-Json') }
  if ($Confirm) {
    $out = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $script:Engine @engineArgs
    $out | ForEach-Object { Write-Host $_ }
    exit $LASTEXITCODE
  }
  Write-Host '未加 -Confirm，什么都不做。将执行：'
  Write-Host ("  {0} {1}" -f $script:Engine, ($engineArgs -join ' '))
  return
}

if (-not $Spec) { throw '需要 -Spec（或只用 -CensusOnly / -RepairScope / -CheckShadowed）' }

if ($WhatIfPlan) {
  Write-Host '计划（不执行）：'
  Write-Host "  0) 会话空窗闸门：quiet=${QuietSec}s，最多等 ${WaitQuietSec}s（超时中止，什么都不碰）"
  Write-Host "  1) 快照 package.json + pnpm-lock.yaml → $snapDir"
  Write-Host "  1b) 写续跑通知 $noticePath（停机前原子写：sessionId/reason/when/attempts=0/extra{package,resultPath,logPath}）"
  if ($OnDemand) {
    Write-Host '  2) （-OnDemand）跳过：宿主由调用方停好'
  }
  else {
    Write-Host "  2) & '$script:Engine' -Stop -Profile $($Facts.profile)"
  }
  Write-Host "  3) cd '$profileDir'; & '$nodeExe' '$pnpmMjs' add $Spec --prefer-offline"
  Write-Host "  3b) 失败 → 还原快照 + pnpm install --prod --frozen-lockfile"
  Write-Host "  4) 落盘检查 $pkgName（目录 + package.json.version）"
  $scopeArg = if ($RepairScope) { ' + -RepairSharedScope' } else { '' }
  Write-Host ("  5) & '{0}' -CheckShadowed{1}" -f $script:Engine, $scopeArg)
  if ($Bundle) { Write-Host "  5b) 把 $pkgName 挂进 dsh.profile.bundles（校验不过就还原）" }
  if ($OnDemand) { Write-Host '  6) （-OnDemand）跳过拉起，只做健康探测' }
  else { Write-Host "  6) & '$script:Engine' -Start -Profile $($Facts.profile)，然后健康校验（先取 web-auth-url.txt 的 port，退回 -Status 的 resolvedPort，${HealthSec}s）；不健康 → 回滚再起" }
  Write-Host "  7) 写结果 $resultPath"
  if ($Report) {
    (([ordered]@{
        mode = 'plan'; spec = $Spec; package = $pkgName; profile = $Facts.profile; hostKind = $Facts.hostKind
        dshHome = $dshHome; profileDir = $profileDir; engine = $script:Engine; nodeExe = $nodeExe; pnpm = $pnpmMjs
        appRoot = $Facts.appRoot; snapshot = $snapDir; result = $resultPath; log = $logPath
        quietSec = $QuietSec; waitQuietSec = $WaitQuietSec; healthSec = $HealthSec; bundle = [bool]$Bundle
        steps = @('gate', 'snapshot', 'notice', 'stop', 'pnpm-add', 'landed', 'check-shadowed', 'start', 'health')
      } | ConvertTo-Json -Depth 5) + "`n") | Set-Content -LiteralPath $Report -Encoding utf8
    Write-Host ("报告 $Report")
  }
  return
}

if (-not $Confirm) {
  Write-Host '未加 -Confirm，什么都不做。先看：-CensusOnly / -WhatIfPlan'
  return
}

if ($Detach) {
  $idArg = if ($SessionId) { ' -SessionId "{0}"' -f $SessionId } else { '' }
  $bundleArg = if ($Bundle) { ' -Bundle' } else { '' }
  # 宿主侧调用方（install_plugin）拿不到子进程的 stamp，必须把报告路径显式传下去，
  # 否则它只能去 stateDir 里猜最新文件。
  $reportArg = if ($Report) { ' -Report "{0}"' -f $Report } else { '' }
  $outLog = Join-Path $stateDir "dsh-plugin-install-$($script:Stamp).out.log"
  $runner = Join-Path $stateDir "dsh-plugin-install-$($script:Stamp).run.cmd"

  # 用 .cmd 落地再执行，避免 cmd 的嵌套引号解析问题
  $body = @(
    '@echo off',
    ('pwsh -NoProfile -ExecutionPolicy Bypass -File "{0}" -Spec "{1}" -Confirm -Reason "{2}" -Profile "{3}" -HealthSec {4}{5}{6}{8} > "{7}" 2>&1' -f `
      $PSCommandPath, $Spec, $Reason, $Facts.profile, $HealthSec, $idArg, $bundleArg, $outLog, $reportArg)
  ) -join "`r`n"
  [System.IO.File]::WriteAllBytes($runner, (New-Object System.Text.ASCIIEncoding).GetBytes($body + "`r`n"))

  # WMI 创建进程：父进程是 WmiPrvSE，不在宿主进程树里，宿主被停时不会连带杀掉
  $launched = $false
  try {
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
      -Arguments @{ CommandLine = ('cmd.exe /c "{0}"' -f $runner) } -ErrorAction Stop
    if ($r.ReturnValue -eq 0) { $launched = $true }
    else { Write-Host ("WMI 返回 $($r.ReturnValue)，回退计划任务") }
  }
  catch { Write-Host ('WMI 脱离失败（' + $_.Exception.Message + '），回退计划任务') }

  if (-not $launched) {
    if (-not $TaskName) { $TaskName = "DSH Plugin Install $($script:Stamp)" }
    try {
      $pwshExe = (Get-Process -Id $PID).Path
      $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Spec "{1}" -Confirm -Reason "{2}" -TaskName "{3}" -Profile "{4}" -HealthSec {5}{6}{7}{8}' -f `
        $PSCommandPath, $Spec, $Reason, $TaskName, $Facts.profile, $HealthSec, $idArg, $bundleArg, $reportArg
      Register-ScheduledTask -TaskName $TaskName -Action (New-ScheduledTaskAction -Execute $pwshExe -Argument $argLine) `
        -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1)) -Force | Out-Null
      Start-ScheduledTask -TaskName $TaskName
      $launched = $true
      Write-Host "已注册并启动计划任务：$TaskName"
    }
    catch { Write-Host ('计划任务也不可用：' + $_.Exception.Message) }
  }

  if ($launched) {
    Write-Host "已脱离启动（脚本 $runner）"
    if ($Report) { Write-Host "结果 $Report；日志 $outLog" } else { Write-Host "结果 $resultPath；日志 $outLog" }
    Write-Host '宿主会停一次再起来，本轮对话会断 —— 需要先约一次唤醒'
  }
  else {
    Write-Host '两种脱离方式都失败，未执行任何安装动作'
  }
  return
}

# ---------------------------------------------------------------- 正式链路

$steps = [System.Collections.Generic.List[object]]::new()
$pnpmExit = $null
$rollbackOk = $null
$landed = $null
$landedFail = $false
$health = $null
$script:HealthyPort = $null
$script:StopTime = $null
$startedAt = (Get-Date).ToString('o')

try {
  Write-Log "spec = $Spec ／ pkg = $pkgName ／ profile = $($Facts.profile) ／ session = $(if ($SessionId) { $SessionId } else { '(未指定)' })"

  # 0) 闸门（-OnDemand：宿主已由调用方停掉，没有会话可等）
  if ($OnDemand) {
    Write-Log '跳过闸门（-OnDemand：调用方负责停机）'
    $steps.Add([pscustomobject]@{ step = 'gate'; code = 0 })
  }
  elseif (-not $Force) {
    if (-not (Wait-InstallWindow)) {
      Write-Log '闸门未通过，中止（未停机、未改任何文件）'
      $steps.Add([pscustomobject]@{ step = 'gate'; code = 2 })
      $result = [pscustomobject]@{
        spec = $Spec; status = 'aborted'; stage = 'gate'; steps = $steps
        startedAt = $startedAt; finishedAt = (Get-Date).ToString('o'); log = $logPath
      }
      $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultPath -Encoding utf8
      Write-Log "结果 $resultPath"
      exit 2
    }
    $steps.Add([pscustomobject]@{ step = 'gate'; code = 0 })
  }
  else { Write-Log '跳过闸门（-Force）' }

  # 1) 快照
  Write-Log "快照 → $snapDir"
  New-Item -ItemType Directory -Path $snapDir -Force | Out-Null
  foreach ($snapName in @('package.json', 'pnpm-lock.yaml')) {
    $src = Join-Path $profileDir $snapName
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $snapDir $snapName) -Force }
    else { Write-Log "  缺少 $snapName（回滚会跳过它）" }
  }

  # 1b) 续跑通知必须在停机之前写：新宿主起来后由 waker 消费，把本轮会话唤醒。
  #     写在成功之后（旧做法）只会把通知留给下一次无关重启。
  if (-not $OnDemand) { Write-PendingNoticeSafe }

  # 2) 停机（-OnDemand：调用方已经停过，这里不能重复 -Stop）
  if (-not $OnDemand) {
    Write-Log '停止宿主'
    & $script:Engine -Stop -Profile $Facts.profile
    $script:StopTime = Get-Date
    $steps.Add([pscustomobject]@{ step = 'stop'; code = $LASTEXITCODE })
  }
  else { $script:StopTime = Get-Date }

  # 3) 安装
  Write-Log 'pnpm add（宿主已停；--prefer-offline 优先吃本地缓存）'
  $pnpmOut = Join-Path $stateDir ("dsh-plugin-install-$($script:Stamp).pnpm.out.log")
  $pnpmErr = Join-Path $stateDir ("dsh-plugin-install-$($script:Stamp).pnpm.err.log")
  $pnpmTimedOut = $false
  Push-Location -LiteralPath $profileDir
  try {
    # 不能用 `& $nodeExe ... 2>&1`：那条路径没有任何上限，pnpm 不退出脚本就永远停在这里，
    # 宿主也永远起不来（finally 里的拉起根本轮不到）。
    $pnpmProc = Start-Process -FilePath $nodeExe `
      -ArgumentList @($pnpmMjs, 'add', $Spec, '--prefer-offline') `
      -WorkingDirectory $profileDir -NoNewWindow -PassThru `
      -RedirectStandardOutput $pnpmOut -RedirectStandardError $pnpmErr
    if ($pnpmProc.WaitForExit([Math]::Max(30, $PnpmTimeoutSec) * 1000)) {
      $pnpmExit = $pnpmProc.ExitCode
    }
    else {
      try { $pnpmProc.Kill($true) } catch { }
      $pnpmTimedOut = $true
      $pnpmExit = 124
      Write-Log ("pnpm 超过 {0}s 未退出，已终止（退出码记 124）" -f $PnpmTimeoutSec)
    }
    foreach ($line in (Get-Content -LiteralPath $pnpmOut -ErrorAction SilentlyContinue)) { Write-Log ('  ' + [string]$line) }
    foreach ($line in (Get-Content -LiteralPath $pnpmErr -ErrorAction SilentlyContinue)) { Write-Log ('  ' + [string]$line) }
  }
  finally { Pop-Location }
  # 超时不等于失败：实测这时包往往已经写好，只是进程没退。先验落盘，写好了就按成功继续，
  # 否则回滚会把一次成功的安装撤掉。
  if ($pnpmTimedOut -and $null -ne $pkgName) {
    $probe = Join-Path $profileDir "node_modules\$pkgName\package.json"
    if (Test-Path -LiteralPath $probe) {
      Write-Log '超时但包已落盘 → 按成功继续（不执行回滚）'
      $pnpmExit = 0
    }
  }
  $steps.Add([pscustomobject]@{ step = 'pnpm-add'; code = $pnpmExit })

  # 4) 失败即回滚
  if ($pnpmExit -ne 0) {
    Write-Log "pnpm 退出码 $pnpmExit —— 还原快照"
    $rollbackOk = Restore-Snapshot
    Write-Log ("回滚 " + $(if ($rollbackOk) { '成功' } else { '未完成（需手动核对 node_modules 与 lockfile）' }))
    $steps.Add([pscustomobject]@{ step = 'rollback'; code = $(if ($rollbackOk) { 0 } else { 1 }) })
  }
  else {
    if ($null -eq $pkgName) { Write-Log 'spec 是 URL/本地路径，跳过落盘检查' }
    else {
      $dirOk = Test-Path -LiteralPath (Join-Path $profileDir "node_modules\$pkgName")
      $verOk = $false
      $pkgJson = Join-Path $profileDir "node_modules\$pkgName\package.json"
      if (Test-Path -LiteralPath $pkgJson) {
        try { $j = Get-Content -LiteralPath $pkgJson -Raw | ConvertFrom-Json; $verOk = [bool]$j.version } catch { }
      }
      $landed = ($dirOk -and $verOk)
      Write-Log ("落盘检查 {0}：目录={1} 版本={2}" -f $pkgName, $dirOk, $(if ($verOk) { '可读' } else { '缺失/不可读' }))
      $steps.Add([pscustomobject]@{ step = 'landed'; code = $(if ($landed) { 0 } else { 1 }) })

      if (-not $landed) {
        Write-Log "落盘检查失败：$pkgName 不在 node_modules（pnpm 实际装出的名字与 spec 不一致）—— 还原快照"
        $rollbackOk = Restore-Snapshot
        Write-Log ("回滚 " + $(if ($rollbackOk) { '成功' } else { '未完成（需手动核对 node_modules 与 lockfile）' }))
        $steps.Add([pscustomobject]@{ step = 'rollback'; code = $(if ($rollbackOk) { 0 } else { 1 }) })
        $landedFail = $true
      }
      elseif ($Bundle) {
        $bundleResult = Set-BundleEntry $pkgName
        Write-Log "bundles 挂载：$bundleResult"
        $steps.Add([pscustomobject]@{ step = 'bundles'; code = $(if ($bundleResult -in @('added', 'already')) { 0 } else { 1 }) })
      }
    }
  }
}
catch {
  Write-Log ('安装阶段异常：' + $_.Exception.Message)
}
finally {
  # 5) 查遮蔽（每次安装后都查：pnpm 很容易把旧版基础包提升进 profile）
  Write-Log '查遮蔽'
  try { & $script:Engine -CheckShadowed -Profile $Facts.profile | Out-Null } catch { Write-Log ('CheckShadowed 失败：' + $_.Exception.Message) }
  if ($RepairScope) {
    Write-Log '重建共享投影'
    try { & $script:Engine -RepairSharedScope -Profile $Facts.profile | Out-Null } catch { Write-Log ('RepairSharedScope 失败：' + $_.Exception.Message) }
  }

  # 6) 拉起 + 健康校验（不健康则回滚再起一次）
  #    -OnDemand：宿主由调用方拉起，这里只读地探一次端口。
  $health = $null
  if (-not $OnDemand) {
    Write-Log '拉起宿主'
    try { & $script:Engine -Start -Profile $Facts.profile | Out-Null } catch { Write-Log ('拉起失败：' + $_.Exception.Message) }
  }
  else { Write-Log '跳过拉起（-OnDemand：调用方负责）' }
  $health = Test-HostHealthy
  $portDesc = if ($script:HealthyPort) { [string]$script:HealthyPort } else { 'auth-url / 进程扫描 / -Status 的 resolvedPort' }
  Write-Log ("健康校验（{0}，{1}s）= {2}" -f $portDesc, $HealthSec, $health)

  if (-not $health -and $pnpmExit -eq 0) {
    Write-Log '拉起后不健康 —— 回滚到快照并重起'
    $rollbackOk = Restore-Snapshot
    if (-not $OnDemand) {
      try { & $script:Engine -Start -Profile $Facts.profile | Out-Null } catch { Write-Log ('二次拉起失败：' + $_.Exception.Message) }
    }
    $health = Test-HostHealthy
    Write-Log ("回滚后健康 = {0}（端口 {1}）" -f $health, $script:HealthyPort)
  }

  if ($pnpmExit -eq 0 -and $health -and -not $landedFail) {
    Write-Log "安装完成：$Spec。启用/配置走 plugin_manager，不必再跑 pnpm。"
  }
  elseif ($landedFail) {
    Write-Log '安装未落盘，已回滚；宿主仍会拉起。'
  }
  elseif ($pnpmExit -ne 0) {
    Write-Log '安装未成功，已尝试回滚；宿主仍会拉起。'
  }

  $status = if ($pnpmExit -eq 0 -and $health -and -not $landedFail) { 'ok' } elseif ($pnpmExit -ne 0 -or $landedFail) { 'failed' } else { 'unhealthy' }
  $result = [pscustomobject]@{
    spec       = $Spec
    package    = $pkgName
    profile    = $Facts.profile
    hostKind   = $Facts.hostKind
    appRoot    = $Facts.appRoot
    onDemand   = [bool]$OnDemand
    sessionId  = $SessionId
    status     = $status
    pnpmExit   = $pnpmExit
    landed     = $landed
    rollbackOk = $rollbackOk
    healthy    = $health
    steps      = $steps
    snapshot   = $snapDir
    startedAt  = $startedAt
    finishedAt = (Get-Date).ToString('o')
    log        = $logPath
  }
  $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultPath -Encoding utf8
  Write-Log "结果 $resultPath"

  if ($TaskName) {
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false } catch { }
  }
}
