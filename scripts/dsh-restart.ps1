<#
.SYNOPSIS
  dsh-restart — 安全重启 Windows 上的 DSH Web 宿主。

.DESCRIPTION
  Windows 特供版。严格遵循「先证明新组合能起来，再停掉旧的」顺序（R1/R2），
  任何预检失败都 fail-closed，绝不先停后试。

  与 Linux 版的平台差异（本机实测，非推演）：
    * Windows 无 SIGTERM 交付语义 → 不依赖停机钩子，改为「停机前由本脚本写
      pending-notice.json」（应用级协作，即文档 §5.2 路径①）。
    * 无 setsid → 执行者脱离改用计划任务 schtasks /Run（P1），兜底 WMI（P2）。
    * Get-CimInstance Win32_Process 在本机沙箱下「拒绝访问」→ 进程发现以
      「端口监听者 → PID」为权威（netstat -ano），进程名做二次校验。

  启动命令怎么来（Windows 读不到别人进程的 cwd/environ，见文档 §7）：
    * 首次使用 `-Record` 记录真实启动命令，落盘 boot-record.json，此后重启原样重放；
    * 没有记录时用 DEFAULT_LAUNCH（本机实测取自启动本实例的 PowerShell 历史）。

  宿主环境注入开关（M-10）：
    * 默认（环境变量 DSH_RESTART_INJECT_HOST_ENV 未设）= 照旧注入
      DSH_UC_PROFILE_NODE_MODULES / NPM_CONFIG_LEGACY_PEER_DEPS，修 dsh-update-checker 的
      两处老毛病；只写**进程级**，绝不写用户级（落到用户级会改掉用户自己终端里的 npm 行为）。
    * 设 DSH_RESTART_INJECT_HOST_ENV=0 = 跳过这两条注入，宿主按自己的默认行为走；
      DSH_HOME 仍显式注入 —— 它决定宿主用哪个 home，不属于可关闭项。

.PARAMETER Action
  (默认) 完整重启   -Status 只读状态   -DryRun 演练不写入
  -Start 仅拉起      -Stop 仅停机

.EXAMPLE
  dsh-restart.cmd -Status
.EXAMPLE
  dsh-restart.cmd                 # 完整安全重启
.EXAMPLE
  dsh-restart.cmd -Record -RecordCommand 'pnpm dsh web --no-open --host 127.0.0.1 --port 3080' -RecordWorkingDirectory '%USERPROFILE%\<repo>'

.PARAMETER ResultFile
  把最终结果 JSON 落盘到该路径：成功、失败、异常路径**都**写（UTF-8 无 BOM）。
  内容与 -Json 打到 stdout 的是同一份对象；供分离执行的一方取回结果。

.PARAMETER NoWait
  分离模式：收尾不停留 —— 跳过收尾处等待新 boot token 的 20s，改为一次非阻塞扫描。
  进程组脱离（不被宿主退出连带清理）由调用方的 detached / 新进程组负责。
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Profile = 'web',
  # 宿主形态：auto = 检测到 DSH Desktop（Electron + dsh-desktop-host 子进程）就按桌面版驱动，
  # 否则保持 dsh web 语义；web / desktop 可显式钉死（desktop 下 -Port 只是期望值，端口实测）。
  [ValidateSet('auto', 'web', 'desktop')]
  [string]$HostKind = 'auto',
  [int]$Port = 3080,
  [string]$BindHost = '127.0.0.1',
  [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),
  # 状态目录固定为 %LOCALAPPDATA%\dsh-restart（日志/审计/启动档案/验证残留都在这里）。
  # 脚本本体在它的 bin\ 子目录下，PATH 上只暴露一个 dsh-restart.cmd shim；
  # 状态目录**刻意不跟随 $PSScriptRoot** —— 单一固定位置比"跟着脚本跑"更可预期，
  # 也让文档与已有日志路径保持稳定。
  [string]$StateDir = $(if ($env:DSH_RESTART_HOME) { $env:DSH_RESTART_HOME } else { Join-Path $env:LOCALAPPDATA 'dsh-restart' }),

  # 时间参数
  [int]$ReadySec        = 240,  # 重启后就绪等待上限（本机 2026-11-23 实测：桌面版从拉起主进程到宿主
                                #   绑上 HTTP 面要 56s，再挂好路由要 136s —— 90 和 150 都会假失败）
  [int]$VerifyReadySec  = 150,  # 深度验证实例就绪等待上限（2026-09-20：75s 偶发假失败，见 Invoke-DeepVerifyWithRetry）
  [int]$GraceSec        = 3,    # 优雅停机宽限（R21：实测 /T 温和路径从未成功，10s 纯浪费）
  [int]$PortFreeSec     = 30,   # 等端口释放上限
  [int]$ProgressSec     = 5,    # 进度行间隔：等待中每 N 秒往 stderr 打一行「阶段 · 已等 · 剩余」
  [int]$WaitIdleSec     = 0,    # >0 则重启前等会话空闲，超时行为写日志（R11）
  [int]$IdleMaxSec      = 300,

  # 动作
  [switch]$Status,
  [switch]$DryRun,
  [switch]$Start,
  [switch]$Stop,          # 只停机（不深度验证、不写续跑通知、不拉起）：跨端口迁移/彻底关停用
  [switch]$Json,
  [switch]$Fast,          # 跳过深度验证；存在运行实例时默认仍拒绝停机（需 -ForceUnverified）
  # 跳过「主进程冒烟」：默认会真起一次 Electron 主进程（临时 userData + 临时 DSH_HOME），
  # 确认它能过启动期校验并拉起宿主，再动生产实例。只有明确知道主进程起不来也照重启时才用。
  [switch]$SkipGuiProbe,
  [switch]$ForceUnverified,
  # 存储预检失败时仍继续（只在明确知道 workspace 域已经 FAILED、准备手工修的时候用）
  [switch]$ForceStorage, # 显式承担「未验证即停机」的风险（与 -Fast 配套，R1 的唯一豁免）
  [switch]$VerifyOnly,    # 只跑「深度验证」配方（隔离 home + 空闲端口真启一次），绝不碰生产实例
  [switch]$Preflight,     # 同上，且显式做「符号链接权限」预检（推荐在任何重启前先跑一次）
  [string]$VerifyTempRoot = '',   # 验证实例临时根目录，缺省用 $env:TEMP

  # 续跑通知（R12）—— 缺省自动取当前会话
  [string]$Session = $(if ($env:DSH_SESSION_ID) { $env:DSH_SESSION_ID } else { '' }),
  [string]$Reason  = 'dsh-restart 安全重启',

  # 启动档案
  [switch]$Record,
  [string]$RecordCommand = '',
  [string]$RecordWorkingDirectory = '',
  # 桌面版可执行文件路径。显式给了就跳过所有探测（机器配置 / 运行中实例 / 启动档案 / 常见位置 /
  # 登记处反查），用于装在非默认目录且 App 停着的场景。
  [string]$DesktopApp = '',

  # 优雅停机（默认关闭：Windows 上仅在同控制台场景才有效，见文档 §5.2 路径②）
  [switch]$TryCtrlC,

  # 脱离执行（P1）：Windows 没有 setsid，用计划任务 /Run 让执行者脱离 DSH 进程树
  [switch]$ViaTask,       # 用户入口：先 schtasks /Run，由任务里的 -ViaTaskInner 真正干活
  [switch]$ViaTaskInner,  # 内部：由计划任务拉起时使用，表示"我已经不在 DSH 树里了"
  [switch]$RegisterTask,  # 注册/更新计划任务 "DSH Restart"
  [switch]$UnregisterTask,
  [string]$TaskName = 'DSH Restart',

  # 内部：验证实例专用
  [switch]$DoNotTouchDshHome,

  # 分离执行支撑（插件/自动化用；人工使用时不必传）
  [string]$ResultFile = '',   # 最终结果 JSON 落盘路径（任何终态都写）
  [switch]$NoWait,            # 收尾不停留：跳过等新 boot token 的 20s，只做一次非阻塞扫描
  [switch]$RepairSharedScope, # 只做一件事：从 app.asar 重建 <DSH_HOME>\profiles\node_modules 并退出
  [switch]$CheckShadowed,     # 只做一件事：移走 profile 里遮蔽基础包的旧版本 @deepseek-ai/* 并退出
  [switch]$CleanupOrphans,    # 只做一件事：回收父进程已退出的残留桌面宿主（不动当前实例）并退出
  [string]$LaunchRecord = ''  # 内部：交接模式下引擎自报 pid（见 lib/delayed-spawn.mjs 的 handoff）
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# 活动台账（activity ledger）：引擎还在「做事」的活证据。
#
# 为什么必须有（2026-11-23 实测）：命令行调用一次重启，机主看到的是空白提示符 + 什么都不发生，
# 持续 14 分钟。原因不是引擎崩了，而是它**正确地**在等深度验证的隔离宿主（预算 150s，最多重试
# 一次），而这段时间 stderr 一行字都没有；进程 CPU 停在 2.7s 不动，`-Status` 也只报一行
# `result=status`。观察者无法区分三种状态：还在跑 / 卡死 / 根本没启动。
#
# 台账做的事：进程活着的时候每推进一个阶段就重写一次带时间戳的文件；进程一死（任何原因，包括
# 被 Force 干掉）就没人再写 —— 于是「文件很旧」本身就等于「没人在跑」。
#   * 只有拿到重启锁的动作才写（-Status 是只读的，不能假装有人在干活）。
#   * 写在拿锁之后、第一个可能耗时的步骤之前，早于任何一次网络/WMI 探测。
#   * 任何写失败都吞掉：台账是诊断设施，不能成为新的失败点。
# ---------------------------------------------------------------------------
function Get-ActivityPath { return (Get-StatePath 'activity.json') }

function Test-ActivityProcessAlive($Rec) {
  <#
    台账里的 pid 还活着吗？—— 不能只看 Get-Process：Windows 会复用 pid，
    一个早该结束的引擎的 pid 可能落在刚启动的另一个进程上。
    判据：进程存在 **且** 它的启动时刻不晚于台账最后一次写入（容差 30s）。
    比台账还新 = 那个 pid 不是写台账的人。2026-11-27 实测：一份 3612s 前就该结束的台账，
    因为 pid 被 python 进程复用，-Status 报「多半是卡住了」，把一次正常的只读查询带偏。
  #>
  if (-not $Rec) { return $false }
  $proc = $null
  try { $proc = Get-Process -Id ([int]$Rec.pid) -ErrorAction Stop } catch { return $false }
  if (-not $proc) { return $false }
  $updated = $null
  try { $updated = [datetime]$Rec.updatedAt } catch { return $true }
  if (-not $updated) { return $true }
  try { if ($proc.StartTime -gt $updated.AddSeconds(30)) { return $false } } catch { return $true }
  return $true
}

function Write-Activity([string]$Step, [string]$Note = '') {
    if (-not $script:ActivityOn) { return }
    # 每一步只写一次会漏掉「一步之内长时间等待」的形状（实测：深度验证一步内部要等 150s 的
    # 隔离宿主，台账在这 150s 里一动不动，看起来和卡死完全一样）。所以按时间节流：
    # 节流窗内同一阶段只更新一次，换个阶段立刻写。
    $now = Get-Date
    if ($script:ActivityLastTick -and $script:ActivityLastStep -eq $Step -and
        ($now - $script:ActivityLastTick).TotalSeconds -lt 2) { return }
    $script:ActivityLastTick = $now
    $script:ActivityLastStep = $Step
    $action = if ($Start) { 'start' } elseif ($Stop) { 'stop' } elseif ($DryRun) { 'dry-run' }
              elseif ($Preflight -or $VerifyOnly) { 'verify' } else { 'restart' }
    $rec = [ordered]@{
        pid        = $PID
        host       = $env:COMPUTERNAME
        version    = $script:VERSION
        action     = $action
        hostKind   = [string]$script:HostKind
        profile    = $Profile
        port       = $Port
        step       = $Step
        note       = $Note
        elapsedSec = [math]::Round($script:Clock.Elapsed.TotalSeconds, 1)
        updatedAt  = (Get-Date).ToString('o')
    }
    try { New-Utf8NoBom (Get-ActivityPath) ($rec | ConvertTo-Json -Compress) } catch { }
}

# 一次动作的总预算（见 Set-ActionBudget）。$null = 不设上限（只读动作）。
function Get-BudgetLeftSec {
    if (-not $script:ActionDeadline) { return $null }
    return [Math]::Max(0, [int](([datetime]$script:ActionDeadline - (Get-Date)).TotalSeconds))
}

# -Json：stdout 是机器接口（契约 §3.3 单个 JSON 对象）—— 这里把三条口子堵死：
#   ① 人类可读诊断一律改走 Write-Diag（stderr），全脚本不再有裸 Write-Host；
#   ② 抑制 PowerShell 自身的 warning 流：两个宿主实测都把 Write-Warning 写到进程
#      stdout（pwsh 打「警告:」、5.1 打「WARNING:」），混进 JSON 会让消费方解析失败；
#   ③ 控制台输出编码固定为 UTF-8 无 BOM：5.1 默认用 OEM 代码页，会把 steps 里的
#      中文 detail 写成 GBK 字节，消费方按 UTF-8 解码即乱码。
if ($Json) {
  $WarningPreference = 'SilentlyContinue'
  try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) }
  catch { [Console]::Error.WriteLine('[dsh-restart] 提示：无法把 stdout 编码设为 UTF-8：' + $_.Exception.Message) }
}

# 本次拉起实例的访问地址（含 token）；由 Wait-NewHostToken（url/rescue 步）或
# Resolve-WebAuthUrl（-Status）填充，供步骤输出与 restart-history.jsonl 复用。
$script:HostUrl = $null

# 拉起子进程前先关掉「标准句柄可继承」标记。
# 为什么必须（2026-11-14 实测）：Start-Process 走 CreateProcess(bInheritHandles=TRUE)，
# 即使显式把子进程的 stdout/stderr 重定向到文件，调用方（本脚本）原来的 stdout 句柄
# 仍然会被**复制**进子进程的句柄表。当本脚本被管道调用（`dsh-restart | tail`）时，
# 子进程（GUI 宿主或 notepad 都一样）会一直攥着管道写端 → 调用方永远等不到 EOF，
# 一次成功的重启表现为「命令挂住」。把三个标准句柄的 HANDLE_FLAG_INHERIT 清掉即可，
# 重定向仍然有效（那是显式传句柄）。失败不致命：退回旧行为。
function Hide-StdHandleInheritance {
  try {
    if (-not ('DshHandleFlags' -as [type])) {
      Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DshHandleFlags {
  [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int n);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetHandleInformation(IntPtr h, uint mask, uint flags);
  public static bool Clear(int n) {
    IntPtr h = GetStdHandle(n);
    if (h == IntPtr.Zero || h == new IntPtr(-1)) return false;
    return SetHandleInformation(h, 1u, 0u);
  }
}
'@ -ErrorAction Stop
    }
    [void][DshHandleFlags]::Clear(-11)   # STD_OUTPUT_HANDLE
    [void][DshHandleFlags]::Clear(-12)   # STD_ERROR_HANDLE
    [void][DshHandleFlags]::Clear(-10)   # STD_INPUT_HANDLE
  } catch {
    [Console]::Error.WriteLine('[dsh-restart] 提示：无法关闭标准句柄继承（管道调用仍可能挂住）：' + $_.Exception.Message)
  }
}
Hide-StdHandleInheritance
# boot token 判据：记下「拉起前」的旧 token 与日志长度，url 步只认变化后的新 token ——
# 上一实例留在日志里的旧 token 绝不能被当成本次新实例的地址。
$script:PrevBootToken = ''
$script:LogOffsetBeforeLaunch = 0

# 防呆：本脚本被「点源」时绝不能执行主流程（实测过：. script.ps1 会让默认参数直接跑重启）
if ($MyInvocation.InvocationName -eq '.') {
  Write-Warning "dsh-restart.ps1 不支持下点源执行（会直接跑主流程）。请用 & 或 -File 调用。"
  return
}

# 版本只有一个源：插件仓库根的 package.json（tarball 里 scripts\ 与 package.json 同级）。
# 读不到（把脚本单独拷走运行）就回落 dev 标识 —— 绝不硬编码一个像发布版的号。
$script:VERSION = '0.0.0-dev'
$versionPkgPath = Join-Path $PSScriptRoot '..\package.json'
if ($PSScriptRoot -and (Test-Path -LiteralPath $versionPkgPath -PathType Leaf)) {
  try {
    $versionPkg = Get-Content -LiteralPath $versionPkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($versionPkg.version) { $script:VERSION = [string]$versionPkg.version }
  } catch {
    [Console]::Error.WriteLine('[dsh-restart] 提示：读取 ' + $versionPkgPath + ' 的 version 失败，版本回落 ' +
      $script:VERSION + '：' + $_.Exception.Message)
  }
}
$script:Result   = 'not-started'
$script:ExitCode = 1
$script:TargetPid = $null
$script:NewPid    = $null
# 已经**真的停过**的旧实例 pid：中止若落在停机之后，catch 会据此走抢救拉起（P3）
$script:StoppedPid = $null
$script:Steps     = New-Object System.Collections.ArrayList
$script:Warn      = New-Object System.Collections.ArrayList
$script:Mutex     = $null
$script:Audit     = New-Object System.Collections.ArrayList
# 机器可读终态（契约 §3.3）：异常原文、耗时基准、按动作附加字段、结果是否已落盘。
$script:ErrorText     = $null
$script:ResultWritten = $false
$script:Extra         = [ordered]@{}
# 分阶段耗时：一次 -Status 里「解析参数/找宿主/探端口/拼信封」各占多少，出问题时不用再猜。
# 记在 $script:Phases 里，由 -Json 信封的 phases 字段输出；读宿主的工具（脚本/repair）不必关心。
$script:Phases        = [ordered]@{}
function Get-PhaseMs {
  # 距开始计的毫秒数。用 Stopwatch 而不是 Get-Date：Get-Date 本机实测每次 ~1.1ms，
  # 打点十几次就是十几毫秒的假开销，而且它会混进 total。
  return [int]$script:Clock.ElapsedMilliseconds
}
function Add-Phase([string]$Name_) {
  <#
    打点：每次记下「距上一个打点」的毫秒数。第一次调用只设基准（不记数）。
    点按标签归并（probe:3082 这种一个端口一个标签）：同名点累加而不是后写覆盖 ——
    同名覆盖会让 total 与明细差出三秒（probe:3082 被后续探针覆盖）。
  #>
  if (-not $script:PhasesOn) { return }
  if (-not $script:PhaseT0) { $script:PhaseT0 = Get-PhaseMs; return }
  $now = Get-PhaseMs
  $ms = [int]($now - $script:PhaseT0)
  if ($script:Phases.Contains($Name_)) { $script:Phases[$Name_] = [int]$script:Phases[$Name_] + $ms }
  else { $script:Phases[$Name_] = $ms }
  $script:PhaseT0 = $now
}
$script:PhaseT0 = $null
$script:Clock = [System.Diagnostics.Stopwatch]::StartNew()
# 分阶段打点是否启用：只在 -Json / -ResultFile（机器接口）时记，人读模式不增加任何开销。
$script:PhasesOn = [bool]($Json -or $ResultFile)
# 活动台账是否启用：只有会拿重启锁的动作才写（-Status / -CheckShadowed 这类只读动作不写）。
$script:ActivityOn = $false
$script:ActivityLastTick = $null
$script:ActivityLastStep = ''
# 进度行的节流时间：与台账分开计（台账 2s 一跳，进度行 5s 一跳，两者互不影响）。
$script:ProgressLastTick = $null
$script:ProgressStageStart = $null
# 还没走完的那个阶段（配合 Add-Step 的「成功即结束」语义记录持续时间）。
$script:StageOpen = $false
$script:StageName = ''
$script:StageStart = $null
# 一次动作的预算（见 Set-ActionBudget）。只读动作保持 $null。
$script:ActionDeadline = $null
$script:ActionBudgetSec = 0
# hostKind 是怎么判出来的（machine.json / boot-record / running / default / explicit）：
# 冷启动判错形态是最贵的一类错误，所以推理来源必须能被 -Status 看见。
$script:HostKindSource = ''
# 进程内复用：一次调用里 netstat 与「全量进程表」各只需要一份（时间戳为 $null = 尚未取过）
$script:NetstatRows = @()
$script:NetstatStamp = $null
$script:ProcIndex = $null
$script:ProcStamp = $null
# 这份索引里是否带 CommandLine（默认的那次 CIM 不取，省 ~240ms）
$script:ProcHasCmd = $false
# 本进程内已经探过的端口 → @{ status; chosen }。-Status 的第二次采样据此跳过「上一轮已确认
# 不是宿主面」的附件端口（省掉一次连接/读超时），也避免同一端口在一轮里被问两次。
$script:ProbedPorts = @{}
# 宿主发现的两级缓存：WMI 查询结果（HostRows）与已校验的宿主行（HostHits）。
# -Status 里 Resolve-HostKind / Resolve-DesktopProfileName / 实例发现都会问「宿主在哪」，
# 一次 130ms 的查询问三遍就是 400ms。等待循环里宿主集会变，那边传 -Refresh。
$script:HostRows = $null
$script:HostHits = $null
# 预热的代价（本机实测，pwsh 7 / 5.1 都一样）：新建第一个 ArrayList 要 ~100ms —— 那是第一次
# 碰 System.Collections 相关程序集/泛型实化的固定开销，不是脚本在做活。这里在计时开始之前
# 就把这几类各走一遍，之后逐个打点才是真实耗时。
# 注意别把 [类型] 直接赋给 $null（类型字面量会落进管道）；泛型名带 [] 时 New-Object 会把它当
# COM 参数解析（实测报「无法转换 ComObject」），用 ::new() 语法。
$null = [pscustomobject]@{ warm = 1 }
$null = New-Object System.Collections.ArrayList
$null = New-Object System.Collections.Specialized.OrderedDictionary
$null = [System.Collections.Generic.Dictionary[string, int]]::new()
$null = (Get-Command netstat -ErrorAction SilentlyContinue | Select-Object -First 1).Source
# WMI 也有冷启动成本（第一次查询 ~270ms，之后 ~110-120ms）。这里在计时之前把 CIM 也热一次：
# 它不属于任何一次调用的成本，留在计时里就是一条假的「host-kind 慢了一倍」。
try { $null = @(Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop) } catch { }
# 预热结束，从这里开始计时（预热不属于任何一次调用的成本）
$script:Clock.Restart()
$script:StartedAt = Get-Date
$script:LogPath       = Join-Path $StateDir 'dsh-restart.log'

# 宿主形态（desktop 分支的全部状态都在这里；web 分支不读这些变量）
$script:HostKindRequested = $HostKind
$script:HostKind          = $HostKind
$script:ConfiguredPort    = $Port
$script:ResolvedPort      = $Port
$script:Desktop           = $null
$script:MainPid           = $null
$script:NewMainPid        = $null
$script:DesktopAppPath    = $null
# 这个路径是从哪推导出来的（resolved / running-instance / boot-record / default-location / registry/shortcut）
$script:DesktopAppPathSource = ''
# Electron 的 userData（崩溃日志固定在 <userData>\logs\crash-*-main.log）。按需探测后缓存。
$script:DesktopUserData = ''
# -Profile 是否由用户显式指定：桌面版下若没指定，profile 从运行中的宿主推导
$script:ProfileExplicit   = $PSBoundParameters.ContainsKey('Profile')

# 启动形状兜底。
# 【实测踩坑记录（2026-09-12，真实事故）】这里曾经写成 `pnpm dsh web ...` + cwd=<仓库根>，
# 结果：那是 DSH 自己的源码 monorepo（280 个 workspace 项目），其 package.json 有脚本
#   `dsh = node --import tsx/esm apps/cli/src/bin.ts`
# 于是 `pnpm dsh` 跑的是**仓库里的 CLI**，先做 workspace 依赖检查并执行 pnpm install；
# install 失败(exit 1) → 宿主根本没机会启动 → 拉起后立即退出（ready-failed:exited）。
# 而真实的线上宿主（实测命令行）是全局包：
#   node.exe %APPDATA%\npm\node_modules\@deepseek-ai\dsh\lib\bin.js web     （cwd = %USERPROFILE%）
# 所以兜底必须用「全局 dsh shim + 家目录」，并且**绝不经过 pnpm**。
$script:DEFAULT_LAUNCH = New-Object System.Collections.Specialized.OrderedDictionary
$script:DEFAULT_LAUNCH['file'] = 'cmd.exe'
# host 固定 127.0.0.1：-BindHost 只影响探针与状态显示，**不**改变宿主实际监听的地址 ——
# 否则「只想探一下通配地址」的 -BindHost 0.0.0.0 会让宿主真的对外监听，是旧版没有的行为变更。
# 端口由 {PORT} 占位符在拉起时替换。
$script:DEFAULT_LAUNCH['args'] = @('/c','dsh web --no-open --host 127.0.0.1 --port {PORT}')
$script:DEFAULT_LAUNCH['cwd']  = $env:USERPROFILE

# ---------------------------------------------------------------- 工具

function Add-Step([string]$name, [string]$detail, [string]$state = 'ok') {
  [void]$script:Steps.Add([ordered]@{ step = $name; state = $state; detail = $detail })
  if ($state -eq 'warn') { [void]$script:Warn.Add("${name}: ${detail}") }
  # 每个阶段都落一次台账：这正是「还在跑」与「卡死」的分界线。落在这里而不是各个调用点，
  # 是为了让漏掉的调用点也能被覆盖（Add-Step 本身就是阶段的唯一出口）。
  Write-Activity $name $detail
  # 进度行只给「成功走完」的阶段追加合计：失败/警告行本身已经是结论，再补一行合计只会更吵。
  if ($state -eq 'ok' -and $script:StageOpen -and $script:StageName -eq $name -and $script:StageStart) {
    $spent = [math]::Round(((Get-Date) - $script:StageStart).TotalSeconds, 1)
    Write-Diag ('  .. ' + $name + ' · 完成 · 用时 ' + $spent + 's')
  }
  $script:StageOpen = $false
  $script:StageName = ''
  $script:StageStart = $null
  if (-not $Json) {
    $mark = switch ($state) { 'ok' { '  ok ' } 'warn' { ' WARN' } 'skip' { ' skip' } default { ' FAIL' } }
    # 人读模式下每行都带「已用秒数」：机主看到的是一条在往前走的进度，而不是一段静默。
    # 以前这里只打内容，30s 的深度验证和「卡死」在屏幕上长得一模一样。
    Write-Diag ("[{0}] {1,-18} {2}" -f $mark.TrimEnd(), $name, $detail)
  }
}

function Write-Audit([string]$level, [string]$message) {
  [void]$script:Audit.Add([ordered]@{ ts = (Get-Date).ToString('o'); level = $level; message = $message })
  if ($level -eq 'error') { Write-DiagWarn $message } elseif ($level -eq 'warn') { Write-DiagWarn $message }
}

function New-Utf8NoBom([string]$Path, [string]$Text) {
  # pending-notice.json 必须无 BOM，否则宿主 JSON.parse 抛错、通知被丢弃
  $dir = Split-Path $Path -Parent
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-NowIso { (Get-Date).ToString('o') }

# ---------------------------------------------------------------- 诊断输出 / 终态信封

function Write-Diag {
  <#
    本脚本**唯一**的诊断输出口：人类模式照旧打到控制台，-Json 模式改打到 stderr。
    stdout 只允许出现一个 JSON 对象（契约 §3.3）—— 任何人类可读文本混进去，消费方的
    ConvertFrom-Json / JSON.parse 都会报 "Additional text encountered"。
    这里用真正的 Write-Host（全脚本其余处的诊断都已改成 Write-Diag；别在此处回改成
    Write-Diag，那会变成自递归）。
  #>
  param(
    [string]$Text = '',
    [string]$ForegroundColor = ''
  )
  if ($Json) { [Console]::Error.WriteLine($Text); return }
  if ($ForegroundColor) { Write-Host $Text -ForegroundColor $ForegroundColor }
  else { Write-Host $Text }
}

function Write-DiagWarn {
  # Write-Warning 在两个宿主上都落到**进程 stdout**（实测：pwsh 打「警告:」、5.1 打
  # 「WARNING:」），-Json 模式下会直接污染 JSON —— 所以这里在机器模式下改走 stderr。
  param([string]$Message)
  if ($Json) { [Console]::Error.WriteLine('WARNING: ' + $Message) } else { Write-Warning $Message }
}

function Get-LastFailDetail {
  <#
    没抛异常但结论是失败（预检拒绝、门禁拦截、taskkill 失败、schtasks 失败…）时，
    信封里的 error 不该是 null —— 消费方不该为了看原因去翻 stderr 或 steps。
    取最后一条 state=fail 的步骤原文；没有就回 $null（保持「无错误」语义）。
  #>
  if ($script:ExitCode -eq 0) { return $null }
  $last = $null
  foreach ($s in @($script:Steps)) {
    if ([string]$s['state'] -eq 'fail') { $last = [string]$s['detail'] }
  }
  return $last
}

function Get-ResultEnvelope {
  <#
    终态信封（契约 §3.3）：14 个字段**必须**全在；按动作附加的字段由 $script:Extra 提供
    （目前只有 status 动作填 status=旧 -Status -Json 的富对象，字段名与层级不变）。
  #>
  $payload = [ordered]@{
    ok         = ($script:ExitCode -eq 0)
    result     = [string]$script:Result
    exitCode   = [int]$script:ExitCode
    version    = [string]$script:VERSION
    steps      = @($script:Steps)
    warnings   = @($script:Warn)
    targetPid  = $script:TargetPid
    newPid     = $script:NewPid
    hostUrl    = $script:HostUrl
    error      = $(if ($script:ErrorText) { [string]$script:ErrorText } else { Get-LastFailDetail })
    durationMs = (Get-PhaseMs)
    stateDir   = [string]$StateDir
    logPath    = [string]$script:LogPath
    # 分阶段耗时（毫秒，距上一个打点）：机器接口里唯一新增的诊断字段。
    # 消费方仍按 14 个必选字段解析，多出来的键不影响既有契约。
    phases     = [ordered]@{}
  }
  if ($script:PhasesOn) {
    $payload['phases']['total'] = (Get-PhaseMs)
    foreach ($k in @($script:Phases.Keys)) { $payload['phases'][$k] = [int]$script:Phases[$k] }
  }
  foreach ($k in @($script:Extra.Keys)) { $payload[$k] = $script:Extra[$k] }
  return $payload
}

function Write-EngineResult {
  <#
    把终态落两份：-ResultFile（任何终态都写；异常路径由主流程 finally 兜底）与 -Json 的
    stdout。两者是**同一份** JSON 文本 —— 分离执行的一方读文件、前台调用方读 stdout，
    不会各看一套。幂等：同一进程只写第一次终态（第一个结论即结论）。
  #>
  if ($script:ResultWritten) { return }
  $script:ResultWritten = $true
  # 变量名刻意不叫 $json：PowerShell 变量名大小写不敏感，$json 与 -Json 的 $Json 是同一个名字，
  # 在函数里赋值会遮蔽脚本级开关，让「人类模式不输出 JSON」的判据永远为真（实测踩到过）。
  $jsonText = $null
  try { $jsonText = (Get-ResultEnvelope | ConvertTo-Json -Depth 8 -Compress) }
  catch {
    # 信封自身序列化失败（外部件里带循环引用之类）——仍然要交出一份合法 JSON：
    # 否则消费方既拿不到结果，也看不出是序列化坏了。
    $msg = [string]$_.Exception.Message
    $msg = ((($msg -replace '\\', '\\') -replace '"', '\"') -replace "`r", ' ') -replace "`n", ' '
    $jsonText = '{"ok":false,"result":"result-serialize-failed","exitCode":1,"version":"' +
                $script:VERSION + '","steps":[],"warnings":[],"targetPid":null,"newPid":null,' +
                '"hostUrl":null,"error":"' + $msg + '","durationMs":0,"stateDir":"","logPath":""}'
  }
  if ($ResultFile) {
    $writeError = $null
    try {
      $dir = Split-Path -Path $ResultFile -Parent
      if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
      # 无 BOM：BOM 会让 JSON.parse / ConvertFrom-Json 直接读失败
      [System.IO.File]::WriteAllText($ResultFile, $jsonText, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
      $writeError = [string]$_.Exception.Message
    }
    if ($writeError) {
      # 不静默，而且不能只写 stderr：分离模式下 stdout 被丢弃，warnings[] 是唯一可观测面。
      # 所以要把它塞进 warnings 并**重算一次**信封 —— 上面的 $jsonText 是在失败之前序列化的，
      # 不重算的话 stdout 里就看不到这条。文件本身不再重试（此时写不进去通常不是瞬时原因），
      # 调用方按「结果文件缺失 = 该次分离运行失败」处理。
      [void]$script:Warn.Add('resultFile: 写 -ResultFile 失败（结果文件缺失，按该次运行失败处理）：' +
        $ResultFile + ' :: ' + $writeError)
      [Console]::Error.WriteLine('[dsh-restart] ERROR: 写 -ResultFile 失败：' + $ResultFile + ' :: ' + $writeError)
      try { $jsonText = (Get-ResultEnvelope | ConvertTo-Json -Depth 8 -Compress) }
      catch { [Console]::Error.WriteLine('[dsh-restart] ERROR: 重算终态 JSON 失败（写入失败这条已写进 stderr）：' + $_.Exception.Message) }
    }
  }
  # 直写 stdout：不经管道，避免被调用方当成返回值收走（诊断已全部走 stderr，此处只有这一行）
  if ($Json) { [Console]::Out.WriteLine($jsonText) }
}

# ---------------------------------------------------------------- 环境块（从注册表重建）

function Get-RegistryEnvLayer([string]$Hive, [string]$SubKey) {
  <#
    读出**一层**注册表环境变量：
      machine 层 = HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment
      user    层 = HKCU\Environment
    REG_EXPAND_SZ 一律取**未展开**原文（RegistryValueOptions.DoNotExpandEnvironmentNames）：
    展开时机由调用方按层决定 —— Windows 是按层构造环境块的，machine 层展开时看不见
    只在 user 层才定义的名字，user 层展开时则能看见 machine 层。
    返回 @{ Values = List(Name, Raw, Kind); Failed = 是否读失败 }。
    读失败只降级为「该层不参与覆盖」，不抛出：拉起前的环境重建不能把一次重启变成中止。
  #>
  $values = New-Object 'System.Collections.Generic.List[object]'
  $failed = $false
  $key = $null
  try {
    if ($Hive -eq 'HKCU') { $root = [Microsoft.Win32.Registry]::CurrentUser }
    else { $root = [Microsoft.Win32.Registry]::LocalMachine }
    $key = $root.OpenSubKey($SubKey)
    if ($null -eq $key) { $failed = $true }
    else {
      foreach ($name in $key.GetValueNames()) {
        if (-not $name) { continue }
        $raw = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $raw) { continue }
        if ($raw -is [string[]]) { $rawText = ($raw -join ';') } else { $rawText = [string]$raw }
        [void]$values.Add([pscustomobject]@{
          Name = $name
          Raw  = $rawText
          Kind = [string]$key.GetValueKind($name)
        })
      }
    }
  } catch {
    $failed = $true
  } finally {
    if ($key) { try { $key.Dispose() } catch { } }
  }
  return [pscustomobject]@{ Values = $values; Failed = $failed }
}

function Expand-EnvValue([string]$Value, $Block) {
  # 单层展开：%NAME% → 块内值；块内没有的名字原样保留（同 ExpandEnvironmentStrings：
  # 不把未知变量清空，也不二次展开 —— 块里的值写入时都已展开过）。
  if (-not $Value) { return $Value }
  if ($Value.IndexOf('%') -lt 0) { return $Value }
  $sb = New-Object System.Text.StringBuilder
  $i = 0
  $n = $Value.Length
  while ($i -lt $n) {
    $ch = $Value[$i]
    if ($ch -eq '%') {
      $end = $Value.IndexOf('%', $i + 1)
      if ($end -gt ($i + 1)) {
        $name = $Value.Substring($i + 1, $end - $i - 1)
        if ($Block.ContainsKey($name)) {
          [void]$sb.Append([string]$Block[$name])
          $i = $end + 1
          continue
        }
      }
      [void]$sb.Append('%')
      $i = $i + 1
      continue
    }
    [void]$sb.Append($ch)
    $i = $i + 1
  }
  return $sb.ToString()
}

function Copy-EnvBlock($Block, $Names) {
  # 复制一份「块 + 名字序」，供某一层的展开快照使用
  $copy = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($name in $Names) { $copy[$name] = $Block[$name] }
  return $copy
}

function Get-RegistryEnvironmentBlock {
  <#
    按 Windows 的构造顺序重建**完整**环境块（纯只读：不写进程环境、不写注册表）：
      ① 继承块作底 —— 当前进程已有的全部变量（含调用者临时注入的目录/变量）；
      ② machine 层覆盖 —— REG_SZ 原样；REG_EXPAND_SZ 用「继承块」这一层的当前值展开，
         因此 machine 变量看不见只在 HKCU 里定义的名字；
      ③ user 层覆盖 —— REG_EXPAND_SZ 用「继承块 + machine 层」展开，因此可引用 machine 变量。
    PATH 单独处理并保持既有语义：machine 在前、user 其次、继承条目兜底，去重保序；
    两层 PATH 各自按自己的类型展开（REG_EXPAND_SZ 同上分层规则）。
    已知边界（与 Windows 原生一致，不是缺陷）：注册表里**已删除**的变量不会从继承块
    消失；已从注册表 PATH 删除的目录若仍被调用者继承，会继续留在 PATH 末尾。
  #>
  $ci = [System.StringComparer]::OrdinalIgnoreCase
  $block = New-Object 'System.Collections.Generic.Dictionary[string,string]' ($ci)
  $names = New-Object 'System.Collections.Generic.List[string]'
  $skipped = 0

  # ① 继承块
  $inherited = @(Get-ChildItem Env: | Sort-Object Name)
  foreach ($entry in $inherited) {
    $name = [string]$entry.Name
    if (-not $name) { continue }
    if ($name -ieq 'Path') { continue }
    $val = [string]$entry.Value
    if ($null -eq $val -or $val.Length -eq 0) { continue }
    if (-not $block.ContainsKey($name)) { [void]$names.Add($name) }
    $block[$name] = $val
  }
  $inheritedCount = $names.Count

  # ② machine 层：先算 PATH（用继承快照展开），再把它放回 machine 层的展开快照
  $machine = Get-RegistryEnvLayer 'HKLM' 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  $machineCount = $machine.Values.Count
  $machineSnap = Copy-EnvBlock $block $names
  $machinePath = ''
  foreach ($item in $machine.Values) {
    if ($item.Name -ieq 'Path') {
      if ($item.Kind -eq 'ExpandString') { $machinePath = Expand-EnvValue $item.Raw $machineSnap }
      else { $machinePath = $item.Raw }
    }
  }
  $machineSnap['Path'] = $machinePath
  foreach ($item in $machine.Values) {
    if ($item.Name -ieq 'Path') { continue }
    if ($item.Kind -eq 'ExpandString') { $val = Expand-EnvValue $item.Raw $machineSnap }
    else { $val = $item.Raw }
    if ($null -eq $val -or $val.Length -eq 0) { $skipped = $skipped + 1; continue }
    if (-not $block.ContainsKey($item.Name)) { [void]$names.Add($item.Name) }
    $block[$item.Name] = $val
  }

  # ③ user 层：用「继承块 + machine 层」展开（user PATH 同理，可引用 machine 变量）
  $user = Get-RegistryEnvLayer 'HKCU' 'Environment'
  $userCount = $user.Values.Count
  $userSnap = Copy-EnvBlock $block $names
  $userSnap['Path'] = $machinePath
  $userPath = ''
  foreach ($item in $user.Values) {
    if ($item.Name -ieq 'Path') {
      if ($item.Kind -eq 'ExpandString') { $userPath = Expand-EnvValue $item.Raw $userSnap }
      else { $userPath = $item.Raw }
    }
  }
  if ($userPath) { $userSnap['Path'] = $machinePath + ';' + $userPath }
  foreach ($item in $user.Values) {
    if ($item.Name -ieq 'Path') { continue }
    if ($item.Kind -eq 'ExpandString') { $val = Expand-EnvValue $item.Raw $userSnap }
    else { $val = $item.Raw }
    if ($null -eq $val -or $val.Length -eq 0) { $skipped = $skipped + 1; continue }
    if (-not $block.ContainsKey($item.Name)) { [void]$names.Add($item.Name) }
    $block[$item.Name] = $val
  }

  # PATH：machine 在前、user 其次、继承条目兜底；裁剪空白、去重保序（沿用原实现语义）
  $parts = New-Object 'System.Collections.Generic.List[string]'
  $sources = @($machinePath, $userPath, [string]$env:PATH)
  foreach ($src in $sources) {
    if (-not $src) { continue }
    foreach ($seg in ($src -split ';')) { if ($seg.Trim()) { [void]$parts.Add($seg.Trim()) } }
  }
  $ordered = New-Object 'System.Collections.Generic.List[string]'
  foreach ($seg in $parts) { if ($ordered -notcontains $seg) { [void]$ordered.Add($seg) } }

  return [pscustomobject]@{
    Block          = $block
    Names          = $names
    PathValue      = ($ordered -join ';')
    PathItems      = $ordered.Count
    TotalCount     = ($names.Count + 1)
    InheritedCount = $inheritedCount
    MachineCount   = $machineCount
    UserCount      = $userCount
    SkippedCount   = $skipped
    MachineFailed  = $machine.Failed
    UserFailed     = $user.Failed
  }
}

function Sync-ProcessEnvironment {
  <#
    拉起宿主前，把本进程环境块重建为「注册表里的最新值」——整套环境，而不只是 PATH。
    为什么需要：Windows 的子进程只继承父进程的环境快照。dsh-restart 常被一个「早于
    setx 改动」打开的终端（或计划任务）唤起，于是宿主拿到过期环境：用户在旧窗口里
    敲不到新装的命令，setx 改的变量也永远到不了新实例。
    取值：继承块作底，machine 覆盖，user 再覆盖（分层与展开时机见 Get-RegistryEnvironmentBlock）；
    PATH 保持原语义（machine 在前、去重、各自按类型展开），继承条目兜底不丢调用者临时目录。
    直接写进程级环境（子进程自然继承）；刻意不用仅 PS7 才有的 Start-Process -Environment，
    以保持与 Windows PowerShell 5.1 的兼容。
  #>
  $plan = Get-RegistryEnvironmentBlock
  foreach ($name in $plan.Names) {
    try { [Environment]::SetEnvironmentVariable($name, $plan.Block[$name], 'Process') } catch { }
  }
  $env:PATH = $plan.PathValue

  # USERNAME / USERDOMAIN 不在注册表里（由登录会话给出），所以上面「注册表为准」的重建
  # 覆盖不到它们：调用者环境里的脏值会原样传进新宿主。实测遇到过 USERNAME 字面为
  # SYSTEM、而真实身份是普通用户的情况 —— 凡是拿 %USERNAME% 拼路径的地方都会指向
  # 一个并不存在的用户目录。这里用真实令牌身份校正。
  $identText = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  $identParts = @($identText -split '\\', 2)
  if ($identParts.Count -eq 2) {
    [Environment]::SetEnvironmentVariable('USERDOMAIN', $identParts[0], 'Process')
    [Environment]::SetEnvironmentVariable('USERNAME', $identParts[1], 'Process')
    $plan.Block['USERDOMAIN'] = $identParts[0]
    $plan.Block['USERNAME'] = $identParts[1]
  }
  return $plan
}

# ---------------------------------------------------------------- 计划任务（P1 脱离）

function Get-TaskXmlPath {
  $p = Join-Path $StateDir 'dsh-restart.task.xml'
  return $p
}

function ConvertTo-XmlText([string]$Text) {
  # XML 文本节点只需要转义 & < >；双引号保留原样，这样生成的 Arguments 与 schtasks
  # 回读的文本逐字一致（SecurityElement.Escape 会把 " 变成 &quot;，虽然合法但制造无谓差异）
  if ($null -eq $Text) { return '' }
  return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function Get-RestartTaskEngine {
  <#
    计划任务用哪个 PowerShell 引擎 —— 与入口 dsh-restart.cmd 保持同一优先级：
      ① pwsh.exe（PowerShell 7）：-ViaTaskInner 要跑深度验证，需要 Start-Process -Environment
         （7.4+）、New-Item -ItemType SymbolicLink、System.Net.Http，5.1 全都没有；
      ② 找不到 pwsh 才退回 powershell.exe（5.1）—— 此时脚本会在用到 PS7 能力前明确报错
         （engine-requires-pwsh），而不是中途抛「找不到参数」。
    任务里写**绝对路径**：任务环境的 PATH 可能不含 pwsh 目录；shim 用 PATH 名是因为它由
    完整用户会话启动 —— 优先级一致，解析方式按各自场景取最稳的。
  #>
  $cmd = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -ne $cmd) {
    return [pscustomobject]@{ Path = [string]$cmd.Source; Kind = 'pwsh' }
  }
  return [pscustomobject]@{ Path = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'); Kind = 'powershell' }
}

function New-RestartTaskXml([string]$EnginePath, [string]$ScriptPath) {
  <#
    生成计划任务 XML（纯函数：与 scripts\dsh-restart.task.xml 模板逐字对照时可直接调用）。
    schtasks 要求文件为 UTF-16LE；落盘由 Save-RestartTaskXml 负责。
  #>
  $userText = ConvertTo-XmlText ($env:USERDOMAIN + '\' + $env:USERNAME)
  $uriText = ConvertTo-XmlText ('\' + $TaskName)
  $cmdText = ConvertTo-XmlText $EnginePath
  $argText = ConvertTo-XmlText ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $ScriptPath +
    '" -ViaTaskInner -Profile ' + $Profile + ' -Port ' + $Port + ' -DshHome "' + $DshHome + '" -StateDir "' + $StateDir + '"')
  $wdText = ConvertTo-XmlText $env:USERPROFILE
  return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>dsh-restart 脱离执行入口：先验证新组合能起来，再安全重启本机 DSH Web 宿主。</Description>
    <URI>$uriText</URI>
  </RegistrationInfo>
  <Triggers />
  <Principals>
    <Principal id="Author">
      <UserId>$userText</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <ExecutionTimeLimit>PT15M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$cmdText</Command>
      <Arguments>$argText</Arguments>
      <WorkingDirectory>$wdText</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

function Save-RestartTaskXml([string]$Path, [string]$Xml) {
  # schtasks 只接受 UTF-16LE（带 BOM）的任务定义文件
  [System.IO.File]::WriteAllText($Path, $Xml, (New-Object System.Text.UnicodeEncoding($false, $true)))
}

function Register-RestartTask {
  <#
    用 schtasks 注册/更新计划任务（-TaskName，默认 'DSH Restart'）。
    为什么需要它：Windows 没有 setsid，而 taskkill /T 会顺着父链把调用者一起杀掉。
    计划任务进程的父是任务计划服务，天然不在 DSH 树里（文档 §5.3 P1）。
    任务定义文件必须 UTF-16LE（schtasks 的要求）。
  #>
  if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
  $engine = Get-RestartTaskEngine
  $ps1 = Join-Path $PSScriptRoot 'dsh-restart.ps1'
  $xml = New-RestartTaskXml -EnginePath $engine.Path -ScriptPath $ps1
  $path = Get-TaskXmlPath
  Save-RestartTaskXml $path $xml
  if ($engine.Kind -eq 'pwsh') {
    Add-Step 'register-task' "计划任务引擎：$($engine.Path)（优先 pwsh，与 dsh-restart.cmd 一致）" 'ok'
  } else {
    Add-Step 'register-task' "计划任务引擎退回 Windows PowerShell 5.1（找不到 pwsh.exe）：-ViaTaskInner 的验证型重启需要 pwsh 7.4+，任务会失败并明确提示。建议先装 PowerShell 7。" 'warn'
  }
  $o = & (Get-SystemTool 'schtasks') /Create /TN $TaskName /XML $path /F 2>&1
  $ok = ($LASTEXITCODE -eq 0)
  Add-Step 'register-task' ("$o" -replace "`r?`n", ' ').Trim() $(if ($ok) { 'ok' } else { 'fail' })
  return $ok
}

function Invoke-ViaTask {
  # 通过计划任务执行 —— 执行者脱离 DSH 进程树；任务里以 -ViaTaskInner 跑真正的重启
  $o = & (Get-SystemTool 'schtasks') /Run /TN $TaskName 2>&1
  $ok = ($LASTEXITCODE -eq 0)
  Add-Step 'via-task' ("schtasks /Run /TN `"$TaskName`" → " + (("$o") -replace "`r?`n", ' ').Trim()) $(if ($ok) { 'ok' } else { 'fail' })
  return $ok
}

function Test-Elevation {
  <#
    提权检测（TokenElevationType：1=Default 未提升 / 2=Full 已提升 / 3=Limited 筛选令牌）。
    为什么需要：Windows 不允许**未提升**进程终止**已提升**进程（Access is denied）。
    本机真实场景：宿主曾从管理员窗口启动 → 之后从普通窗口跑 dsh-restart 必然停在「停不掉」，
    而 taskkill 只回一句 Access is denied，看不出根因。所以这里在动手前就判定并给方案。
  #>
  try {
    if (-not ('DshElev' -as [type])) {
      Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DshElev {
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr GetCurrentProcess();
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr tok, int cls, out int info, int len, out int ret);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  public static int ElevationType() {
    IntPtr tok;
    if (!OpenProcessToken(GetCurrentProcess(), 0x0008, out tok)) return -1;
    int info, ret;
    bool ok = GetTokenInformation(tok, 18, out info, 4, out ret);
    CloseHandle(tok);
    return ok ? info : -1;
  }
  public static bool Elevated() { return ElevationType() == 2; }

  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint acc, bool inh, int pid);

  // 探测「能不能动这个进程」：打开它的令牌失败就说明它比我们更特权（典型是它已提升而我们没有）。
  // 返回 0 = 可查询（可以尝试终止）、1 = Access is denied、2 = 其他失败。
  public static int CanQueryTargetToken(int pid) {
    IntPtr h = OpenProcess(0x1000, false, pid);
    if (h == IntPtr.Zero) return 1;
    IntPtr tok;
    bool ok = OpenProcessToken(h, 0x0008, out tok);
    if (tok != IntPtr.Zero) CloseHandle(tok);
    CloseHandle(h);
    return ok ? 0 : 1;
  }
}
'@ -ErrorAction Stop
    }
    return [pscustomobject]@{ ok = $true; elevated = [DshElev]::Elevated(); type = [DshElev]::ElevationType() }
  } catch {
    return [pscustomobject]@{ ok = $false; elevated = $null; type = -1 }
  }
}

function Get-TaskRegistered {
  [void](schtasks /Query /TN $TaskName 2>&1)
  return ($LASTEXITCODE -eq 0)
}

function Get-Ps7RuntimeStatus {
  <#
    验证型重启需要三个只有 pwsh 7 才具备的能力：
      · Start-Process -Environment —— 隔离 home 的临时验证实例靠它注入 DSH_HOME / DSH_UC_…
        （该参数 7.4+ 才有）；
      · New-Item -ItemType SymbolicLink —— profile 组装；Windows PowerShell 5.1 没有该 ItemType；
      · System.Net.Http —— 就绪探测；5.1 默认未加载（Get-HttpStatusCode 已做 HttpWebRequest 兜底）。
    在 5.1 上这些会在流程中途抛「找不到参数 / 找不到类型」，把一次重启半途炸掉；所以提前判定、
    给出可操作提示，而不是等异常把机器留在停机态。
  #>
  $sp = Get-Command Start-Process -ErrorAction SilentlyContinue
  $hasEnvironment = $false
  if ($sp -and $sp.Parameters) { $hasEnvironment = $sp.Parameters.ContainsKey('Environment') }
  if ($PSVersionTable.PSVersion.Major -ge 7 -and $hasEnvironment) {
    return [pscustomobject]@{ Ok = $true; Reason = ''; Engine = ('PowerShell ' + $PSVersionTable.PSVersion.ToString()) }
  }
  $why = 'Windows PowerShell ' + $PSVersionTable.PSVersion.ToString()
  if ($PSVersionTable.PSVersion.Major -ge 7) {
    $why = 'PowerShell ' + $PSVersionTable.PSVersion.ToString() + '（缺少 Start-Process -Environment，需 7.4+）'
  }
  return [pscustomobject]@{ Ok = $false; Reason = $why; Engine = $why }
}

# ---------------------------------------------------------------- 状态目录 / 终态记录（R21）

function Get-StatePath([string]$Name) { Join-Path $StateDir $Name }

function Get-HostLogName([string]$Which) {
  # 宿主日志按形态分文件（桌面 App 会长期占住自己那份）。命名只在这里定义：
  # 拉起时写入与 -Status 回读必须用同一个名字，否则 web-auth-url 的自愈补写会读空。
  return ('host.{0}.{1}.log' -f $script:HostKind, $Which)
}

function Get-EmptyStdinPath {
  <#
    拉起 GUI/宿主时把 stdin 接到一个空文件。
    为什么必须：Start-Process 默认让子进程继承调用方的 stdin —— 当本脚本被管道调用
    （`dsh-restart | head`、插件 detached 之前的前台探测等）时，子进程会一直攥着管道写端，
    调用方于是永远等不到 EOF，一次成功的重启表现为「命令挂住」。2026-11-14 实测一次。
  #>
  $p = Get-StatePath 'host.stdin'
  if (-not (Test-Path -LiteralPath $p)) {
    try { [System.IO.File]::WriteAllText($p, '') } catch { return $null }
  }
  return $p
}

function Write-Terminal([string]$result, [int]$rc) {
  $script:Result   = $result
  $script:ExitCode = $rc
  $rec = [ordered]@{
    ts         = Get-NowIso
    version    = $script:VERSION
    result     = $result
    rc         = $rc
    profile    = $Profile
    port       = $Port
    target_pid = $script:TargetPid
    new_pid    = $script:NewPid
    url        = $script:HostUrl
    session    = $Session
    reason     = $Reason
    host       = $env:COMPUTERNAME
    host_kind  = [string]$script:HostKind
    main_pid   = $script:MainPid
    new_main_pid = $script:NewMainPid
    configured_port = [int]$script:ConfiguredPort
    resolved_port   = [int]$Port
    user       = (([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -split '\\')[-1]
    steps      = @($script:Steps)
    warnings   = @($script:Warn)
    audit      = @($script:Audit)
  }
  $line = "{0} [dsh-restart] 终态 result={1} rc={2} 旧pid={3} 新pid={4} profile={5} port={6} session={7}" -f `
          (Get-Date -Format o), $result, $rc, $script:TargetPid, $script:NewPid, $Profile, $Port, $Session
  foreach ($p in @((Get-StatePath 'dsh-restart.log'), (Join-Path (Get-StatePath 'fallback') 'dsh-restart.log'))) {
    try {
      $d = Split-Path $p -Parent
      if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
      Add-Content -LiteralPath $p -Value $line -Encoding UTF8
      break
    } catch { continue }
  }
  foreach ($p in @((Get-StatePath 'restart-history.jsonl'), (Join-Path (Get-StatePath 'fallback') 'restart-history.jsonl'))) {
    try {
      $d = Split-Path $p -Parent
      if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
      Add-Content -LiteralPath $p -Value ($rec | ConvertTo-Json -Compress -Depth 8) -Encoding UTF8
      break
    } catch { continue }
  }
  # 注意：本函数**只**落 dsh-restart.log / restart-history.jsonl，绝不向 stdout 写。
  # 以前这里在 -Json 模式下又 echo 一遍 $rec，于是 `-Status -Json` 会输出两个 JSON 文档
  # （状态对象 + 历史记录），严格 ConvertFrom-Json 直接报 "Additional text encountered"。
  # 需要机器可读的终态记录时，读 restart-history.jsonl 的最后一行（每行一个对象）。
  # 终态同时交给 Write-EngineResult（-ResultFile 落盘 + -Json 的 stdout，同一份文本）。
  # 所有退出路径都是「先 Write-Terminal 再 exit」，因此这里是唯一的机器可读出口；
  # 万一某条路径没走到这里就抛了异常，主流程的 finally 还会兜底调一次。
  Write-EngineResult
}

# ---------------------------------------------------------------- 访问地址（boot token 判据 + 持久化）

function Get-WebAuthUrlPath { return (Get-StatePath 'web-auth-url.txt') }

function Get-JsonField($Object, [string]$Name) {
  # StrictMode 2.0 下访问不存在的属性会直接抛异常 → 统一经 PSObject.Properties 取，缺失返回 $null。
  # （持久文件可能是手工/旧格式，字段不全不能把 -Status 打成 fatal。）
  if ($null -eq $Object) { return $null }
  $p = $Object.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

function Get-TokenFromUrl([string]$Url) {
  if (-not $Url) { return '' }
  $m = [regex]::Match($Url, '[?&]token=([^&]+)')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

function Read-FileTailText([string]$Path, [int]$MaxBytes = 65536) {
  <#
    读文本文件的尾部（最多 $MaxBytes 字节，按 UTF-8 解码）。宿主正持有写句柄时必须
    FileShare.ReadWrite 打开（[IO.File]::ReadAllText 会因共享冲突直接抛）。
    为什么要「只读尾部」：token 行只可能在最后几 KB，而日志会长到几十 MB。
  #>
  $fs = $null
  try {
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $len = $fs.Length
    if ($len -le 0) { return '' }
    $start = [long][Math]::Max(0, $len - $MaxBytes)
    [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
    $buf = New-Object 'System.Byte[]' ([int]($len - $start))
    $read = $fs.Read($buf, 0, $buf.Length)
    if ($read -le 0) { return '' }
    return [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
  } catch {
    return ''
  } finally {
    if ($fs) { try { $fs.Dispose() } catch { } }
  }
}

function Get-HostAuthUrlRecord([string]$LogPath) {
  <#
    取宿主 stdout 日志里**最后一条** `dsh web: http://…/?token=…`，返回 @{ Url; Token } 或 $null。
    只读文件尾部（Read-FileTailText，FileShare.ReadWrite）：宿主正持有写句柄，而 token 行只可能
    在最后几 KB —— 全文 Select-String 在本机实测要 1-2s（日志几十 MB）。
  #>
  if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return $null }
  $tailText = Read-FileTailText $LogPath 65536
  if (-not $tailText) { return $null }
  $matches2 = [regex]::Matches($tailText, 'dsh\s+web:\s*(https?://\S+)')
  if ($matches2.Count -eq 0) { return $null }
  # 取最后一条：一次重启可能打印多行，前面的都是旧 boot 的地址
  $url = $matches2[$matches2.Count - 1].Groups[1].Value.TrimEnd('.', ',', ')', '"', "'")
  $tok = Get-TokenFromUrl $url
  if (-not $tok) { return $null }
  return [pscustomobject]@{ Url = $url; Token = $tok }
}

function Read-WebAuthUrlRecord {
  <#
    读持久文件 $StateDir\web-auth-url.txt（JSON）。不存在/损坏 → $null。
    兼容「整份文件只有一行 URL」的手工/旧格式。
  #>
  $p = Get-WebAuthUrlPath
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  $raw = ''
  try { $raw = [string](Get-Content -LiteralPath $p -Raw -Encoding UTF8 -ErrorAction Stop) } catch { return $null }
  if (-not $raw -or -not $raw.Trim()) { return $null }
  $o = $null
  try { $o = $raw | ConvertFrom-Json } catch { $o = $null }
  $urlVal = [string](Get-JsonField $o 'url')
  if ($urlVal) {
    $tok = [string](Get-JsonField $o 'token')
    if (-not $tok) { $tok = Get-TokenFromUrl $urlVal }
    $pidVal = 0
    $pidRaw = Get-JsonField $o 'pid'
    if ($null -ne $pidRaw) { $pidVal = [int]$pidRaw }
    $portVal = 0
    $portRaw = Get-JsonField $o 'port'
    if ($null -ne $portRaw) { $portVal = [int]$portRaw }
    return [pscustomobject]@{
      Url     = $urlVal
      Token   = $tok
      Pid     = $pidVal
      Port    = $portVal
      SavedAt = [string](Get-JsonField $o 'savedAt')
      Source  = [string](Get-JsonField $o 'source')
    }
  }
  $first = ($raw.Trim() -split "`r?`n")[0].Trim()
  if ($first -match '^https?://') {
    return [pscustomobject]@{ Url = $first; Token = (Get-TokenFromUrl $first); Pid = 0; Port = 0; SavedAt = ''; Source = 'raw-line' }
  }
  return $null
}

function Save-WebAuthUrlRecord([string]$Url, [int]$Pid_, [string]$Source) {
  <#
    把「宿主真实打印出来的」地址落盘，供 -Status 与后续步骤读取（不再实时抓日志）。
    只写 token 已由宿主打印的 URL —— 本脚本绝不自己拼一个点不开的地址。
  #>
  if (-not $Url) { return $null }
  $rec = [ordered]@{
    url     = $Url
    token   = (Get-TokenFromUrl $Url)
    pid     = $Pid_
    port    = $Port
    profile = $Profile
    savedAt = (Get-Date).ToString('o')
    source  = $Source
  }
  try { New-Utf8NoBom (Get-WebAuthUrlPath) ($rec | ConvertTo-Json -Compress) } catch { }
  return $rec
}

function Read-WebAuthUrlForPid([int]$Pid_) {
  <#
    读 `web-auth-url.txt` 里**属于指定 pid** 的地址；pid 对不上就返回 $null。
    用途：桌面宿主的 boot token 行不保证出现在被重定向的 stdout 上（它把地址写进
    自己的 `web-auth-url.txt` 才是可靠事实）。这里只做 pid 相等的严格匹配 ——
    旧实例留下的文件绝不能被当成本次新实例的地址。
  #>
  if (-not $Pid_) { return $null }
  $rec = Read-WebAuthUrlRecord
  if ($rec -and [int]$rec.Pid -eq $Pid_ -and $rec.Url) { return [string]$rec.Url }
  return $null
}

function Test-WebAuthUrl([string]$Url, [int]$Port_ = 0) {
  <#
    本机实测：有效 token → 303（重定向到应用页）；缺失/伪造 token → 401。
    2xx/3xx = 有效；401/403 = 无效；0/404（进程未就绪/路由未注册） = 尚未证明。
    走 Get-HttpStatusCodeDetail（原始 TCP）：以前走 .NET 请求栈，一次校验 0.2-2s，
    而 -Status 每次都要为「持久地址」校验一遍。**路径必须带查询串**（token 在 ?token= 里），
    只请求 '/' 会让一个有效 token 被判成失效。
  #>
  if (-not $Url) { return $false }
  $p = $Port_
  $path = '/'
  try {
    $u = [uri]$Url
    if (-not $p -and $u.Port -gt 0) { $p = $u.Port }
    if ($u.PathAndQuery) { $path = $u.PathAndQuery }
  } catch { return $false }
  if (-not $p) { return $false }
  $code = (Get-HttpStatusCodeDetail -Port $p -TimeoutMs 6000 -Path $path).code
  return ($code -ge 200 -and $code -lt 400)
}

function Resolve-WebAuthUrl($CurrentPids, $ProbePorts = @()) {
  <#
    -Status 用：返回 @{ Url; State = 'ok'|'stale'|'unknown'; Detail; Refreshed }。
    旧地址绝不能被当成当前有效地址 —— 必须同时满足：
      ① 持久文件里的记录带 pid 且等于当前端口监听者 pid（否则是上一次 boot 的旧记录）；
      ② 带 token 的 HTTP 探测被当前实例接受（旧进程的 token 会被新进程拒绝）。
    文件缺失/过期时做一次「只读修复」：若日志里已经有**当前实例**的 token（同样以 HTTP
    探测证明），就补写持久文件。补写的只是状态目录里的一个缓存文件，不碰 DSH 实例 ——
    这样 20s 窗口错过 token 行（实测 117s）后，用户仍能在 -Status 里拿到地址。
    日志候选**不按 pid 预筛**：拉起时 `host.desktop.out.log` 是被 Start-Process 截断重写的，
    最后一条 `dsh web:` 行只可能属于当前 boot；而真正的判据是第 ② 条的带 token 探测 ——
    上一代的 token 会被新实例拒绝，绝不会被补写成「当前地址」。曾经的 pid 预筛把这条
    唯一的自愈路径关掉了：重启后持久文件里必然是上一代记录，于是 -Status 恒为 unknown。
  #>
  $pids = @()
  foreach ($p in @($CurrentPids)) { if ($null -ne $p) { $pids += [int]$p } }
  $file = Get-WebAuthUrlPath
  if ($pids.Count -eq 0) {
    return [pscustomobject]@{ Url = $null; State = 'stale'; Detail = '当前没有运行实例（端口无监听者）'; Refreshed = $false }
  }

  Add-Phase 'auth-file'
  $rec = Read-WebAuthUrlRecord
  $pidMatches = $false
  if ($rec -and $rec.Pid -gt 0) { $pidMatches = ($pids -contains [int]$rec.Pid) }
  $why = ''
  if (-not $rec) {
    $why = '尚无持久地址记录（' + $file + ' 不存在）'
  } elseif (-not $pidMatches) {
    $why = '持久文件记录的是 pid=' + $rec.Pid + ' 的旧 boot，当前监听者 pid=' + ($pids -join ',')
  } elseif (-not $rec.Token) {
    $why = '持久文件缺少 token'
  } elseif ((-not ([int]$rec.Port -gt 0) -or @($ProbePorts).Count -eq 0 -or @($ProbePorts) -contains [int]$rec.Port) -and (Test-WebAuthUrl $rec.Url)) {
    return [pscustomobject]@{ Url = $rec.Url; State = 'ok'; Detail = ('持久文件 pid=' + $rec.Pid + '，token 已被当前实例接受'); Refreshed = $false }
  } else {
    $why = '持久文件里的 token 未被当前实例接受（pid=' + $rec.Pid + '；宿主可能仍在启动，或该记录已过期）'
  }

  Add-Phase 'auth-log'
  $hit = Get-HostAuthUrlRecord (Get-StatePath (Get-HostLogName 'out'))
  if ($hit -and (Test-WebAuthUrl $hit.Url)) {
    [void](Save-WebAuthUrlRecord $hit.Url ([int]$pids[0]) ((Get-HostLogName 'out') + '（-Status 校验后补写）'))
    $fresh = Read-WebAuthUrlRecord
    if ($fresh -and $fresh.Url) {
      return [pscustomobject]@{ Url = $fresh.Url; State = 'ok'; Detail = ('持久文件已补写（pid=' + $fresh.Pid + '，token 已被当前实例接受）'); Refreshed = $true }
    }
  }
  return [pscustomobject]@{ Url = $null; State = 'unknown'; Detail = $why; Refreshed = $false }
}

function Get-AppendedText([string]$Path, [long]$Offset) {
  # 只读「Offset 之后」追加的内容。宿主正持有该文件的写入句柄，必须以 FileShare.ReadWrite
  # 打开；日志被 Start-Process 重定向覆盖（变短）时重置到文件头。
  $fs = $null
  try {
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    if ($Offset -lt 0 -or $Offset -gt $fs.Length) { $Offset = 0 }
    [void]$fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
    $len = [int]($fs.Length - $Offset)
    if ($len -le 0) { return [pscustomobject]@{ Text = ''; Offset = $Offset } }
    $buf = New-Object 'System.Byte[]' $len
    $read = $fs.Read($buf, 0, $len)
    return [pscustomobject]@{ Text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read); Offset = [long]($Offset + $read) }
  } catch {
    return $null
  } finally {
    if ($fs) { try { $fs.Dispose() } catch { } }
  }
}

function Wait-NewHostToken([string]$LogPath, [int]$MaxWaitMs = 20000) {
  <#
    等宿主打印**新的** boot token：dsh web 每次启动都会打印一行 `dsh web: http://…?token=…`，
    token 变化即证明新进程真的接管了（比只核对端口 owner 多一层证明）。
    只读「拉起之后追加的部分」（$script:LogOffsetBeforeLaunch 起），并把拉起前记下的
    $script:PrevBootToken 排除掉 —— 旧 token 绝不算本次地址。
    返回 URL；超时返回 $null（调用方只 WARN，不阻塞退出、不改变退出码）。
  #>
  if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return $null }
  $prevToken = [string]$script:PrevBootToken
  $offset = [long]$script:LogOffsetBeforeLaunch
  $deadline = (Get-Date).AddMilliseconds($MaxWaitMs)
  $scanned = ''
  do {
    $chunk = Get-AppendedText $LogPath $offset
    if ($chunk) {
      $offset = [long]$chunk.Offset
      $scanned = $scanned + [string]$chunk.Text
      foreach ($hit in [regex]::Matches($scanned, 'dsh\s+web:\s*(https?://\S+)')) {
        $url = $hit.Groups[1].Value.TrimEnd('.', ',', ')', '"', "'")
        $tok = Get-TokenFromUrl $url
        if ($tok -and $tok -ne $prevToken) { return $url }
      }
      if ($scanned.Length -gt 4096) { $scanned = $scanned.Substring($scanned.Length - 4096) }
    }
    if ($MaxWaitMs -le 0) { break }
    Start-Sleep -Milliseconds 400
  } while ((Get-Date) -lt $deadline)
  return $null
}

# ---------------------------------------------------------------- 环境探测

function Test-PortListening([int]$p) {
  # netstat 是权威（本机 Get-NetTCPConnection 在沙箱下不可靠）。
  # 解析统一走 Get-NetstatListenerRows —— 全脚本只有那一处调 netstat，且 3s 内在不同调用点之间复用。
  foreach ($row in @(Get-NetstatListenerRows)) { if ([int]$row.port -eq $p) { return $true } }
  return $false
}

function Get-PortOwner([int]$p) {
  $pids = @()
  foreach ($row in @(Get-NetstatListenerRows)) {
    # 【严格模式 2.0 陷阱 · 2026-09-12 真实事故】管道只产出一项时结果是**标量**，
    # 标量没有 .Count（非严格模式才会给标量补 Count=1）→ 这里一律 @() 包成数组。
    # 该次中止就发生在本行：restart-history.jsonl 18:15:03 aborted: 在此对象上找不到属性 Count
    if ([int]$row.port -eq $p) { $pids += [int]$row.pid }
  }
  # 恒返回数组：单元素时 Sort-Object 会解包成标量，调用方忘了 @() 就会踩同一个坑
  return @($pids | Sort-Object -Unique)
}

function Get-FreePort {
  $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $l.Start(); $p = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port; $l.Stop(); return $p
}

function Test-PortBindable([int]$p) {
  <#
    真正尝试 bind 一次 —— 判「新实例能不能起来」的唯一权威判据（R21）。
    2026-09-27 实测根因：旧实例被 taskkill /T /F 强杀后，端口可以「没有 LISTENING」
    却仍然 bind 不上；只判 LISTENING 的 Wait-PortFree 会放行，随后新宿主的
    @deepseek-ai/dsh-host-webserver 首绑报 EADDRINUSE，21 个依赖 webServer 的插件排队，
    启动从 ~35s 变成 90~125s。这里只 bind 不 accept，因此不会制造 TIME_WAIT。
  #>
  $l = $null
  try {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p)
    $l.Start()
    return $true
  } catch {
    return $false
  } finally {
    if ($l) { try { $l.Stop() } catch { } }
  }
}

function Get-HttpStatusCode([string]$Url, [int]$TimeoutSec = 6) {
  <#
    取 HTTP 状态码。先走 HttpClient（pwsh 7），取不到再退回 HttpWebRequest。
    为什么必须双路径：Windows PowerShell 5.1 默认没加载 System.Net.Http —— 实测连
    [System.Net.Http.HttpClientHandler] 类型都找不到。只用 HttpClient 时它对一切请求都返回 0：
    -Status 的 HTTP 字段恒为「无响应」、Wait-HostReady 永远等不到就绪、-ViaTask 的验证型
    重启因此整条走不通。
    两条路径都保持「不跟随重定向」：只有这样才能看见 303（token 有效）与 401（无效）的区别。
  #>
  $h = $null; $c = $null
  $code = 0
  try {
    $h = [System.Net.Http.HttpClientHandler]::new()
    $h.UseCookies = $true; $h.AllowAutoRedirect = $false
    $c = [System.Net.Http.HttpClient]::new($h)
    $c.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    $task = $c.GetAsync($Url)
    if ($task.Wait([TimeSpan]::FromSeconds($TimeoutSec + 1))) {
      $r = $task.GetAwaiter().GetResult()
      $code = [int]$r.StatusCode
    }
  } catch { $code = 0 } finally { if ($c) { $c.Dispose() }; if ($h) { $h.Dispose() } }
  if ($code -ne 0) { return $code }
  # ---- HttpWebRequest 兜底（Windows PowerShell 5.1 / 未加载 System.Net.Http 的环境）
  $req = $null
  try {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.AllowAutoRedirect = $false
    $req.Timeout = [Math]::Max(1000, $TimeoutSec * 1000)
    $req.ReadWriteTimeout = [Math]::Max(1000, $TimeoutSec * 1000)
    try {
      $resp = $req.GetResponse()
      try { return [int]$resp.StatusCode } finally { $resp.Close() }
    } catch [System.Net.WebException] {
      $errResp = $_.Exception.Response
      if ($errResp) { return [int]$errResp.StatusCode }
      return 0
    }
  } catch {
    return 0
  }
}

function Get-HttpStatusCodeDetail {
  <#
    单次 GET 的状态码，额外告诉调用方「这次是不是重发的那一遍」。
    走原始 TCP（不用 HttpClient / HttpWebRequest）：两个 .NET 请求栈在本机都有隐性成本 ——
    HttpClient 每次新建 ~200ms 起步，HttpWebRequest 要读完整响应才回来（3082 实测 1.6-2s）。
    宿主的面都是本机回环上的纯 HTTP/1.1，写请求 + 读响应头就够回答「几号状态码」。

    【实测坑，三条都踩过】
      ① TcpClient(host,port) 同步构造函数在**死端口**上要卡 ~14s（SYN 重试），
         ReceiveTimeout 只管后续读不管连接 —— 所以连接用 ConnectAsync(...).Wait(预算)；
      ② 在 try 里 return、finally 里 Close 的组合会让一次**成功**的调用固定多出 2s
         （五连测五次全是 ~2050ms）—— 所以一切返回都放在 try/finally 之外；
      ③ 读超时必须显式设 NetworkStream.ReadTimeout，光设 ReceiveTimeout 不够。
    服务器回 Connection: close / 不回内容长度时第一遍可能什么都读不到，所以要能重发一次。
      返回 @{ code; reconnecting }
  #>
  param([int]$Port, [string]$Host_ = $BindHost, [int]$TimeoutMs = 5000, [string]$Path = '/', [int]$Retries = 2)
  # $Path 必须带查询串：带 token 的地址是 /?token=… —— token 不在请求行里时宿主按「没凭据」
  # 回 401，看起来像「token 失效」（实测踩过一次，一个完全有效的 token 被判成失效）。
  if (-not $Path) { $Path = '/' }
  if (-not $Path.StartsWith('/')) { $Path = '/' + $Path }
  $req = "GET $Path HTTP/1.1`r`nHost: ${Host_}:$Port`r`nUser-Agent: dsh-restart-probe`r`nAccept: */*`r`nConnection: close`r`n`r`n"
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
  # 重发次数由调用方定：服务器回 Connection: close / 不回内容长度时第一遍可能什么都读不到，
  # 值得再问一次；但「读超时」说明对端连话都不说，重发只会把这个超时翻倍。
  $attempts = [Math]::Max(1, $Retries)
  $connectFailed = $false
  for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
    $c = $null
    $n = 0
    $connectFailed = $false
    $head = ''
    try {
      $c = [System.Net.Sockets.TcpClient]::new()
      $maxWait = [Math]::Max(200, [Math]::Min($TimeoutMs, 1500))
      if (-not $c.ConnectAsync($Host_, [int]$Port).Wait($maxWait)) {
        # 连不上 = 端口没人听。这不是「重发一次可能变好」的情况（SYN 重试要 ~14s），
        # 立刻返回，别让重发把这份等待翻倍。
        $connectFailed = $true
        continue
      }
      $ns = $c.GetStream()
      $ns.WriteTimeout = [Math]::Max(500, $TimeoutMs)
      $ns.ReadTimeout = [Math]::Max(500, $TimeoutMs)
      $ns.Write($bytes, 0, $bytes.Length)
      $ns.Flush()
      $buf = New-Object 'System.Byte[]' 512
      $n = $ns.Read($buf, 0, $buf.Length)
      if ($n -gt 0) { $head = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n) }
    } catch {
      $n = 0
    } finally {
      if ($c) { try { $c.Close() } catch { } }
    }
    # 走到这里连接一定已经关了：所有判定都在 try/finally 之外
    if ($n -gt 0) {
      $m = [regex]::Match($head, '^HTTP/\d\.\d\s+(\d{3})')
      if ($m.Success) {
        # 响应头里的 content-type 是区分「宿主面」与「兜底路由」的唯一廉价证据：
        # 兜底路由几毫秒就回 404 + application/json，宿主的认证面回 401 + text/plain。
        # 2026-11-27 实测：401 面一次读超时，-Status 就报 35877/404 而不是 35863/401。
        $ct = ''
        $ctm = [regex]::Match($head, '(?im)^content-type:\s*([^\r\n]+)')
        if ($ctm.Success) { $ct = $ctm.Groups[1].Value.Trim() }
        return [pscustomobject]@{ code = [int]$m.Groups[1].Value; reconnecting = ($attempt -eq 1); contentType = $ct }
      }
    }
  }
  # 区分两种失败，上游靠它决定要不要再等一次：连不上（端口没绑）vs 连上了但没回状态行
  # （读超时 / 对端乱说话）。前者重发没有意义，后者才值得在「宿主启动早期」再问一遍。
  if ($connectFailed -and $attempts -eq 1) { return [pscustomobject]@{ code = 0; reconnecting = $false; contentType = '' } }
  return [pscustomobject]@{ code = 0; reconnecting = $true; contentType = '' }
}

function Invoke-HttpProbe {
  <#
    带毫秒预算的单次 GET，只回答三件事：连上了吗、HTTP 状态码是多少、花了多久。
    它**不**区分 200 和 401 —— 后者属于认证策略，调用方自己判断语义。

    三条硬性约束（都是本机实测出来的）：
      ① 连接与读响应分开给预算。活着的 3082 端口偶发要 1.6-2s，一刀切 1.5s 会把活的 200 探成 0
         （假阴性，切端口时踩过一次）；死端口也不能拖住整个探针；
      ② 必须不走系统代理。宿主的 HTTP 面是本机回环，走 Clash 的 127.0.0.1:7897 只会绕远
         还会让并发探针互相排队 —— 原始 TCP 天然不受系统代理影响；
      ③ 每次探测都是一次**新建连接**，不复用（宿主的面会在启动早期重置 keep-alive）。
  #>
  param([int]$Port, [string]$Host_ = $BindHost, [int]$ConnectTimeoutMs = 1500, [int]$RequestTimeoutMs = 5000)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  # 先单独判一次「连得上吗」，把这层失败与「连上了但没回状态码」分开报告（别的调用方靠
  # stage 区分这两种情况，比如「端口绑了但路由没挂完」与「端口还没绑」）。
  $c = $null
  try {
    $c = [System.Net.Sockets.TcpClient]::new()
    if (-not $c.ConnectAsync($Host_, [int]$Port).Wait([Math]::Max(200, $ConnectTimeoutMs))) {
      $sw.Stop()
      return [pscustomobject]@{ status = 0; code = 0; ms = [int]$sw.ElapsedMilliseconds; stage = 'connect-timeout'; contentType = '' }
    }
  } catch {
    $sw.Stop()
    return [pscustomobject]@{ status = 0; code = 0; ms = [int]$sw.ElapsedMilliseconds; stage = 'connect-failed'; contentType = '' }
  } finally {
    if ($c) { try { $c.Close() } catch { } }
  }
  # 「连上了但一句话都不回」是唯一能把探测器拖满预算的形状（实测：accept 后永不响应的端口
  # 让一次 Invoke-HttpProbe 花掉 10.19s = 读超时 5s × 重发 2 次）。所以：连接阶段已经超时的
  # 端口不再进入读阶段（那里只会再等一次同样的超时）；真正读超时的也只在「重发一次可能有
  # 不同结果」时才重发 —— 见下面 $Retries 的推导。
  # 连接是通的（上面已经确认），才谈「重发一次」：这一步以前无论如何都发两次，一次读超时
  # 就翻倍成 10s。现在按「本端口是否值得再问一遍」决定，默认不问。
  $r = Get-HttpStatusCodeDetail -Port $Port -Host_ $Host_ -TimeoutMs $RequestTimeoutMs -Retries 1
  $sw.Stop()
  return [pscustomobject]@{
    status      = $r.code
    code        = $r.code
    ms          = [int]$sw.ElapsedMilliseconds
    stage       = 'http'
    reconn      = [bool]$r.reconnecting
    contentType = [string]$r.contentType
  }
}

function Test-HttpServing([string]$Url) {
  <#
    就绪判据（本机源码级实测）：
      dsh-host-webserver/lib/index.js:132-136, 237-241 ——
      「Activation listens IMMEDIATELY … the fallback handler answers anything
        not yet claimed during startup with **404 until its owner registers**」
    ⇒ 所以：
        连接失败(0)   = 还没绑端口
        404          = 端口已绑，但路由尚未注册完（插件仍在挂载）→ **不算就绪**
        401 / 200    = 索引路由/认证层已就位 → **真就绪**
    本机实测：隔离实例 9.4s 出现 404、10.4s 变为 401。
    上一版把「任意状态码」都当就绪，导致过早判定（假阳性）——这里收紧。
  #>
  $s = Get-HttpStatusCode $Url
  return [pscustomobject]@{
    status  = $s
    serving = ($s -ne 0)          # 端口已绑、有 HTTP 响应
    ready   = ($s -eq 401 -or $s -eq 200)   # 路由/认证层已就位
    authed  = ($s -eq 200)
  }
}

function Read-HostServing([string]$Url) {
  <#
    Test-HttpServing 的低开销版：只取状态码，走原始 TCP 探针（Get-HttpStatusCodeDetail）。
    与 Test-HttpServing 返回同样的 @{ status; serving; ready; authed }，判据一模一样：
      0 = 端口还没绑 / 404 = 路由没挂完 / 401、200 = 就绪。
    为什么单独一个函数：Test-HttpServing 走 .NET 请求栈（HttpClient→HttpWebRequest 兜底），
    一次几百毫秒到 2s；验证循环里每 800ms 问一次，光探针就吃掉大半等待预算。
    保留 Test-HttpServing 不动 —— 它带着「5.1 没有 System.Net.Http」那段历史契约，改它风险更大。
  #>
  $p = 0
  $path = '/'
  try { $u = [uri]$Url; if ($u.Port -gt 0) { $p = $u.Port }; if ($u.PathAndQuery) { $path = $u.PathAndQuery } } catch { return [pscustomobject]@{ status = 0; serving = $false; ready = $false; authed = $false } }
  $s = 0
  if ($p -gt 0) { $s = (Get-HttpStatusCodeDetail -Port $p -TimeoutMs 6000 -Path $path).code }
  return [pscustomobject]@{
    status  = $s
    serving = ($s -ne 0)
    ready   = ($s -eq 401 -or $s -eq 200)
    authed  = ($s -eq 200)
  }
}

function Get-CimAvailable {
  try { [void](Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop); return $true }
  catch { return $false }
}

function Get-HostCandidate {
  <#
    进程发现（R4 形状匹配在本机降级）：
      权威判据 = 目标端口的监听者 PID + 该 PID 是 node.exe
      辅证     = 深度验证实例必然由本脚本 -DoNotTouchDshHome 启动（node.exe + 端口）
    绝不做命令行模糊匹配（Linux 侧实测会命中 agent 自身命令行）。
    返回恒为数组（严格模式 2.0 下单对象没有 .Count）。
  #>
  $cands = New-Object System.Collections.ArrayList
  foreach ($p in @(Get-PortOwner $Port)) {
    $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
    if (-not $proc) { continue }
    $isNode = ($proc.ProcessName -match '^(node|dsh|bun)$')
    $cmd = ''
    if (-not $isNode) {
      # 这台机器的 `dsh` 是桌面版自带的 CLI shim：`dsh web` 实际是 Electron 进程跑
      # dsh-desktop-host\lib\cli.js web，进程名不是 node —— 只按进程名判会误拒 -Stop。
      try {
        $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
        if ($ci) { $cmd = [string]$ci.CommandLine }
      } catch { $cmd = '' }
      if ($cmd -match '(?i)(lib[\\/](bin|cli)\.js["'']?\s+web|dsh(\.cmd|\.exe)?["'']?\s+web)') { $isNode = $true }
    }
    [void]$cands.Add([pscustomobject]@{
      pid     = $p
      name    = $proc.ProcessName
      port    = $Port
      isNode  = $isNode
      start   = $(try { $proc.StartTime.ToString('o') } catch { '' })
      ws_mb   = [math]::Round($proc.WorkingSet64 / 1MB, 1)
      handles = $(try { $proc.HandleCount } catch { -1 })
      source  = 'port-listener'
    })
  }
  return @($cands.ToArray())
}

function Get-DshInstances {
  # 全量实例视图（恒为数组）。-Refresh 只对 desktop 分支有意义（web 分支本来就按端口现查）。
  param([switch]$Refresh)
  if ($script:HostKind -eq 'desktop') { return @(Get-DesktopInstances -Refresh:$Refresh) }
  return @(Get-HostCandidate)
}

function Test-HostAlive([int]$Pid_, [int]$P) {
  $proc = Get-Process -Id $Pid_ -ErrorAction SilentlyContinue
  if (-not $proc) { return $false }
  if ($script:HostKind -eq 'desktop') {
    # 桌面版的「活着」= 宿主子进程在 + Electron 主进程在（主进程没了，壳已经死了）
    if (-not $script:MainPid) { return $false }
    return [bool](Get-Process -Id $script:MainPid -ErrorAction SilentlyContinue)
  }
  return [bool](Get-PortOwner $P | Where-Object { $_ -eq $Pid_ })
}

# ---------------------------------------------------------------- 启动档案（文档 §7：Windows 读不到别人的 cwd/environ）

function Get-BootRecord {
  $p = Get-StatePath 'boot-record.json'
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Save-BootRecord([string]$CommandLine, [string]$WorkingDirectory) {
  $rec = [ordered]@{
    recordedAt = Get-NowIso
    command    = $CommandLine
    cwd        = $WorkingDirectory
    profile    = $Profile
    hostKind   = $script:HostKind
    port       = $Port
    host       = $BindHost
    dshHome    = $DshHome
    note       = 'dsh-restart 在重启时原样重放这条命令（Windows 读不到运行中进程的 cwd/environ）'
  }
  New-Utf8NoBom (Get-StatePath 'boot-record.json') ($rec | ConvertTo-Json -Depth 5)
  return $rec
}

function Resolve-Launch {
  # 返回 @{ file; args[]; cwd; source; raw }
  if ($script:HostKind -eq 'desktop') {
    $dl = Get-DesktopLaunch
    if ($dl) { return $dl }
    return [pscustomobject]@{ file = ''; args = @(); cwd = ''; source = 'desktop-app-missing'; raw = '' }
  }
  # 统一用 cmd.exe /c 重放命令文本：启动档案里记的就是用户在 shell 里敲的那一行，
  # 重放它比把命令拆成 argv 更贴近真实（也避免 pnpm/node 路径解析差异）。
  $rec = Get-BootRecord
  # 启动档案是**共享**的：桌面版记的是 App 的 exe，web 模式绝不能重放它
  # （否则 `-Profile web` 会把 web 宿主停掉、却把桌面 App 拉起来）。
  if ($rec -and $rec.command) {
    $desktopRecord = ([string](Get-JsonField $rec 'hostKind') -eq 'desktop') -or ([string]$rec.command -match '(?i)DeepSeek Harness\.exe')
    if ($desktopRecord) {
      Add-Step 'launch' "启动档案是 DSH Desktop 的记录（$($rec.command)）→ web 模式忽略它，改用 DEFAULT_LAUNCH" 'warn'
      $rec = $null
    }
  }
  if ($rec -and $rec.command) {
    $cwd = if ($rec.cwd) { $rec.cwd } else { (Get-Location).Path }
    $resolved = Resolve-DirectLaunch ($rec.command) "$Port"
    if ($resolved) {
      $resolved.source = "boot-record.json（已改写为直启 node+bin.js：$($rec.command)）"
      return $resolved
    }
    return [pscustomobject]@{
      file   = 'cmd.exe'
      args   = @('/c', ($rec.command -replace '\{PORT\}', "$Port"))
      cwd    = $cwd
      source = 'boot-record.json（经 cmd.exe 包装——无法直启时的兜底）'
      raw    = $rec.command
    }
  }
  # 统一：先试直启（node + dsh bin.js），失败才退回 shell 文本形态
  $resolvedFallback = Resolve-DirectLaunch ($script:DEFAULT_LAUNCH['args'] -join ' ') "$Port"
  if ($resolvedFallback) {
    $resolvedFallback.source = 'DEFAULT_LAUNCH（已直启 node+bin.js）'
    return $resolvedFallback
  }
  $args_ = @()
  foreach ($a in $script:DEFAULT_LAUNCH['args']) { $args_ += ($a -replace '\{PORT\}', "$Port") }
  return [pscustomobject]@{
    file   = $script:DEFAULT_LAUNCH['file']
    args   = $args_
    cwd    = $script:DEFAULT_LAUNCH['cwd']
    source = 'DEFAULT_LAUNCH（经 cmd.exe 包装——直启不可用时的兜底）'
    raw    = ($script:DEFAULT_LAUNCH['args'] -join ' ')
  }
}

function Resolve-DirectLaunch([string]$Command, [string]$PortText) {
  <#
    把「<shell> /c dsh web …」改写成「node.exe <dsh bin.js> web …」的**直启**形态。

    为什么必须这么做（本轮真实踩到）：
      经 cmd.exe /c 启动时，脚本记录的是 **cmd.exe 的 pid**，真正 serve 的是它启动的子进程，
      于是就绪校验报「端口 $Port 的服务者不是新实例（owner=X pid=Y）」，
      更糟的是**中止回收会去杀包装器而不是服务器**，可能留下孤儿。
      直启 node 后，Start-Process 返回的 pid 就是服务器本身，R7/R14/R20 全部自洽。
    只改写"dsh web …"这一种已知形态；任何自定义命令一律按原样走 cmd.exe（保持通用性）。
  #>
  $tokens = @(($Command.Trim() -split '\s+') | Where-Object { $_ -ne '' })   # @()：严格模式下单元素管道结果是标量，没有 .Count
  while ($tokens.Count -gt 0 -and ($tokens[0] -match '^(?i)(cmd(\.exe)?|powershell(\.exe)?|pwsh(\.exe)?)$' -or $tokens[0] -match '^/(c|d|s)$')) {
    $tokens = @($tokens | Select-Object -Skip 1)
  }
  $tokens = @($tokens | ForEach-Object { $_.Trim('"') })
  if ($tokens.Count -lt 2) { return $null }
  if ($tokens[0] -notmatch '^(?i)dsh(\.cmd|\.exe|\.ps1)?$') { return $null }
  if ($tokens[1] -ne 'web') { return $null }

  $binJs = Get-DshEntry
  $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
  if (-not $binJs -or -not $nodeExe) { return $null }

  # 参数从 $tokens[1] 开始取 —— 【必须包含子命令 web 本身】：
  # `node bin.js web --port N` 里 `web` 是 node 的第一个参数。
  # 早先写成 $tokens[2..] 把 web 丢了，结果拉起 `node bin.js --port N`，不可用（本轮实测踩到）。
  $rest = @()
  if ($tokens.Count -gt 1) { $rest = @($tokens[1..($tokens.Count - 1)]) }
  $rest = @($rest | ForEach-Object { $_ -replace '\{PORT\}', $PortText })
  if ($env:DSH_RESTART_DEBUG) {
    # 不能用 -f：$Command 里可能含 "{PORT}"，会被当成格式占位符而抛错
    Write-Diag ("      [dbg] cmd=" + $Command + "  tokens=[" + ($tokens -join '|') + "]  rest=[" + ($rest -join '|') + "]") -ForegroundColor DarkGray
  }
  # 没显式给 --port 就补上，确保拉起的是同一个端口
  if (-not ($rest -contains '--port') -and -not ($rest | Where-Object { $_ -like '--port=*' })) {
    $rest += @('--port', $PortText)
  }
  return [pscustomobject]@{
    file   = $nodeExe
    args   = @($binJs) + $rest
    cwd    = $env:USERPROFILE
    source = 'direct: node + dsh bin.js'
    raw    = "node `"$binJs`" $($rest -join ' ')"
  }
}

function Test-LaunchPrereq([string]$RawCommand, [string]$RawCwd) {
  <#
    预检「拉起」的外部依赖（两道闸门）：
      A) 启动命令第一个词必须能在 PATH 上解析到。
      B) 【真实事故换来的闸门】若 cwd 是 pnpm workspace 根、且命令以 pnpm 开头，
         则 `pnpm <script>` 会先跑 workspace 依赖检查并执行 pnpm install —— 一旦 install
         失败，宿主根本没机会启动。本机 tools 目录就是这种情况（其 package.json 定义了
         `dsh = node --import tsx/esm apps/cli/src/bin.ts`，跑的是仓库版 CLI 而非全局包）。
    注意：必须传"命令文本"，不能直接看 DEFAULT_LAUNCH['args']（第一个元素是 cmd 的 /c）。
  #>
  if ($script:HostKind -eq 'desktop') {
    $exe = Resolve-DesktopAppPath
    if (-not $exe) {
      Add-Step 'launch-prereq' '找不到 DSH Desktop 可执行文件：用 -Record -RecordCommand "\"<path>\DeepSeek Harness.exe\"" 记录一次，或把 hostKind 设成 web' 'fail'
      return $false
    }
    Add-Step 'launch-prereq' "DSH Desktop 可执行文件存在：$exe" 'ok'
    return $true
  }
  $raw = $RawCommand
  $cwd = $RawCwd
  if (-not $raw -or -not $cwd) {
    $rec = Get-BootRecord
    if ($rec -and $rec.command) {
      if (-not $raw) { $raw = $rec.command }
      if (-not $cwd) { $cwd = $rec.cwd }
    }
    if (-not $raw) { $raw = ($script:DEFAULT_LAUNCH['args'] | Where-Object { $_ -ne '/c' }) -join ' ' }
    if (-not $cwd) { $cwd = $script:DEFAULT_LAUNCH['cwd'] }
  }
  $tokens = @(($raw.Trim() -split '\s+') | Where-Object { $_ -ne '' })   # @()：同上（严格模式下标量没有 .Count）
  # 剥离可能的 launcher 前缀（cmd.exe /c、powershell -Command …）：
  # 否则会把 cmd.exe 当成"命令名"，闸门 B 就会漏判（实测踩过）。
  while ($tokens.Count -gt 0 -and ($tokens[0] -match '^(?i)(cmd(\.exe)?|powershell(\.exe)?|pwsh(\.exe)?)$' -or $tokens[0] -match '^/(c|d|s)$')) {
    $tokens = @($tokens | Select-Object -Skip 1)
  }
  $tokens = @($tokens | ForEach-Object { $_.Trim('"') })
  $first = $tokens[0]
  if (-not $first) { Add-Step 'launch-prereq' "启动命令为空（$raw）" 'fail'; return $false }

  $cmd = Get-Command $first -ErrorAction SilentlyContinue
  if (-not $cmd) {
    Add-Step 'launch-prereq' "'$first' 在 PATH 上找不到（启动命令：$raw）→ 拉起会失败。请用 -Record 记录可用命令，或把它的目录加入 PATH" 'fail'
    return $false
  }
  Add-Step 'launch-prereq' "'$first' 可解析 → $($cmd.Source)" 'ok'

  # 闸门 B：包管理器 + cwd 把该名字定义成本地脚本 = 会先装依赖 / 跑的不是全局包
  #   判据不依赖 pnpm-workspace.yaml（实测它会随仓库状态消失，脆弱）；
  #   改为直接看 cwd 的 package.json 是否把该名字定义为脚本 —— 这才是「pnpm <name> 会
  #   先做 workspace 依赖检查并执行本地脚本」的真正原因。
  if ($first -match '^(?i)(pnpm|npm|yarn|bun)(\.cmd|\.exe|\.ps1)?$' -and $cwd) {
    $pkgJson = Join-Path $cwd 'package.json'
    $localScript = $null
    if (Test-Path -LiteralPath $pkgJson) {
      try { $localScript = (Get-Content -LiteralPath $pkgJson -Raw -Encoding UTF8 | ConvertFrom-Json).scripts.$($tokens[1]) } catch { }
    }
    $wsFile = Join-Path $cwd 'pnpm-workspace.yaml'
    if ($localScript -or (Test-Path -LiteralPath $wsFile)) {
      $why = if ($localScript) { "cwd 的 package.json 把「$($tokens[1])」定义成了本地脚本：$localScript" }
             else { "cwd 是 pnpm workspace 根（存在 pnpm-workspace.yaml）" }
      $msg = "{0} → 「{1} {2}」会先执行依赖安装/本地脚本，跑的不是全局包，极易启动失败。请用 -Record 记录全局命令（如 `dsh web --no-open --host 127.0.0.1 --port {{PORT}}`）并把 cwd 设为 %USERPROFILE%（或删除 boot-record.json 用内置兜底）" -f $why, $first, $tokens[1]
      Add-Step 'launch-prereq' $msg 'fail'
      return $false
    }
  }
  return $true
}

function Show-LaunchFailure([string]$OutPath, [string]$ErrPath) {
  # 拉起后进程立刻退出时，把它的输出尾部打出来 —— 没有这个，排障只能靠猜。
  Add-Step 'launch-died' "宿主进程在就绪前退出，下面是它的输出（诊断用）" 'warn'
  foreach ($f in @($OutPath, $ErrPath)) {
    if ($f -and (Test-Path -LiteralPath $f)) {
      # @()：单行文件时 Get-Content 返回 String（标量），严格模式下 String 没有 .Count
      $l = @(Get-Content -LiteralPath $f -Encoding UTF8 -ErrorAction SilentlyContinue)
      if ($l.Count) {
        Write-Diag "      | --- $(Split-Path $f -Leaf)（最后 12 行）---" -ForegroundColor DarkYellow
        $l | Select-Object -Last 12 | ForEach-Object { Write-Diag ("      | " + $_.Substring(0, [Math]::Min(200, $_.Length))) }
        $errLines = $l | Select-String -Pattern 'ERROR|Error:|error:|failed|exit code' | Select-Object -First 6
        if ($errLines) {
          Write-Diag "      | --- 命中错误行 ---" -ForegroundColor DarkYellow
          $errLines | ForEach-Object { Write-Diag ("      | " + $_.Line.Trim().Substring(0, [Math]::Min(200, $_.Line.Trim().Length))) }
        }
      }
    }
  }
}

# ---------------------------------------------------------------- 深度验证（R1/R2/R16，文档 §10）

function Get-DshEntry {
  <#
    解析 dsh 本体入口（lib/bin.js）。Windows 上 dsh 是 npm 全局 .cmd/.ps1 shim，
    真正的可执行入口是 <npm-global>\node_modules\@deepseek-ai\dsh\lib\bin.js。
    优先用 node 直接跑 bin.js：能精确控制 argv，也不会多套一层 cmd/pnpm。
  #>
  $cands = @()
  $cands += (Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\lib\bin.js')
  $cands += (Join-Path $env:ProgramFiles 'nodejs\node_modules\@deepseek-ai\dsh\lib\bin.js')
  $g = Get-Command dsh -ErrorAction SilentlyContinue
  if ($g) {
    $dir = Split-Path $g.Source -Parent
    $cands += (Join-Path $dir 'node_modules\@deepseek-ai\dsh\lib\bin.js')
  }
  foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
  return $null
}

function Remove-VerifyInstance([int]$ProcId, [int]$ProcPort, [string]$Dir, [bool]$KeepDir, [ref]$Progress) {
  <#
    收干净验证实例（R16/R20）。实测教训：只 kill 进程对象是不够的 ——
    若宿主在启动早期就报错但句柄未释放，HasExited 不会置位，taskkill 会扑空并留下孤儿。
    因此这里三层兜底：① 进程对象 ② 端口占用者（权威） ③ 确认端口真的释放后才删目录。
  #>
  if ($ProcId) {
    & (Get-SystemTool 'taskkill') /PID $ProcId /T /F *> $null
    Start-Sleep -Milliseconds 600
  }
  if ($ProcPort) {
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
      $owners = @(Get-PortOwner $ProcPort)
      if ($owners.Count -eq 0) { break }
      foreach ($o in $owners) {
        Write-Audit 'warn' "验证实例残留：端口 $ProcPort 仍被 pid=$o 占用，强制回收"
        & (Get-SystemTool 'taskkill') /PID $o /T /F *> $null
        $proc = Get-Process -Id $o -ErrorAction SilentlyContinue
        if ($proc) { try { Stop-Process -Id $o -Force -ErrorAction Stop } catch { } }
      }
      Start-Sleep -Milliseconds 700
    }
    if (@(Get-PortOwner $ProcPort).Count -ne 0) {
      if ($Progress) { $Progress.Value = $false }
      Add-Step 'deep-verify-cleanup' "端口 $ProcPort 未能释放（占用者 $(@(Get-PortOwner $ProcPort) -join ',')），目录保留以便排查：$Dir" 'warn'
      return
    }
  }
  if ($Progress) { $Progress.Value = $true }
  if (-not $KeepDir) { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
  else { Add-Step 'deep-verify-cleanup' "失败日志按要求保留：$Dir" 'warn' }
}

function Copy-TreeWithLinks([string]$Source, [string]$Dest) {
  <#
    拷贝一棵树，但**不跟随**重解析点（符号链接/junction）：遇到链接就地重建为 junction。
    为什么必须这样：.dsh-module-fallback 里几乎全是宿主维护的符号链接，且它们指向
    真实 node_modules。用 robocopy /sl 或 Copy-Item -Recurse 都会跟随链接把 967MB
    真实内容抄一遍（本机实测：robocopy 跑 23s 仍在大批量拷贝，属实现缺陷）。
    只对 node_modules 这一层用 junction（见 Test-DeepVerify），其余一律真拷贝。
  #>
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null
  foreach ($item in (Get-ChildItem -LiteralPath $Source -Force -ErrorAction SilentlyContinue)) {
    $target = Join-Path $Dest $item.Name
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      # 不跟随：重建为 junction（免管理员）。失败就跳过并在日志里留痕，不静默。
      try {
        $linkTarget = (Get-Item -LiteralPath $item.FullName -Force).Target
        if ($linkTarget -is [array]) { $linkTarget = $linkTarget[0] }
        if ($linkTarget) { New-Item -ItemType Junction -Path $target -Target $linkTarget -ErrorAction Stop | Out-Null }
      } catch {
        Write-Audit 'warn' "Copy-TreeWithLinks: 重建链接失败 $($item.FullName) -> $($_.Exception.Message.Split([char]10)[0])"
      }
      continue
    }
    if ($item.PSIsContainer) { Copy-TreeWithLinks $item.FullName $target }
    else { Copy-Item -LiteralPath $item.FullName -Destination $target -Force -ErrorAction SilentlyContinue }
  }
}

function Test-SymlinkPrivilege {
  <#
    预检：DSH 宿主每次启动都会用 fs.symlinkSync 维护 profile 的模块投影链接
    （dsh-app-boot lib/index.js ensureSymlink）。Windows 上 CreateSymbolicLinkW 需要
    「管理员」或「开发者模式」；两者都没有时，任何一次冷启动都会 EPERM —— 而运行中
    的旧实例照样服务（典型「线上正常 ≠ 组合 OK」）。
    本机实测：cmd mklink /D 与 New-Item -ItemType SymbolicLink 均报权限不足；
    只有 junction 可用。故必须把这一条当成前置条件显式预检并给出修复路径。
  #>
  $dir = Join-Path $StateDir 'symlink-probe'
  try {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $target = Join-Path $dir 'target'; $link = Join-Path $dir 'link'
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }
    if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue }
    $ok = $false
    try { New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null; $ok = $true } catch { $ok = $false }
    $fix = '需要二者之一：① 设置→隐私和安全性→开发者选项 打开「开发者模式」（一次性，无需管理员即可永久生效）；② 以管理员身份运行本脚本（计划任务已设 RunLevel=HighestAvailable）'
    Add-Step 'symlink-preflight' $(if ($ok) { '可创建符号链接（宿主启动前提满足）' } else { "无法创建符号链接 → 冷启动必失败。$fix" }) $(if ($ok) { 'ok' } else { 'fail' })
    return $ok
  } catch {
    Add-Step 'symlink-preflight' "预检异常: $($_.Exception.Message.Split([char]10)[0])" 'warn'
    return $true   # 无法判定时不拦截，交给深度验证给出真实结果
  } finally {
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

function Test-DeepVerify {
  if ($script:HostKind -eq 'desktop') { return (Test-DesktopVerify) }
  $root = if ($VerifyTempRoot) { $VerifyTempRoot } else { $env:TEMP }
  if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
  $v = Join-Path $root ("dsh-verify." + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $vPort = Get-FreePort
  $keepLog = $false
  $p = $null
  try {
    New-Item -ItemType Directory -Path $v -Force | Out-Null

    # 组装隔离 profile（关键，本机逐条实测得出的结论）：
    #   A) 顶层小文件（package.json / cordis.patch.yml / cordis.yml / lock）→ 真拷贝。
    #      宿主每次组装都要重写 cordis.yml，必须落在可写位置。
    #   B) node_modules（967MB）→ junction 到真实目录。写 <profile>\node_modules\<pkg>
    #      之类深层路径会穿透 junction，只有 junction 本层句柄是只读的。
    #   C) .dsh-module-fallback → 真拷贝，但**不跟随**其中的符号链接（见 Copy-TreeWithLinks）。
    #      这套是宿主每次组装都要「写」的归属目录（ensureSymlink/ensureProfileSymlink），
    #      若也做成 junction，写入会落到真实 profile 上，且 junction 层写入 EPERM。
    # 未知 profile 在桌面版下不是错误：宿主本来就只跑 desktop，引擎会自动取用户层目录名。
    Resolve-DesktopProfileName
    $vProfile = Join-Path $v ('profiles\' + $Profile)
    New-Item -ItemType Directory -Path $vProfile -Force | Out-Null
    $srcProfile = Join-Path $DshHome ('profiles\' + $Profile)
    foreach ($f in (Get-ChildItem -LiteralPath $srcProfile -File -Force -ErrorAction SilentlyContinue)) {
      Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $vProfile $f.Name) -Force -ErrorAction SilentlyContinue
    }
    $srcFallback = Join-Path $srcProfile '.dsh-module-fallback'
    if (Test-Path -LiteralPath $srcFallback) {
      Copy-TreeWithLinks $srcFallback (Join-Path $vProfile '.dsh-module-fallback')
    }
    $srcNm = Join-Path $srcProfile 'node_modules'
    if (-not (Test-Path -LiteralPath $srcNm)) {
      # L3：这里必须**提前失败并说清根因**。以前只 warn 就继续，随后 $vNm（只在 else 分支
      # 赋值）在 StrictMode 2.0 下抛「无法检索变量 '$vNm'」，报错位置离根因很远。
      $why = "真实 profile 缺少 node_modules（$srcNm）→ 隔离验证实例组装不出依赖，深度验证无法进行。请先让该 profile 完成依赖安装（正常启动/更新器会装），或确认 -Profile '$Profile' 是否正确"
      Add-Step 'deep-verify' $why 'fail'
      return [pscustomobject]@{ ok = $false; reason = 'profile-missing-node-modules'; tail = @($why) }
    }
    # D) profiles 级 node_modules 必须是**真目录**：宿主每次启动都会在这里补/删
    #    投影链接（dsh-app-boot lib/index.js:730-737 ensureSymlink/ensureProfileSymlink，
    #    且 ensureProfileSymlink 在 lstatSync 命中时早返回 → 是幂等的）。
    #    若把这一层做成 junction，写入 EPERM（实测）。所以改为逐顶层条目 junction。
    $vNm = Join-Path $vProfile 'node_modules'
    New-Item -ItemType Directory -Force -Path $vNm | Out-Null
    foreach ($it in (Get-ChildItem -LiteralPath $srcNm -Force -ErrorAction SilentlyContinue)) {
      try { New-Item -ItemType Junction -Path (Join-Path $vNm $it.Name) -Target $it.FullName -ErrorAction Stop | Out-Null } catch { }
    }
    # E) 预建 fallback 已持有包的 profile 侧投影链接，让宿主的 heal 直接短路。
    $vnFb = Join-Path $vProfile '.dsh-module-fallback\node_modules'
    foreach ($entry in (Get-ChildItem -LiteralPath $vnFb -Force -ErrorAction SilentlyContinue)) {
      if ($entry.Name -like '@*' -and $entry.PSIsContainer) {
        foreach ($sub in (Get-ChildItem -LiteralPath $entry.FullName -Force -ErrorAction SilentlyContinue)) {
          $link = Join-Path (Join-Path $vNm $entry.Name) $sub.Name
          if (-not (Test-Path -LiteralPath $link)) {
            New-Item -ItemType Directory -Force -Path (Split-Path $link -Parent) | Out-Null
            try { New-Item -ItemType Junction -Path $link -Target $sub.FullName -ErrorAction Stop | Out-Null } catch { }
          }
        }
      } elseif (-not (Test-Path -LiteralPath (Join-Path $vNm $entry.Name))) {
        try { New-Item -ItemType Junction -Path (Join-Path $vNm $entry.Name) -Target $entry.FullName -ErrorAction Stop | Out-Null } catch { }
      }
    }

    $out = Join-Path $v 'boot.out'
    $err = Join-Path $v 'boot.err'
    # 直接用 dsh 本体 argv 启动，避免套 cmd/pnpm 两层带来的端口/形状误判
    $dshBin = Get-DshEntry
    if (-not $dshBin) { Add-Step 'deep-verify' '找不到 dsh 本体（lib/bin.js），跳过深度验证' 'warn'; return $null }
    # 临时实例必须自证清白：DSH_UC_PROFILE_NODE_MODULES 显式指向它**自己**的 profile
    # node_modules，否则会继承真实 home 的那份，让更新器把真实 profiles 当成自己的根。
    $env2 = @{ DSH_HOME = $v; DSH_UC_PROFILE_NODE_MODULES = $vNm }
    # 注意：`web` 是 `--profile web` 的别名，它自己**不接受** --profile。
    # 实测传了会 `error: unknown option '--profile'`；而此时 config-manager 已挂载，
    # 进程不会退出 → 旧版清理逻辑扑空并留下孤儿。不要再加 --profile。
    $vArgs = @($dshBin, 'web', '--port', "$vPort", '--host', '127.0.0.1', '--no-open')
    $p = Start-Process -FilePath (Get-Command node).Source `
         -ArgumentList $vArgs `
         -WorkingDirectory $v -WindowStyle Hidden -Environment $env2 `
         -RedirectStandardOutput $out -RedirectStandardError $err -PassThru

    $deadline = (Get-Date).AddSeconds($VerifyReadySec)
    # 本次动作的总预算同样封顶深度验证：两层各计一个 150s 就是这台机器上「无声等待 5 分钟」的来历。
    if ($script:ActionDeadline -and $script:ActionDeadline -lt $deadline) { $deadline = $script:ActionDeadline }
    $tokenSeen = $false
    $verifyStart = Get-Date
    $verifyRound = 0
    while ((Get-Date) -lt $deadline) {
      $verifyRound++
      # 这一步是整条链里最长的一段静默（隔离宿主起来要约 60-200s）：必须有心跳。
      Write-Activity 'deep-verify' ("等待隔离宿主端口 " + $vPort + " 就绪：第 " + $verifyRound + " 轮，已等 " +
        [int]((Get-Date) - $verifyStart).TotalSeconds + "s / 预算 " + $VerifyReadySec + "s" +
        $(if ($null -ne (Get-BudgetLeftSec)) { "（本次动作剩余 " + (Get-BudgetLeftSec) + "s）" } else { '' }))
      if ($p.HasExited) { break }
      if (-not $tokenSeen) {
        foreach ($f in @($out, $err)) {
          if (Test-Path -LiteralPath $f) {
            $txt = Get-Content -LiteralPath $f -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($txt -match 'token=') { $tokenSeen = $true }
          }
        }
      }
      $probe = Read-HostServing ("http://127.0.0.1:$vPort/")
      # 只认 401/200（404 = 路由还没注册完，不算就绪）
      if ($probe.ready) { break }
      Start-Sleep -Milliseconds 900
    }

    $final = Test-HttpServing ("http://127.0.0.1:$vPort/")
    if ($final.ready) {
      $extra = if ($tokenSeen) { '日志已出现 token=' } else { '日志未见 token=（HTTP 已 401）' }
      Add-Step 'deep-verify' ("临时实例 $vPort 路由就绪 HTTP=$($final.status)；$extra") 'ok'
      return [pscustomobject]@{ ok = $true; port = $vPort; http = $final.status; logdir = $v }
    }

    # 失败：区分「起不来」与「起了但没就绪」，并保留日志（R16）
    $keepLog = $true
    $tail = @()
    foreach ($f in @($out, $err)) {
      if (Test-Path -LiteralPath $f) {
        # @()：单行文件时 Get-Content 返回 String（标量）；此处虽未取 .Count，
        # 也统一包成数组，避免以后在这里加 .Count 又踩同一个坑
        $l = @(Get-Content -LiteralPath $f -Encoding UTF8 -ErrorAction SilentlyContinue)
        $tail += ($l | Select-Object -Last 15)
        $tail += ($l | Select-String -Pattern 'error|throw|failed|EPERM|EADDRINUSE|unknown option' | Select-Object -First 10 | ForEach-Object { $_.Line })
      }
    }
    $script:VerifyTail = $tail
    $why = if ($p.HasExited) { "进程已退出（exit=$($p.ExitCode)）" }
           elseif ($final.serving) { "进程在跑、端口已绑，但 $VerifyReadySec s 内路由未就绪（最后 HTTP=$($final.status)）" }
           else { "$VerifyReadySec s 内端口未响应" }
    Add-Step 'deep-verify' ("临时实例 $vPort 未就绪：$why；日志保留在 $v" + $(if ($tail) { "`n" + ($tail -join "`n") } else { '' })) 'fail'
    return [pscustomobject]@{ ok = $false; port = $vPort; logdir = $v; tail = $tail }
  } catch {
    Add-Step 'deep-verify' "验证实例启动异常: $($_.Exception.Message)" 'fail'
    return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
  } finally {
    # 收干净（R16/R20）：三层兜底，且在确认端口释放后才删目录
    $cleanupOk = $false
    Remove-VerifyInstance -ProcId $(if ($p) { $p.Id } else { 0 }) -ProcPort $vPort -Dir $v -KeepDir $keepLog -Progress ([ref]$cleanupOk)
    if (-not $cleanupOk) { Write-Audit 'warn' "验证实例未完全回收：$v" }
  }
}

# ---------------------------------------------------------------- 深度验证（带一次重试）

# 为什么要重试（2026-09-20 实测）：隔离 home 里没有 dsh-config-manager 的备份台账
# （backup-schedule.json 的 lastRunAt），临时实例每次都要把它的「启动期导出 + 定时备份
# （本地 ZIP）」跑一遍；这一步偶发会顶到预算上限。同日 8 次验证里有 2 次因此假失败
# （端口已绑、日志停在「config-manager 已挂载」之后，最后 HTTP=404），而重跑均在 21s 内通过。
# 首次未就绪只说明「这次没赶上」，不代表组合坏：fail-closed 的结论由重试后的结果决定。
function Invoke-DeepVerifyWithRetry {
  $dv = Test-DeepVerify
  if ($null -eq $dv -or $dv.ok) { return $dv }
  $retryable = $true
  if ($dv.PSObject.Properties['retryable']) { $retryable = [bool]$dv.retryable }
  if (-not $retryable) {
    Add-Step 'deep-verify' '隔离宿主进程仍存活但一直没就绪（某个插件在启动期挂住）→ 重试不会改变结果，跳过重试' 'warn'
    return $dv
  }
  Add-Step 'deep-verify' "首次未就绪（预算 ${VerifyReadySec}s）→ 重试一次；隔离 home 每次都要跑 config-manager 的启动期导出/定时备份，偶发会顶到预算" 'warn'
  $script:VerifyTail = @()
  $dv2 = Test-DeepVerify
  if ($dv2 -and $dv2.ok) { Add-Step 'deep-verify' '重试通过（首次为假失败）' 'ok' }
  return $dv2
}

# ---------------------------------------------------------------- 续跑通知（R12，文档 §5.4）

function Get-NewestSessionId {
  $base = Join-Path $DshHome 'sessions'
  if (-not (Test-Path -LiteralPath $base)) { return $null }
  $f = Get-ChildItem -LiteralPath $base -Recurse -File -Filter 'session*.jsonl*' -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $f) { return $null }
  return ($f.Directory.Name -replace '^session-', '')
}

function Normalize-SessionId([string]$Id) {
  # 续跑通知里的 sessionId 必须是 DSH 认的规范形态 `session-<id>`
  # （持久化目录就是 sessions\<workspace>\session-<id>）。2026-11-25 实测：
  # 旧实现剥掉前缀写成裸 uuid，waker 拿它去 sessionPersistence.stat 找不到会话，
  # notice 直接归档成 dropped，被中断的会话不会被唤醒。
  # 两种输入都接受，输出恒为规范形态，所以幂等。
  if (-not $Id) { return $null }
  if ($Id -eq 'auto') {
    $newest = Get-NewestSessionId
    if (-not $newest) { return $null }
    return ('session-' + ($newest -replace '^session-', ''))
  }
  return ('session-' + ($Id -replace '^session-', ''))
}

function Write-PendingNotice([string]$SessionId, [string]$Why) {
  if (-not $SessionId) { Add-Step 'notice' '未指定会话，跳过续跑通知（boot 侧将回退 target=primary）' 'skip'; return $false }
  $dir = Join-Path $DshHome '.smart-restart'
  $json = @{ sessionId = $SessionId; reason = $Why; when = Get-NowIso } | ConvertTo-Json
  try {
    New-Utf8NoBom (Join-Path $dir 'pending-notice.json') $json
    Add-Step 'notice' "已写 pending-notice.json → session $SessionId（无 BOM）" 'ok'
    return $true
  } catch {
    Add-Step 'notice' "写 pending-notice.json 失败: $($_.Exception.Message)" 'warn'
    return $false
  }
}

# ---------------------------------------------------------------- 门禁（R10）与等空闲（R11）

function Test-ConfigOperationGate {
  $hits = @()
  foreach ($pat in @('*.transaction', '*.transaction.json', 'RECOVERY_REQUIRED*')) {
    $hits += @(Get-ChildItem -LiteralPath $DshHome -Filter $pat -Recurse -Force -ErrorAction SilentlyContinue -Depth 2)
  }
  foreach ($n in @('dsh-config-manager\locks', 'dsh-config-manager\.locks')) {
    $p = Join-Path $DshHome $n
    if (Test-Path -LiteralPath $p) { $hits += @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue) }
  }
  return $hits
}

function Get-StaleEnvLockAdvice {
  # 只读归因：locks 目录里的残留锁是不是「持有者已确证死亡的崩溃残留」。
  # 为什么需要它：Test-ConfigOperationGate 只看锁文件在不在，会把上次进程被强杀留下的
  # 残留锁说成「进行中的配置操作」——用户于是去找一个根本不存在的运行中操作，而且拿不到
  # 回收命令。这里只补准确的归因与下一步，不改变 fail-closed 结论。
  #   - 只诊断，绝不删除任何文件；回收一律交给
  #     `dsh-config-manager recover-stale-lock`（它会二次验证 owner 确证死亡、原子捕获、
  #     再校验一次；校验不过就 quarantine，不会误删活锁）。
  #   - 任何不确定（读不到 / 解析失败 / pid 仍活 / 心跳缺失）→ 返回 $null，
  #     宁可不提示，也不把活锁误报成残留。
  $locksDir = Join-Path $DshHome 'dsh-config-manager\locks'
  $ownPath = Join-Path $locksDir 'environment.lock'
  if (-not (Test-Path -LiteralPath $ownPath)) { return $null }
  $rec = $null
  try { $rec = (Get-Content -LiteralPath $ownPath -Raw -Encoding utf8 | ConvertFrom-Json) } catch { return $null }
  if (-not $rec -or -not $rec.owner) { return $null }
  $instId = [string]$rec.owner.instanceId
  $ownerPid = 0
  try { $ownerPid = [int]$rec.owner.pid } catch { $ownerPid = 0 }
  if (-not $instId -or $ownerPid -le 0) { return $null }
  # 持有者仍活着 → 不是残留：保持原样，交给调用方按「进行中」处理
  if (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue) { return $null }
  # 心跳时间：优先 sidecar，缺失则退回 ownership.acquiredAt
  $lastMs = 0
  $hbPath = Join-Path $locksDir ('environment.heartbeat.' + $instId)
  if (Test-Path -LiteralPath $hbPath) {
    try {
      $hb = (Get-Content -LiteralPath $hbPath -Raw -Encoding utf8 | ConvertFrom-Json)
      if ($hb.heartbeatAt) { $lastMs = [long]$hb.heartbeatAt }
    } catch { $lastMs = 0 }
  }
  if ($lastMs -le 0 -and $rec.acquiredAt) {
    try { $lastMs = [long]$rec.acquiredAt } catch { $lastMs = 0 }
  }
  if ($lastMs -le 0) { return $null }
  $lastUtc = [DateTimeOffset]::FromUnixTimeMilliseconds($lastMs).UtcDateTime
  $ageSec = ((Get-Date).ToUniversalTime() - $lastUtc).TotalSeconds
  # 阈值取产品默认 stale 阈值（10s）的 3 倍，避免把心跳抖动误判成残留
  if ($ageSec -lt 30) { return $null }
  $ageTxt = if ($ageSec -ge 3600) { '{0:N1} 小时' -f ($ageSec / 3600) } else { '{0:N0} 秒' -f $ageSec }
  $whenTxt = $lastUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
  return "environment.lock 判定为「残留锁」（不是进行中的操作）：持有者 pid=$ownerPid 已确证不存在，心跳停在 $whenTxt（约 $ageTxt 前），op=$($rec.op)。重启不会自愈，需先显式回收：dsh-config-manager recover-stale-lock（owner 未确证死亡时它会拒绝执行，不会误删活锁）"
}

function Wait-SessionIdle([int]$MaxSec) {
  # 就绪判据的近似：会话文件在 IdleSec 内无新增写入即视为空闲
  if ($MaxSec -le 0) { return $true }
  $base = Join-Path $DshHome 'sessions'
  $quietFor = 5
  $deadline = (Get-Date).AddSeconds($MaxSec)
  while ((Get-Date) -lt $deadline) {
    $f = Get-ChildItem -LiteralPath $base -Recurse -File -Filter 'session*.jsonl*' -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f -and ((Get-Date) - $f.LastWriteTime).TotalSeconds -ge $quietFor) {
      Add-Step 'wait-idle' "会话已空闲 $([math]::Round(((Get-Date) - $f.LastWriteTime).TotalSeconds,1))s" 'ok'
      return $true
    }
    Start-Sleep -Seconds 2
  }
  Add-Step 'wait-idle' "等待空闲超时（$MaxSec s），按超时继续重启（R11：超时行为写入日志）" 'warn'
  return $false
}

# ---------------------------------------------------------------- 停机（文档 §5）

function Invoke-TryCtrlC([int]$Pid_) {
  # 同控制台才有效；失败无害，直接回退强杀。默认关闭。
  #
  # 【必须隔离到子进程】FreeConsole + AttachConsole 之后本进程就没有控制台了，
  # 紧接着的 netstat.exe 会以「程序'netstat.exe'运行失败：获取控制台模式时发生
  # Win32 内部错误 句柄无效。0x6」直接终止 —— 2026-11-25 18:30 那次 restart 就是
  # 在 graceful 之后这样 aborted 的（宿主没停、run 失败）。子进程崩掉只回一个非零
  # 退出码，主进程继续走 taskkill 强杀。发送器：scripts/dsh-ctrlc-sender.ps1；
  # 对照组：test/console-probe.ps1。
  $sender = Join-Path $PSScriptRoot 'dsh-ctrlc-sender.ps1'
  if (-not (Test-Path -LiteralPath $sender -PathType Leaf)) {
    Add-Step 'graceful' "Ctrl+C 发送器缺失（$sender），回退强杀" 'warn'
    return $false
  }
  try {
    $self = $null
    try { $self = (Get-Process -Id $PID -ErrorAction Stop).Path } catch { $self = $null }
    if (-not $self) { $self = Join-Path $PSHOME 'pwsh.exe' }
    $proc = Start-Process -FilePath $self -ArgumentList @(
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', $sender, '-TargetPid', "$Pid_"
    ) -WindowStyle Hidden -PassThru
    $null = $proc.WaitForExit(10000)
    if (-not $proc.HasExited) {
      try { $proc.Kill() } catch { }
      Add-Step 'graceful' 'Ctrl+C 发送器超时（10s），回退强杀' 'warn'
      return $false
    }
    $rc = $proc.ExitCode
    Add-Step 'graceful' "AttachConsole+Ctrl+C 结果: $($rc -eq 0)（隔离子进程 exit=$rc）" $(if ($rc -eq 0) { 'ok' } else { 'warn' })
    return ($rc -eq 0)
  } catch {
    Add-Step 'graceful' "Ctrl+C 路径不可用（$($_.Exception.Message.Split([char]10)[0])），回退强杀" 'warn'
    return $false
  }
}

function Format-KillOutput($Output, [int]$MaxSample = 3) {
  <#
    taskkill /T 会对每个子孙各回一行，动辄几十条，把真正有用的那句（Access is denied /
    需要 /F）埋掉。这里只统计成因并留两三条样本，输出从「一堵墙」压成一行。
  #>
  $lines = @($Output | ForEach-Object { ([string]$_ -replace '\s+', ' ').Trim() } | Where-Object { $_ })
  if (-not $lines.Count) { return '（无输出）' }
  $denied = @($lines | Where-Object { $_ -match 'Access is denied|拒绝访问' }).Count
  $force = @($lines | Where-Object { $_ -match 'terminated forcefully|只能强制' }).Count
  $kids = @($lines | Where-Object { $_ -match 'child processes of this process were still running|子进程' }).Count
  $okMsg = @($lines | Where-Object { $_ -match '^(SUCCESS|成功)' }).Count
  $parts = @()
  if ($denied) { $parts += "权限拒绝 $denied 条" }
  if ($force) { $parts += "只能强制终止 $force 条" }
  if ($kids) { $parts += "子进程未退 $kids 条" }
  if ($okMsg) { $parts += "已发信号 $okMsg 条" }
  $summary = if ($parts.Count) { ($parts -join '、') } else { '未分类' }
  $sample = ($lines | Select-Object -First $MaxSample) -join ' | '
  return ("共 " + $lines.Count + " 行（" + $summary + "）；样本：" + $sample)
}

function Test-StopPermission([int]$Pid_) {
  <#
    动手之前先判断「杀不杀得掉」。Windows 不允许未提升进程终止已提升进程，而这个判定
    原本要等到 stop 阶段才暴露 —— 那时深度验证（约 60s、起一个临时实例）已经白跑了。
    提前判死能省掉这段时间，也让失败落在一个说得清的位置上。
    返回 @{ ok = 可以尝试终止; denied = 明确是权限边界; elevated = 自身是否提升; reason }
  #>
  $elev = Test-Elevation
  if (-not $elev.ok) { return [pscustomobject]@{ ok = $true; denied = $false; elevated = $null; reason = '自身提权状态未知' } }
  if ($elev.elevated) { return [pscustomobject]@{ ok = $true; denied = $false; elevated = $true; reason = '自身已提升' } }
  # 目标已消失时 OpenProcess 同样失败（探测回 1），会被误判成权限不足。实际是 discover
  # 之后它自己退了，按可终止处理，让流程继续走冷启动分支。
  if (-not (Get-Process -Id $Pid_ -ErrorAction SilentlyContinue)) {
    return [pscustomobject]@{ ok = $true; denied = $false; elevated = $false; reason = '目标已不存在' }
  }
  $probe = -1
  try { $probe = [DshElev]::CanQueryTargetToken($Pid_) } catch { $probe = 2 }
  if ($probe -eq 1) { return [pscustomobject]@{ ok = $false; denied = $true; elevated = $false; reason = '目标令牌打不开（更高完整性级别）' } }
  if ($probe -eq 0) { return [pscustomobject]@{ ok = $true; denied = $false; elevated = $false; reason = '目标令牌可查询' } }
  return [pscustomobject]@{ ok = $true; denied = $false; elevated = $false; reason = '探测无结论' }
}

function Stop-DshInstance([int]$Pid_, [int]$WaitSeconds, [int]$MainPid_ = 0) {
  if ($MainPid_ -gt 0) { return (Stop-DesktopApp $MainPid_ $Pid_ $WaitSeconds) }
  # 先温和 /T（不带 /F），再宽限，再强杀 /T /F —— /T 连子孙（R8）。
  # 必须记录 taskkill 的真实 exit code 与输出：被拒绝（权限/沙箱）与「没生效」是两回事。
  Add-Step 'stop' "taskkill /PID $Pid_ /T（温和，连子树）" 'ok'
  $o1 = & (Get-SystemTool 'taskkill') /PID $Pid_ /T 2>&1
  $rc1 = $LASTEXITCODE
  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process -Id $Pid_ -ErrorAction SilentlyContinue)) {
      Add-Step 'stop' "进程 $Pid_ 已退出（温和路径，taskkill rc=$rc1）" 'ok'; return $true
    }
    Start-Sleep -Milliseconds 500
  }
  Add-Step 'stop' "宽限 ${WaitSeconds}s 内未退出（taskkill rc=$rc1：$(Format-KillOutput $o1)），强杀 /T /F" 'warn'
  $o2 = & (Get-SystemTool 'taskkill') /PID $Pid_ /T /F 2>&1
  $rc2 = $LASTEXITCODE
  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process -Id $Pid_ -ErrorAction SilentlyContinue)) {
      Add-Step 'stop' "进程 $Pid_ 已退出（强杀路径，taskkill rc=$rc2）" 'ok'; return $true
    }
    Start-Sleep -Milliseconds 500
  }
  Add-Step 'stop' "进程 $Pid_ 仍未退出。taskkill /T/F rc=$rc2 输出：$(Format-KillOutput $o2)" 'fail'

  # 权限边界判定：Windows 不允许未提升进程终止已提升进程。
  # 与其丢一句 "Access is denied"，不如说清根因与两条出路。
  $denied = ("$($o2 -join ' ')" -match 'Access is denied|拒绝访问')
  if ($denied) {
    $elev = Test-Elevation
    $taskOk = Get-TaskRegistered
    Add-Step 'stop-hint' ("taskkill 报 Access is denied —— 这是 Windows 的完整性级别边界：" +
      "**未提升的进程杀不掉已提升的进程**（本机宿主常从管理员窗口启动，属于已提升）。" +
      "当前进程 Elevated=" + $(if ($elev.ok) { $elev.elevated } else { '未知' }) + "。") 'fail'
    Add-Step 'stop-hint' ("两条出路：① 在**管理员**窗口里重跑 dsh-restart（最直接）；" +
      "② 先 dsh-restart -RegisterTask（需一次管理员），之后用 dsh-restart -ViaTask " +
      "让计划任务以完整令牌执行 —— 任务当前" + $(if ($taskOk) { '已注册 ✓' } else { '未注册 ✗' }) + "。") 'fail'
  }
  return $false
}

function Wait-PortFree([int]$P, [int]$MaxSec) {
  # R21：不能只判「没有 LISTENING」——必须确认端口**真的能 bind**，否则会把
  # 「看起来空、实际绑不上」的状态放行给新实例，造成 webserver 首绑 EADDRINUSE。
  $deadline = (Get-Date).AddSeconds($MaxSec)
  while ((Get-Date) -lt $deadline) {
    if ((-not (Test-PortListening $P)) -and (Test-PortBindable $P)) { return $true }
    Start-Sleep -Milliseconds 500
  }
  return $false
}

function Remove-OrphanDshChildren {
  <#
    回收旧实例遗留的「孤儿」DSH 子进程（R22）。
    为什么需要：taskkill /T /F 杀主进程时，孙辈（codegraph MCP / native worker）
    偶尔能活下来，并继承父进程的监听套接字句柄 —— 新实例 webserver 首绑就会
    EADDRINUSE。这里只清「父进程已不存在」且命令行明确属于 DSH/codegraph 的 node，
    不动 Codex 自己拉起的那批 MCP 进程（它们的父进程仍在）。
  #>
  $killed = New-Object System.Collections.ArrayList
  foreach ($proc in @(Get-Process -Name node -ErrorAction SilentlyContinue)) {
    $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction SilentlyContinue
    if (-not $ci) { continue }
    $cmd = [string]$ci.CommandLine
    if ($cmd -notmatch 'deepseek-ai|codegraph') { continue }
    $ppid = [int]$ci.ParentProcessId
    if ($ppid -gt 0 -and (Get-Process -Id $ppid -ErrorAction SilentlyContinue)) { continue }
    [void]$killed.Add($proc.Id)
    & (Get-SystemTool 'taskkill') /PID $proc.Id /T /F *> $null
  }
  if ($killed.Count -gt 0) {
    Add-Step 'stop-orphans' "回收旧实例遗留的孤儿 DSH 子进程：$($killed -join ',')" 'warn'
  }
  return @($killed.ToArray())
}

function Get-ResidualChildren([int]$RootPid) {
  # 扫尾（R8/R9）：只报「非本次实例」的 node 进程，不做模糊全局杀。恒返回数组。
  $out = New-Object System.Collections.ArrayList
  foreach ($proc in @(Get-Process -Name node -ErrorAction SilentlyContinue)) {
    if ($proc.Id -eq $RootPid) { continue }
    [void]$out.Add([pscustomobject]@{ pid = $proc.Id; name = $proc.ProcessName; ws_mb = [math]::Round($proc.WorkingSet64/1MB,1) })
  }
  return @($out.ToArray())
}

# ---------------------------------------------------------------- 拉起

function Start-DshInstance {
  if ($script:HostKind -eq 'desktop') { return (Start-DesktopApp) }
  # 环境块先按注册表重建（见 Sync-ProcessEnvironment 注释）：被旧终端或计划任务拉起的
  # dsh-restart 继承的是过期环境快照，只有在这里重读注册表，setx 改过的变量才能到达新宿主。
  # 放在函数最前，保证「解析」与「拉起」用的是同一份最新环境（PATH 也在其中）。
  $envPlan = Sync-ProcessEnvironment
  $envNote = '环境块已按注册表重建：' + $envPlan.TotalCount + ' 项（继承底 ' + $envPlan.InheritedCount +
             '，覆盖 machine ' + $envPlan.MachineCount + ' / user ' + $envPlan.UserCount +
             '，跳过 ' + $envPlan.SkippedCount + '）；PATH ' + $envPlan.PathItems + ' 项（Machine 在前、user 其次、继承兜底，去重）'
  if ($envPlan.MachineFailed -or $envPlan.UserFailed) { $envNote = $envNote + '；注意：某层注册表读取失败，该层退化为继承值' }
  Add-Step 'launch' $envNote 'ok'

  # 宿主专用环境变量（进程级，子进程继承）——修 dsh-update-checker 的两处老毛病：
  #   1) DSH_UC_PROFILE_NODE_MODULES：本机插件装在 <DshHome>\profiles\<profile>\node_modules，
  #      而更新器默认用 dirname(插件所在 node_modules) 反推 profile 根，会算成 …\profiles\<profile>，
  #      于是 findDeclaringProfiles 找不到「声明该插件的 profile」：
  #      更新能把文件装进 node_modules，却**不写 package.json 与 pnpm-lock.yaml**，
  #      之后任何一次 pnpm install 都会按旧 lock 把它们全部还原（2026-09-20 实测 29 个插件全被还原）。
  #      显式指向 profiles 级共享依赖目录即可修正；该变量是插件源码明确支持的覆盖点。
  #   2) NPM_CONFIG_LEGACY_PEER_DEPS：更新器在临时目录用 npm 取包，rc 版宿主的 peer 范围常年
  #      对不上，npm 直接 ERESOLVE 失败（2026-09-20 实测 agent-teams / agency-agents /
  #      mcp-connector 三个全失败）。等价于旧 dsh-uc-peer-patch 的 --legacy-peer-deps，
  #      但不改插件文件，插件升级也不会被覆盖。
  # 刻意只写进程环境、不写用户级变量：NPM_CONFIG_LEGACY_PEER_DEPS 是全局 npm 开关，
  # 落到用户级会影响用户自己终端里的 npm 行为。
  #
  # 开关（M-10）：这两条是「改写宿主行为」的注入，允许显式关掉 —— DSH_RESTART_INJECT_HOST_ENV=0
  # 时整段跳过，宿主按自己的默认行为走。默认（变量未设或为其它值）与今天逐字一致。
  # DSH_HOME 不在开关范围内：它决定宿主用哪个 home，跳过去只会让宿主跑错目录。
  $env:DSH_HOME = $DshHome
  if ($env:DSH_RESTART_INJECT_HOST_ENV -ne '0') {
    $env:DSH_UC_PROFILE_NODE_MODULES = Join-Path $DshHome 'profiles\node_modules'
    $env:NPM_CONFIG_LEGACY_PEER_DEPS = 'true'
    Add-Step 'launch' "已注入宿主环境 DSH_HOME=$env:DSH_HOME、DSH_UC_PROFILE_NODE_MODULES=$env:DSH_UC_PROFILE_NODE_MODULES、NPM_CONFIG_LEGACY_PEER_DEPS=$env:NPM_CONFIG_LEGACY_PEER_DEPS" 'ok'
  } else {
    Add-Step 'env' '按 DSH_RESTART_INJECT_HOST_ENV=0 跳过宿主环境注入' 'skip'
  }

  $launch = Resolve-Launch
  # 日志按宿主形态分文件：桌面 App 会用 stdout 句柄长期占住自己的日志，
  # 与 web 宿主共用同一个 host.out.log 时，后拉起的一方连 banner 都写不进去。
  $webOut = Get-StatePath (Get-HostLogName 'out')
  $webErr = Get-StatePath (Get-HostLogName 'err')
  if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }

  foreach ($f in @($webOut, $webErr)) {
    $banner = ("`n===== dsh-restart {0} 拉起 profile={1} port={2} cmd={3} cwd={4} =====" -f `
      (Get-Date -Format o), $Profile, $Port, $launch.raw, $launch.cwd) + "`r`n"
    # L2：宿主日志是 UTF-8，banner 必须用同一编码写。这里用 .NET AppendAllText + **无 BOM**
    # 的 UTF8 明确写死 —— Add-Content -Encoding UTF8 在两个引擎上并不等价：实测新建文件时
    # 5.1 会先写 EF BB BF、pwsh 7 不写（追加到已有文件时两者才一致）。显式编码后 banner
    # 的字节在 5.1 与 pwsh 下完全相同，不会出现 GBK/混编码。
    try { [System.IO.File]::AppendAllText($f, $banner, (New-Object System.Text.UTF8Encoding($false))) } catch { }
  }

  # boot token 判据的基线：拉起前记下旧 token 与日志长度。
  # 随后 url 步只认「变化后」的 token —— 上一实例的 token 即使还留在日志/持久文件里，
  # 也绝不能被当成本次新实例的地址。
  $script:PrevBootToken = ''
  $prevRec = Read-WebAuthUrlRecord
  if ($prevRec -and $prevRec.Token) { $script:PrevBootToken = $prevRec.Token }
  else {
    $prevLog = Get-HostAuthUrlRecord $webOut
    if ($prevLog -and $prevLog.Token) { $script:PrevBootToken = $prevLog.Token }
  }
  $script:LogOffsetBeforeLaunch = 0
  if (Test-Path -LiteralPath $webOut) { $script:LogOffsetBeforeLaunch = [long](Get-Item -LiteralPath $webOut).Length }

  $cwd = $launch.cwd
  if (-not (Test-Path -LiteralPath $cwd)) {
    Add-Step 'launch' "启动目录不存在（$cwd），退回 $env:USERPROFILE" 'warn'
    $cwd = $env:USERPROFILE
  }

  $stdinPath = Get-EmptyStdinPath
  if ($stdinPath) {
    $p = Start-Process -FilePath $launch.file -ArgumentList $launch.args `
         -WorkingDirectory $cwd -WindowStyle Hidden -PassThru `
         -RedirectStandardOutput $webOut -RedirectStandardError $webErr -RedirectStandardInput $stdinPath
  } else {
    $p = Start-Process -FilePath $launch.file -ArgumentList $launch.args `
         -WorkingDirectory $cwd -WindowStyle Hidden -PassThru `
         -RedirectStandardOutput $webOut -RedirectStandardError $webErr
  }

  $script:HostOutPath = $webOut
  $script:HostErrPath = $webErr
  $script:NewPid = $p.Id
  Add-Step 'launch' "已拉起 pid=$($p.Id) via $($launch.file) (来源: $($launch.source))，cwd=$cwd，日志→$webOut" 'ok'
  return $p
}

function Wait-HostReady([int]$Pid_, [int]$P, [int]$MaxSec, [datetime]$Start_) {
  if ($script:HostKind -eq 'desktop') { return (Wait-DesktopHostReady $Pid_ $MaxSec $Start_) }
  $url = "http://${BindHost}:$P/"
  $deadline = (Get-Date).AddSeconds($MaxSec)
  # 本次动作的总预算封顶（深度验证已经花掉的部分要从这里扣）：超预算就明确报超时，
  # 不在这里重新开始一个新的 90s。
  if ($script:ActionDeadline -and $script:ActionDeadline -lt $deadline) { $deadline = $script:ActionDeadline }
  $last = [pscustomobject]@{ status = 0; serving = $false; authed = $false }
  $tokenSeen = $false
  $round = 0
  $waitStart = Get-Date
  while ((Get-Date) -lt $deadline) {
    $round++
    $proc = Get-Process -Id $Pid_ -ErrorAction SilentlyContinue
    $last = Test-HttpServing $url
    if ($last.ready) {
      # 确认监听者就是我们起的这条进程链（R7/R14：核对实际端口归属）
      $owner = @(Get-PortOwner $P)
      $ownerOk = $owner -contains $Pid_
      if (-not $ownerOk) {
        # 经 shell 包装器启动时，端口可能由其子进程持有 → 沿父链核对归属，
        # 并用**真实服务器 pid** 作为本次新实例（否则后续回收会杀错进程、留孤儿）。
        $resolved = $null
        foreach ($o in $owner) {
          $cur = $o; $hop = 0
          while ($cur -and $hop -lt 6) {
            if ($cur -eq $Pid_) { $resolved = $o; break }
            $pp = (Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue).ParentProcessId
            $cur = if ($pp) { [int]$pp } else { $null }
            $hop++
          }
          if ($resolved) { break }
        }
        if ($resolved) {
          Add-Step 'ready' "端口 $P 的服务者是子进程 pid=$resolved（启动器 pid=$Pid_）→ 以 $resolved 为本实例" 'ok'
          $script:NewPid = $resolved
        } else {
          Add-Step 'ready' "端口 $P 的服务者不属于本次启动链（owner=$($owner -join ',') 启动器=$Pid_）→ 可能是别的实例或残留，判定失败" 'fail'
          return [pscustomobject]@{ ok = $false; reason = 'port-owner-mismatch'; owner = $owner }
        }
      }
      if (-not (Get-Process -Id $script:NewPid -ErrorAction SilentlyContinue)) {
        Add-Step 'ready' "进程 $($script:NewPid) 在服务前退出" 'fail'
        return [pscustomobject]@{ ok = $false; reason = 'exited' }
      }
      Add-Step 'ready' ("HTTP $($last.status)（$url）" + $(if ($last.authed) { '；已认证 200' } else { '；401 = 索引路由已就位（无 token 属正常）' })) 'ok'
      return [pscustomobject]@{ ok = $true; http = $last.status; authed = $last.authed; pid = $script:NewPid }
    }
    if (-not $proc) {
      Add-Step 'ready' "进程 $Pid_ 已退出（未就绪）" 'fail'
      Show-LaunchFailure $script:HostOutPath $script:HostErrPath
      return [pscustomobject]@{ ok = $false; reason = 'exited' }
    }
    Write-Activity 'ready' ("等待 web 宿主就绪 " + $url + "：第 " + $round + " 轮，HTTP " + $last.status +
      "，已等 " + [int]((Get-Date) - $waitStart).TotalSeconds + "s，剩余预算 " + $(if ($null -ne (Get-BudgetLeftSec)) { (Get-BudgetLeftSec).ToString() + 's' } else { '不限' }))
    Write-ProgressLine 'ready' ("web 宿主 " + $url + "，第 " + $round + " 轮，HTTP " + $last.status)
    Start-Sleep -Milliseconds 900
  }
  $diag = if ($last.status -eq 404) { "端口已绑但 ${MaxSec}s 内路由未就绪（404）" } elseif ($last.status -eq 0) { "${MaxSec}s 内端口无响应" } else { "最后状态码 $($last.status)" }
  Add-Step 'ready' "等待就绪超时 ${MaxSec}s：$diag" 'fail'
  return [pscustomobject]@{ ok = $false; reason = 'timeout'; last = $last.status }
}

# ---------------------------------------------------------------- 锁（R11/R20：句柄不可被继承）

# 一次动作的总预算。
# 为什么需要：一个失败的重启可以合法地把 2×150s（深度验证 + 重试）+ 90s（就绪）+ 30s（端口释放）
# 一路等完 —— 七分钟以上，而每一层各自计时要等，命令行里连一个字都不出。预算把它收敛成
# 「一次动作一批时间」，且每个等待都引用同一个截止时刻，于是剩余时间可以被报出来。
# 只读动作（-Status / -CheckShadowed / -RepairSharedScope / -Record）不设预算：它们本来就快，
# 而且不能被一个不相关的截止时刻打断。
# 进度行：给「正在等」的那一段在屏幕上留下会动的痕迹。
# 为什么必须有（2026-11-23 实测）：整个动作的预算已经收敛成一份，但一个阶段内部（深验证 70-150s、
# 就绪 60-140s）仍然一行字都不出；命令行看起来和卡死一模一样。这里每 ProgressSec 秒打一行
# 「阶段 · 第几轮 · 已等 · 剩余」，写 stderr（-Json 下同样写到 stderr，stdout 只有一个 JSON）。
# 只在阶段循环里被调用；阶段结束（Add-Step 成功）后由 Add-Step 追加一行「合计」。
function Write-ProgressLine([string]$Stage, [string]$Detail) {
    $now = Get-Date
    # 单个阶段内的「已等」从这里算起；StageStart 只在阶段结束时被 Add-Step 用来算合计。
    if (-not $script:ProgressStageStart -or $script:StageName -ne $Stage) {
        $script:StageName = $Stage; $script:StageStart = $now; $script:ProgressStageStart = $now; $script:ProgressLastTick = $null
    }
    $script:StageOpen = $true
    if ($script:ProgressLastTick -and ($now - $script:ProgressLastTick).TotalSeconds -lt [Math]::Max(1, $ProgressSec)) { return }
    $script:ProgressLastTick = $now
    $left = Get-BudgetLeftSec
    $leftText = if ($null -ne $left) { '剩余 ' + $left + 's' } else { '不设上限' }
    Write-Diag ('  .. ' + $Stage + ' · 已等 ' + [int]($now - $script:ProgressStageStart).TotalSeconds + 's · ' + $leftText + $(if ($Detail) { ' · ' + $Detail } else { '' }))
}

function Format-BudgetParts {
    # 预算由哪几段组成 —— 说明与措辞共用一处，免得两处数字对不上（旧版就出现过「就绪 90s」
    # 与预算里按 240s 算的两套说法）。
    $verify = 0
    if ($Preflight -or $VerifyOnly) { $verify = 2 * $VerifyReadySec }
    elseif (-not $Start -and -not $Fast -and -not $Stop -and -not $DryRun) { $verify = 2 * $VerifyReadySec }
    # 主进程冒烟：桌面版在深验证之外还要真起一次 Electron 主进程（临时 userData/DSH_HOME）。
    # 它和深验证是两层，不能互相替代：深验证只覆盖 dsh-desktop-host。
    $gui = 0
    if ($script:HostKind -eq 'desktop' -and -not $Start -and -not $Stop -and -not $DryRun -and -not $Fast -and -not $SkipGuiProbe) { $gui = 25 }
    $ready = $ReadySec
    $free = if ($Stop) { [Math]::Max(30, $PortFreeSec) } else { $PortFreeSec }
    $grace = if ($Stop) { 0 } else { $GraceSec }
    $parts = @()
    if ($verify -gt 0) { $parts += ('深度验证 ' + $verify + 's（' + $VerifyReadySec + 's × 2 次尝试）') } else { $parts += '深度验证 0s（本次跳过）' }
    if ($gui -gt 0) { $parts += ('主进程冒烟 ' + $gui + 's') }
    $parts += ('端口释放 ' + $free + 's')
    if (-not $Stop) { $parts += ('就绪 ' + $ready + 's') }
    if ($grace -gt 0) { $parts += ('收尾 ' + $grace + 's') }
    $parts += '固定余量 60s'
    return ($parts -join ' + ')
}

function Set-ActionBudget {
    if ($Status -or $CheckShadowed -or $RepairSharedScope -or $Record) {
        $script:ActionDeadline = $null
        $script:ActionBudgetSec = 0
        return
    }
    $budget = 0
    if ($DryRun) { $budget = [Math]::Max(30, $ReadySec) }
    elseif ($Stop) { $budget = [Math]::Max(30, $PortFreeSec) + 30 }
    elseif ($Preflight -or $VerifyOnly) {
        $guiPart = 0
        if ($script:HostKind -eq 'desktop' -and -not $SkipGuiProbe) { $guiPart = 25 }
        $budget = 2 * $VerifyReadySec + 60 + $guiPart
    }
    else {
        $verifyPart = 0
        # 桌面版同样要深验证（隔离宿主）—— 旧判据把 desktop 排除在外，预算里写「深度验证 0s」，
        # 实际却跑了 60-150s，就绪等待于是被总预算提前掐断（2026-11-27 实测）。
        if (-not $Start -and -not $Fast) { $verifyPart = 2 * $VerifyReadySec + 60 }
        $guiPart = 0
        if ($script:HostKind -eq 'desktop' -and -not $Start -and -not $Fast -and -not $SkipGuiProbe) { $guiPart = 25 }
        $budget = $verifyPart + $guiPart + $PortFreeSec + $ReadySec + $GraceSec + 60
    }
    $script:ActionBudgetSec = [int]$budget
    $script:ActionDeadline = (Get-Date).AddSeconds([int]$budget)
}

function Get-MutexName {
  # 桌面版端口随机且发现前未知：按形态命名互斥体，避免不同端口的两套宿主互相放行
  if ($script:HostKind -eq 'desktop') { return 'Local\dsh-restart-desktop' }
  return ('Local\dsh-restart-p' + $Port)
}

function Enter-RestartLock {
  $name = Get-MutexName
  $diag = [ordered]@{ process = $PID; name = $name; createdNew = $null; waitOne = $null; error = '' }
  try {
    $createdNew = $false
    $script:Mutex = [System.Threading.Mutex]::new($false, $name, [ref]$createdNew)
    $diag.createdNew = $createdNew
    $got = $script:Mutex.WaitOne(0)
    $diag.waitOne = $got
    [void]$script:Audit.Add($diag)
    return $got
  } catch {
    $diag.error = $_.Exception.Message
    [void]$script:Audit.Add($diag)
    return $false
  }
}

function Exit-RestartLock {
  if ($script:Mutex) {
    try { $script:Mutex.ReleaseMutex() } catch { }
    try { $script:Mutex.Dispose() } catch { }
    $script:Mutex = $null
  }
}


function Test-StorageGate {
  <#
    存储预检的统一入口：写 steps，返回「是否放行」。
    -Rehearsal 给 -DryRun 用：失败只 warn，不拦；$ForceStorage 由脚本作用域提供。
  #>
  param([switch]$Rehearsal)
  $check = Test-StoragePreflight
  Add-Step 'storage' ('存储预检：' + $check.summary) $(if ($check.ok) { 'ok' } else { 'fail' })
  if ($check.ok) { return $true }
  foreach ($e in @($check.errors | Select-Object -First 8)) { Add-Step 'storage' ($e.file + ': ' + $e.message) 'fail' }
  if ($Rehearsal) {
    Add-Step 'storage' '-DryRun：只报告，不中止（真实重启会在这里 exit 3）' 'warn'
    return $true
  }
  if ($ForceStorage) {
    Add-Step 'storage' '-ForceStorage：已显式忽略存储预检失败，继续' 'warn'
    return $true
  }
  Add-Step 'storage' '先修存储再重启：node scripts\workspace-store-doctor.mjs --check；宿主退出后 --fix --apply' 'fail'
  return $false
}

function Test-StoragePreflight {
  <#
    只读体检 <DshHome>\storages：JSON 能否解析 + workspace 域记录是否符合 schema 形状。
    为什么放在重启前：workspace.json 是整份 zod 校验，任何一条记录不合规（最常见：
    createdAt/updatedAt 被外部脚本写成 Date.now() 毫秒数）都会让 workspace 域 FAILED，
    侧栏「工作区」变空、10 个依赖插件 PENDING，而宿主日志里只有一行 state=FAILED。
    -WorkspaceOnly 只查 workspace.json，供 -Status 轮询使用（几十毫秒）。
    返回 [pscustomobject]：ok / checked / errors / warnings / files / summary。
  #>
  param([switch]$WorkspaceOnly)

  $errors = New-Object System.Collections.ArrayList
  $warnings = New-Object System.Collections.ArrayList
  $files = New-Object System.Collections.ArrayList
  $addErr = { param($f, $m) [void]$errors.Add([pscustomobject]@{ file = [string]$f; message = [string]$m }) }
  $addWarn = { param($f, $m) [void]$warnings.Add([pscustomobject]@{ file = [string]$f; message = [string]$m }) }

  $root = Join-Path $DshHome 'storages'
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    & $addWarn 'storages' '目录不存在（全新安装或 DSH_HOME 指错）'
    return [pscustomobject]@{
      ok = $true; checked = 0; errors = @(); warnings = @($warnings); files = @()
      summary = 'storages 目录不存在'
    }
  }

  foreach ($f in @(Get-ChildItem -LiteralPath $root -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
    $name = $f.Name
    if ($WorkspaceOnly -and $name -ne 'workspace.json') { continue }
    [void]$files.Add([pscustomobject]@{ file = $name; bytes = [int64]$f.Length; ok = $true })
    if ($f.Length -gt 33554432) {
      & $addWarn $name ('文件 {0:N1} MB，超过 32 MB 上限，已跳过解析' -f ($f.Length / 1MB))
      continue
    }
    $obj = $null
    try {
      $obj = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
      & $addErr $name ('JSON 解析失败：' + $_.Exception.Message.Split([char]10)[0])
      $files[$files.Count - 1].ok = $false
      continue
    }
    if ($name -eq 'workspace.json') {
      $unit = $null
      if ($obj.PSObject.Properties['unit']) { $unit = $obj.unit }
      if (-not $unit) { & $addErr $name '缺少 unit' }
      else {
        if ([string]$unit.name -ne 'workspace') { & $addErr $name ("unit.name 应为 'workspace'，实际 '" + [string]$unit.name + "'") }
        if ([int]$unit.version -ne 2) { & $addErr $name ('unit.version 应为 2，实际 ' + [string]$unit.version) }
      }
      $g = $null
      if ($obj.PSObject.Properties['global']) { $g = $obj.global }
      if (-not $g) { & $addErr $name '缺少 global' }
      else {
        if ($g.PSObject.Properties['initialized'] -and $g.initialized -isnot [bool]) { & $addErr $name 'global.initialized 应为 boolean' }
        foreach ($key in @('workspaceIds', 'archivedSessionIds', 'pinnedSessionIds')) {
          $kp = $g.PSObject.Properties[$key]
          if (-not $kp) {
            if ($key -eq 'workspaceIds') { & $addErr $name 'global.workspaceIds 缺失' }
            else { & $addWarn $name ('global.' + $key + ' 缺失（schema 有默认值，建议补 []）') }
            continue
          }
          if ($kp.Value -isnot [System.Array]) { & $addErr $name ('global.' + $key + ' 应为字符串数组') }
        }
      }
      $tables = $null
      if ($obj.PSObject.Properties['tables']) { $tables = $obj.tables }
      $rows = $null
      if ($tables) { $rp = $tables.PSObject.Properties['workspaces']; if ($rp) { $rows = $rp.Value } }
      if (-not $rows) { & $addErr $name '缺少 tables.workspaces' }
      else {
        $ids = @($rows.PSObject.Properties | ForEach-Object { $_.Name })
        $order = @()
        if ($g) { $op = $g.PSObject.Properties['workspaceIds']; if ($op) { $order = @($op.Value) } }
        foreach ($id in $order) { if ($ids -notcontains [string]$id) { & $addErr $name ('global.workspaceIds 引用了不存在的记录 ' + $id) } }
        $owners = @{}
        foreach ($prop in $rows.PSObject.Properties) {
          $wid = [string]$prop.Name
          $rec = $prop.Value
          if ($order.Count -gt 0 -and ($order -notcontains $wid)) { & $addWarn $name ('记录 ' + $wid + ' 不在 workspaceIds 顺序里') }
          if ($null -eq $rec) { & $addErr $name ($wid + ' 记录为空'); continue }
          foreach ($k in @('path', 'title')) {
            $kp = $rec.PSObject.Properties[$k]
            if (-not $kp -or $kp.Value -isnot [string]) { & $addErr $name ($wid + '.' + $k + ' 应为 string') }
          }
          foreach ($k in @('createdAt', 'updatedAt')) {
            $kp = $rec.PSObject.Properties[$k]
            $v = $null
            if ($kp) { $v = $kp.Value }
            # 注意：ConvertFrom-Json 会把 ISO-8601 字符串自动转成 [datetime]，所以这里
            # 不能只认 [string] —— [datetime] 说明原文就是合法 ISO 文本；数字才是 epoch。
            if ($v -is [datetime]) {
              # 原文是 ISO-8601 文本，PowerShell 已解析成功
            } elseif ($v -is [string]) {
              $parsed = [datetime]::MinValue
              if (-not ([datetime]::TryParse([string]$v, [ref]$parsed))) {
                & $addErr $name ($wid + '.' + $k + " 不是可解析的 ISO-8601 字符串：'" + [string]$v + "'")
              } elseif ([string]$v -notmatch '^\d{4}-\d{2}-\d{2}T') {
                & $addErr $name ($wid + '.' + $k + " 不是 ISO-8601（应以 yyyy-MM-ddT 开头）：'" + [string]$v + "'")
              }
            } else {
              & $addErr $name ($wid + '.' + $k + ' 必须是 ISO-8601 字符串；数字 epoch（' + [string]$v + '）会让整个 workspace 域 FAILED')
            }
          }
          $sp = $rec.PSObject.Properties['sessionIds']
          if (-not $sp -or $sp.Value -isnot [System.Array]) { & $addErr $name ($wid + '.sessionIds 应为字符串数组') }
          else {
            foreach ($sid in @($sp.Value)) {
              $sv = [string]$sid
              if ($owners.ContainsKey($sv)) { & $addErr $name ('会话 ' + $sv + ' 同时挂在 ' + $owners[$sv] + ' 与 ' + $wid) }
              else { $owners[$sv] = $wid }
            }
          }
        }
      }
    }
  }

  return [pscustomobject]@{
    ok = ($errors.Count -eq 0)
    checked = $files.Count
    errors = @($errors)
    warnings = @($warnings)
    files = @($files)
    summary = ('{0} 个文件，{1} 个错误，{2} 个警告' -f $files.Count, $errors.Count, $warnings.Count)
  }
}

# ---------------------------------------------------------------- Status

function Show-Status {
  Add-Phase 'start'
  Resolve-HostKind
  Add-Phase 'host-kind'
  $instances = @(Get-DshInstances)   # @() 强制成数组：函数返回空数组会被解包成 $null
  Add-Phase 'instances'
  # 第二轮采样（只补探，不重扫）：第一次采样命中 200 就早退，剩下的端口记成 unprobed。
  # 这些端口必须真的探一次 —— 否则「哪个端口是附件面」永远学不到，下次还是会撞上；
  # 但不必重扫 netstat/CIM，也不必重问已经确认的那一面。选面结论仍以第一次为准。
  if ($script:HostKind -eq 'desktop' -and $instances.Count -ge 1 -and @($instances[0].probe | Where-Object { $_.stage -eq 'unprobed' }).Count -gt 0) {
    $inst2 = @(Get-DesktopInstances -ProbeAll)
    Add-Phase 'instances-2'
    if ($inst2.Count -ge 1 -and [int]$inst2[0].port -gt 0) {
      # 合并成一行一个端口（第二轮的实测结果覆盖第一轮的 unprobed 占位）。
      # 别用 [ordered]@{} + 整数键：有序字典的键必须是字符串，用整数取会抛 ArgumentOutOfRange（实测）。
      $merged = @{}
      $orderPorts = @()
      foreach ($o in @($instances[0].probe)) {
        $k = [string][int]$o.port
        if (-not $merged.ContainsKey($k)) { $orderPorts += $k }
        $merged[$k] = $o
      }
      foreach ($o in @($inst2[0].probe)) {
        if ($o.stage -eq 'unprobed') { continue }
        $k = [string][int]$o.port
        if (-not $merged.ContainsKey($k)) { $orderPorts += $k }
        $merged[$k] = $o
      }
      $instances[0].probe = @($orderPorts | ForEach-Object { $merged[$_] })
    }
  }
  if ($script:HostKind -eq 'desktop' -and $instances.Count -ge 1 -and -not $script:ProfileExplicit -and $instances[0].profile) {
    $Profile = [string]$instances[0].profile
  }
  if ($script:HostKind -eq 'desktop' -and $instances.Count -ge 1 -and $instances[0].port -gt 0) {
    $Port = $instances[0].port
    $script:ResolvedPort = $Port
    $script:Desktop = $instances[0]
    $script:MainPid = $instances[0].mainPid
  }
  $cim = Get-CimAvailable
  Add-Phase 'cim'
  # 存储预检：只查 workspace.json（整份 zod 校验，最容易被外部脚本写坏）。只读、几十毫秒。
  $storage = $null
  try { $storage = Test-StoragePreflight -WorkspaceOnly } catch { $storage = $null }
  Add-Phase 'storage'
  $rec = Get-BootRecord
  $last = $null
  $hist = Get-StatePath 'restart-history.jsonl'
  if (Test-Path -LiteralPath $hist) {
    $line = Get-Content -LiteralPath $hist -Tail 1 -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($line) { try { $last = $line | ConvertFrom-Json } catch { } }
  }
  Add-Phase 'history'
  # 主面状态码：桌面版已经在 Resolve-HostPort 里探过（实例的 http 字段），这里不再问第二遍 ——
  # 以前这一行会对着同一个端口重发一次请求（3082 实测多花 1.6-2s）。
  # 实例的 http 只可能是 200/401/303/404/0，判据与 Test-HttpServing 完全一致。
  if ($script:HostKind -eq 'desktop' -and $instances.Count -ge 1) {
    $iHttp = [int]$instances[0].http
    $probe = [pscustomobject]@{
      status  = $iHttp
      serving = ($iHttp -ne 0)
      ready   = ($iHttp -eq 401 -or $iHttp -eq 200)
      authed  = ($iHttp -eq 200)
    }
  } else {
    # 只读动作走非交互探针：Test-HttpServing 走 .NET 请求栈并可能重试，宿主刚绑端口
    # 还没应答时会把一次 -Status 拖成数秒（面板每几秒轮询一次，直接叠成卡顿）。
    # Read-HostServing 是同一套判据（0/404/401/200）的单次原始 TCP 版本。
    $probe = Read-HostServing "http://${BindHost}:$Port/"
  }
  Add-Phase 'http-probe'
  # 访问地址优先读持久文件（url 步/上次 -Status 落盘），并校验 pid 与 token 是否属于当前实例：
  # 旧 boot 的地址一律不展示，宁可明确说「未知/过期」。
  $currentHostPids = @()
  foreach ($inst in $instances) { $currentHostPids += [int]$inst.pid }
  # 持久地址的端口必须在「这个实例现在真的在监听的端口」里：换端口之后记录里的端口属于上一个
  # 实例，去探它只会白等一个死端口（实测 1.5s 连接超时）。
  $livePorts = @()
  # web 分支的实例对象由 Get-HostCandidate 产出，只有 port，没有 ports；直接访问在
  # Set-StrictMode 2.0 下抛 PropertyNotFound，-Status 会以 "找不到属性 ports" 中止。
  foreach ($inst in $instances) { $livePorts += @($(if ($inst.PSObject.Properties['ports']) { $inst.ports } else { $inst.port })) }
  # 持久记录的 pid 对不上时也必须扫日志：重启后 web-auth-url.txt 里必然是上一代记录，
  # 而本次 boot 的 token 行就在被重定向（截断重写）的宿主日志里 —— 那正是要补写的场景。
  # 安全性不靠 pid 预筛，靠 Resolve-WebAuthUrl 里的带 token HTTP 探测（旧 token 必被拒）。
  $auth = Resolve-WebAuthUrl $currentHostPids -ProbePorts $livePorts
  Add-Phase 'auth-url'
  $script:HostUrl = $auth.Url
  $stUrl = $script:HostUrl
  # 注意：`$x = if (...) { @() } else { @() }` 里的**空数组会被解包成 $null**，
  # 于是后面的 $x.Count 抛 PropertyNotFoundException（只在「无实例」这条路上触发，
  # 实测过一次：dsh 没启动时 `-Status` 走到这里崩掉）。所以整个 if 表达式要再套一层 @()。
  $children = @(if ($script:HostKind -eq 'desktop') { @() } elseif ($instances.Count) { Get-ResidualChildren $instances[0].pid } else { @() })

  if ($Json -or $ResultFile) {
    # desktopApp：桌面版可执行文件的绝对路径（运行时解析：本次已解析 → 运行中实例 → 启动档案 →
    # 常见安装位置）。依赖它的外部工具（如 scripts\dsh-plugin-install.ps1）靠这一项推导安装根，不必自己猜。
    $desktopApp = ''
    if ($script:HostKind -eq 'desktop') {
      $resolved = Resolve-DesktopAppPath
      if ($resolved) { $desktopApp = [string]$resolved }
    }
    # 契约 §3.3：-Json 发一个固定信封（ok/result/exitCode/version/steps/warnings/
    # targetPid/newPid/hostUrl/error/durationMs/stateDir/logPath）；status 动作还必须把
    # 旧 -Status -Json 的富对象**原样**放在 `status` 键下 —— 那是既有的可脚本化接口，
    # 字段名与层级一律不动（消费方直接读 status.instances / status.http，不从 steps 反推）。
    # -ResultFile 也要这份：否则同一进程「写文件」与「打 stdout」会是两种形状。
    $script:Extra['status'] = [ordered]@{
      version    = $script:VERSION
      dshHome    = $DshHome
      stateDir   = $StateDir
      profile    = $Profile
      port       = $Port
      hostKind   = [string]$script:HostKind
      # 形态是怎么判出来的：冷启动判错是最贵的一类错误，必须能从 -Status 反查推理来源。
      hostKindSource = [string]$script:HostKindSource
      # 有没有引擎正在做事：活动台账。ageSec 很大或文件缺失 = 没人在跑（不是卡死）。
      activity = $(try {
          $ap = Get-ActivityPath
          if (-not (Test-Path -LiteralPath $ap -PathType Leaf)) { $null } else {
            $a = Get-Content -LiteralPath $ap -Raw -Encoding UTF8 | ConvertFrom-Json
            $age = 0
            try { $age = [int]((Get-Date) - [datetime]$a.updatedAt).TotalSeconds } catch { $age = -1 }
            $alive = Test-ActivityProcessAlive $a
            [ordered]@{ pid = [int]$a.pid; step = [string]$a.step; note = [string]$a.note;
                        action = [string]$a.action; ageSec = $age; processAlive = $alive;
                        elapsedSec = $a.elapsedSec; updatedAt = $a.updatedAt }
          }
        } catch { $null })
      desktopApp = $desktopApp
      desktopAppSource = [string]$script:DesktopAppPathSource
      runtimeDir = $(if ($desktopApp) { (Get-DesktopPaths $desktopApp).runtimeDir } else { '' })
      appRoot    = $(if ($desktopApp) { (Get-DesktopPaths $desktopApp).appRoot } else { '' })
      pnpm       = $(if ($desktopApp) { (Get-DesktopPaths $desktopApp).pnpm } else { Resolve-GlobalPnpm })
      # 实际存在的那个 pnpm.mjs：官方布局在 resources\runtime 下，解包后桥把 pnpm 放在
      # resources\app\runtime 下 —— 两种都验一遍再报，外部工具直接用，不必自己拼分支。
      # 没有 DSH Desktop（npm 全局安装的 `dsh web`）时退回到全局 pnpm.mjs，否则
      # install_plugin 会以「找不到 pnpm.mjs」失败。
      pnpmResolved = $(if ($desktopApp) { $dp = Get-DesktopPaths $desktopApp; Resolve-FirstPath @($dp.pnpm, $dp.pnpmFallback) } else { Resolve-GlobalPnpm })
      cliCmd     = $(if ($desktopApp) { $dp2 = Get-DesktopPaths $desktopApp; Resolve-FirstPath @($dp2.cliCmd, $dp2.cliCmdFallback) } else { '' })
      nodeExe    = $(if ($script:HostKind -eq 'desktop') { (Get-DesktopNodeExe) } else { '' })
      configuredPort = [int]$script:ConfiguredPort
      resolvedPort   = [int]$Port
      portSource     = $(if ($script:HostKind -eq 'desktop') { 'netstat' } else { 'config' })
      instanceShape  = $(if ($script:HostKind -eq 'desktop') { 'desktop-host' } else { 'web-node' })
      mainPid        = $(if ($script:HostKind -eq 'desktop' -and $instances.Count -ge 1) { [int]$instances[0].mainPid } else { $null })
      url        = "http://${BindHost}:$Port/"
      launchUrl  = $stUrl
      launchUrlState = $auth.State
      launchUrlDetail = $auth.Detail
      http       = $probe.status
      serving    = $probe.serving
      cimOk      = $cim
      instances  = @($instances)
      nodeChildren = @($children)
      bootRecord = $rec
      lastRestart = $last
      # 存储体检：ok=false 表示下一次宿主启动 workspace 域会整份 FAILED（侧栏工作区变空）
      storage    = $storage
      marker     = $(try { Get-Content (Join-Path $DshHome '.smart-restart\marker.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null })
    }
    # 信封里这两个字段在只读动作下同样有确切含义：targetPid=当前监听者、hostUrl=已校验地址
    if ($instances.Count -ge 1) { $script:TargetPid = $instances[0].pid }
    if ($auth.State -ne 'ok') { [void]$script:Warn.Add('launchUrl: ' + $auth.Detail) }
    if ($storage -and -not $storage.ok) {
      [void]$script:Warn.Add('storage: workspace.json 预检失败（' + $storage.errors[0].message + '）→ 下一次宿主启动 workspace 域会 FAILED')
    }
  }
  if ($Json) { return }

  Write-Diag "dsh-restart $($script:VERSION) — 只读状态" -ForegroundColor Cyan
  Write-Diag ("  DSH_HOME    : {0}" -f $DshHome)
  Write-Diag ("  状态目录    : {0}" -f $StateDir)
  Write-Diag ("  宿主形态    : {0}" -f $(if ($script:HostKind -eq 'desktop') { "DSH Desktop（Electron 主进程 pid=$($script:MainPid)，端口实测 $Port / 配置 $($script:ConfiguredPort)）" } else { "web（dsh web，端口 $Port）" }))
  Write-Diag ("  目标        : profile={0}  http://{1}:{2}/" -f $Profile, $BindHost, $Port)
  Write-Diag ("  HTTP        : {0} {1}" -f $probe.status, $(if ($probe.serving) { '(服务中)' } else { '(无响应)' }))
  if ($stUrl) { Write-Diag ("  访问地址    : {0}  （持久文件 {1}）" -f $stUrl, (Get-WebAuthUrlPath)) -ForegroundColor Green }
  else { Write-Diag ("  访问地址    : 未知/过期（{0}）" -f $auth.Detail) -ForegroundColor Yellow }
  $mk = $null
  try { $mk = Get-Content (Join-Path $DshHome '.smart-restart\marker.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  if ($mk) { Write-Diag ("  marker.json : pid={0} lastBootAt={1} ver={2}" -f $mk.pid, $mk.lastBootAt, $mk.dshVersion) }
  Write-Diag ("  进程发现    : {0}" -f $(if ($cim) { 'CIM 可用' } else { 'CIM 不可用（沙箱/权限）→ 以端口监听者为权威' }))
  if ($storage) {
    Write-Diag ("  存储预检    : {0}" -f $storage.summary) -ForegroundColor $(if ($storage.ok) { 'Gray' } else { 'Red' })
    if (-not $storage.ok) {
      foreach ($e in @($storage.errors | Select-Object -First 3)) { Write-Diag ("      {0}: {1}" -f $e.file, $e.message) -ForegroundColor Red }
    }
  }
  if ($instances.Count -eq 0) {
    Write-Diag ("  实例        : 无（{0}）" -f $(if ($script:HostKind -eq 'desktop') { '未发现 DSH Desktop 宿主子进程' } else { "端口 $Port 无监听者" })) -ForegroundColor Yellow
  }
  else {
    Write-Diag "  实例        :"
    foreach ($i in $instances) {
      Write-Diag ("     pid={0,-7} {1,-6} 内存={2}MB 句柄={3} 启动={4} 角色={5}" -f $i.pid, $i.name, $i.ws_mb, $i.handles, $i.start, $i.source)
    }
  }
  if ($children.Count) {
    Write-Diag ("  node 子进程 : {0} 个，共 {1}MB" -f $children.Count, (($children | Measure-Object ws_mb -Sum).Sum))
  } else { Write-Diag "  node 子进程 : 无（或不可枚举）" }
  Write-Diag ("  启动档案    : {0}" -f $(if ($rec) { "$($rec.command)  (cwd=$($rec.cwd))" } else { '(未记录，将用内置 DEFAULT_LAUNCH)' }))
  # 有没有人在跑：这是「点了没反应」和「正在干活」的唯一分界线，必须打在人读输出的最前面。
  try {
    $ap = Get-ActivityPath
    if (Test-Path -LiteralPath $ap -PathType Leaf) {
      $a = Get-Content -LiteralPath $ap -Raw -Encoding UTF8 | ConvertFrom-Json
      $age = 0
      try { $age = [int]((Get-Date) - [datetime]$a.updatedAt).TotalSeconds } catch { $age = -1 }
      $alive = Test-ActivityProcessAlive $a
      $stateText = if ($alive -and $age -ge 0 -and $age -le 90) {
        "进行中：$($a.action) 的 $($a.step)，已跑 $($a.elapsedSec)s，$($age)s 前还在动（pid=$($a.pid)）"
      } elseif ($alive) {
        "进程 pid=$($a.pid) 还在，但 $($age)s 没推进（停在 $($a.step)）—— 多半是卡住了，可用 -Stop 或结束该 pid"
      } else {
        "没有正在进行的动作（上一次是 $($a.action) 的 $($a.step)，$($age)s 前，进程已退出）"
      }
      $color = if ($alive -and $age -le 90) { 'Green' } elseif ($alive) { 'Yellow' } else { 'Gray' }
      Write-Diag ("  当前动作    : {0}" -f $stateText) -ForegroundColor $color
    } else {
      Write-Diag "  当前动作    : 无（没有引擎在跑）"
    }
  } catch { Write-Diag "  当前动作    : 读不到活动台账" }
  Write-Diag ("  宿主判据    : {0}" -f $(if ($script:HostKindSource) { $script:HostKindSource } else { '(未记录)' }))
  Write-Diag ("  最近一次重启: {0}" -f $(if ($last) { "$($last.ts) result=$($last.result) rc=$($last.rc) 旧pid=$($last.target_pid) 新pid=$($last.new_pid)" } else { '(无记录)' }))

  # 托管形态判定（R13）
  # 原来分两段打（前缀 -NoNewline + 判定），现在拼成一行再输出：诊断统一走 Write-Diag，
  # 而它没有 -NoNewline。
  $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'dsh' }
  # schtasks 查不到任务时会往 stderr 写一行「ERROR: …」，5.1 下那会被当成终结性错误直接
  # 抛出来（$ErrorActionPreference='Stop' + 原生命令 stderr）—— -Status 因此整行 abort。
  # 这里显式把 stderr 收掉、失败当「没有任务」，与既有语义一致。
  $task = $null
  try { $task = (& (Get-SystemTool 'schtasks') /Query /TN $TaskName /FO LIST 2>&1 | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) } catch { $task = $null }
  $hosting = if ($svc) { " Windows 服务 $($svc.Name -join ',')" }
             elseif ($task) { " 计划任务 '$TaskName' 已注册（可脱离 DSH 进程树，P1）" }
             else { " 未被托管 → 用计划任务 /Run 脱离（P1），兜底 WMI（P2）" }
  if ($svc -or $task) { Write-Diag ("  托管形态    :" + $hosting) }
  else { Write-Diag ("  托管形态    :" + $hosting) -ForegroundColor Yellow }
  Write-Diag ("  smart-restart: 插件已装={0}" -f (Test-Path (Join-Path $DshHome ("profiles\$Profile\node_modules\dsh-smart-restart"))))

  # 提权状态：直接决定「能不能停掉宿主」（Windows 不允许未提升进程杀已提升进程）
  $elev = Test-Elevation
  $elevText = if (-not $elev.ok) { '未知' } elseif ($elev.elevated) { '已提升（Full）' } else { '未提升（Default）' }
  $elevColor = if ($elev.ok -and -not $elev.elevated) { 'Yellow' } else { 'Gray' }
  Write-Diag ("  当前令牌    : {0}  → {1}" -f $elevText,
    $(if ($elev.ok -and -not $elev.elevated) { '若宿主是提升启动的，停机将 Access is denied；请用管理员窗口或 -ViaTask' } else { '可终止同等或更低完整性的宿主' })) -ForegroundColor $elevColor
}

function Invoke-RescueLaunch([string]$Cause) {
  <#
    抢救拉起（P3）：只在「中止发生在旧实例已停之后」被 catch 调用。
    为什么必须有：本脚本的承诺是「安全重启」，而中止落在停机之后意味着机器被留在
    「DSH 已停」——端口空着、链接打不开，正是最不能接受的结果。
    设计约束：
      ① 端口已有监听者 → 绝不再拉第二个（避免双实例），直接判定已恢复；
      ② 只尝试一次，失败就如实报错并给出可复制的拉起命令（不掩盖、不循环）；
      ③ 自身出错也必须吞掉并转成失败步骤（它已经在 catch 里，再抛就没人接了）。
    返回 $true = 服务已恢复（或本来就有服务）。
  #>
  try {
    if ($script:HostKind -eq 'desktop') {
      $live = @(Get-DesktopInstances -Refresh)
      if ($live.Count -gt 0) {
        Add-Step 'rescue' "中止发生在停机之后，但机器上已有 DSH Desktop 宿主（main pid=$($live[0].mainPid) 端口=$($live[0].port)）→ 不再重复拉起" 'warn'
        return $true
      }
    } elseif (Test-PortListening $Port) {
      Add-Step 'rescue' "中止发生在停机之后，但端口 $Port 已有监听者（pid=$(@(Get-PortOwner $Port) -join ',')）→ 不再重复拉起" 'warn'
      return $true
    }
    $plan = Resolve-Launch
    if (-not (Test-LaunchPrereq $plan.raw $plan.cwd)) {
      Add-Step 'rescue' '抢救拉起的前置检查未通过 → 无法自动恢复，请手工执行启动命令' 'fail'
      return $false
    }
    Add-Step 'rescue' "中止发生在停机之后（$Cause）→ 尽力拉起一次，避免把机器留在停机态" 'warn'
    $p = Start-DshInstance
    if (-not $p) {
      Add-Step 'rescue' "抢救失败：拉起未返回进程对象；请手工执行：$($plan.raw)" 'fail'
      return $false
    }
    $r = Wait-HostReady $p.Id $Port $ReadySec $(try { $p.StartTime } catch { $null })
    if ($r -and $r.ok) {
      $script:HostUrl = Wait-NewHostToken $script:HostOutPath 8000
      if ($script:HostUrl) { [void](Save-WebAuthUrlRecord $script:HostUrl ([int]$script:NewPid) 'rescue 步（token 变化判据）') }
      Add-Step 'rescue' "抢救成功：宿主已恢复 pid=$($script:NewPid) 端口=$Port" 'ok'
      return $true
    }
    # 抢救也失败：必须自己收干净，别留半残实例（与主流程 exit 8 的 R20 回收同义）
    $killPids = @()
    if ($script:NewPid) { $killPids += $script:NewPid }
    if ($p.Id -ne $script:NewPid) { $killPids += $p.Id }
    foreach ($kp in $killPids) { & (Get-SystemTool 'taskkill') /PID $kp /T /F *> $null }
    Add-Step 'rescue' "抢救未成功（$(if ($r) { $r.reason } else { '无返回' })）：已回收本次尝试的实例（$($killPids -join ',')）；宿主仍为停机态；请手工执行：$($plan.raw)" 'fail'
    return $false
  } catch {
    Add-Step 'rescue' "抢救过程自身出错：$($_.Exception.Message)；请手工执行：dsh web --no-open --host 127.0.0.1 --port $Port" 'fail'
    return $false
  }
}


# ---------------------------------------------------------------- 共享投影（profiles\node_modules）

function Get-SharedScopePath { return (Join-Path $DshHome 'profiles\node_modules') }

function Test-SharedScope {
  <#
    桌面宿主解析 @deepseek-ai/* 用的是 <DSH_HOME>\profiles\node_modules（app.asar\dsh\node_modules 的投影），
    不是 asar 本身。2026-11-15 实测：这份投影被删掉后，App 每次新启动的宿主都会 177 个基础包全部
    ERR_MODULE_NOT_FOUND，App 直接打不开（且用全新 profile 复现，容易误判成 profile 损坏）。
    判据用两个“必需的基石包”，缺一即视为投影不完整。
  #>
  $root = Get-SharedScopePath
  foreach ($pkg in @('dsh-base', 'dsh-web-app')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root ('@deepseek-ai\' + $pkg + '\package.json')))) { return $false }
  }
  return $true
}

function Read-AsarIndex([string]$AsarPath) {
  $fs = [System.IO.File]::OpenRead($AsarPath)
  try {
    $br = New-Object System.IO.BinaryReader($fs)
    [void]$br.ReadUInt32()
    $headerSize = [int64]$br.ReadUInt32()
    [void]$br.ReadUInt32()          # 第三个 uint32 与 jsonLen 同值，占位
    $jsonLen = [int]$br.ReadUInt32()  # 第四个才是 JSON 长度（asar 头部：4, headerSize, len, len）
    $fs.Position = 16
    $json = [System.Text.Encoding]::UTF8.GetString($br.ReadBytes($jsonLen))
    return [pscustomobject]@{ DataStart = (8 + $headerSize); Index = ($json | ConvertFrom-Json) }
  } finally { $fs.Dispose() }
}

function Expand-AsarTree {
  <# 把 asar 里的一个子树写到磁盘（已存在且大小相同的文件跳过 → 修复可增量、可重入）。 #>
  param($Node, [string]$RelPath, [string]$OutDir, $Stream, [int64]$DataStart, [string]$UnpackedRoot, [ref]$Stats)
  if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
  foreach ($prop in $Node.PSObject.Properties) {
    $name = $prop.Name
    $ent = $prop.Value
    $childRel = if ($RelPath) { $RelPath + '/' + $name } else { $name }
    $childOut = Join-Path $OutDir $name
    if ($ent.PSObject.Properties['files']) {
      Expand-AsarTree -Node $ent.files -RelPath $childRel -OutDir $childOut -Stream $Stream -DataStart $DataStart -UnpackedRoot $UnpackedRoot -Stats $Stats
      continue
    }
    if ($ent.PSObject.Properties['link']) { $Stats.Value.Links++; continue }
    $size = 0
    if ($ent.PSObject.Properties['size']) { $size = [int64]$ent.size }
    if ((Test-Path -LiteralPath $childOut) -and ((Get-Item -LiteralPath $childOut).Length -eq $size)) { $Stats.Value.Skipped++; continue }
    try {
      if ($ent.PSObject.Properties['unpacked'] -and $ent.unpacked) {
        $src = Join-Path $UnpackedRoot ($childRel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $src)) { $Stats.Value.Missing++; continue }
        Copy-Item -LiteralPath $src -Destination $childOut -Force
        $Stats.Value.Unpacked++
      } else {
        $parent = Split-Path -Path $childOut -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        $Stream.Position = $DataStart + [int64]$ent.offset
        $buf = New-Object byte[] $size
        $read = 0
        while ($read -lt $size) {
          $n = $Stream.Read($buf, $read, [int]($size - $read))
          if ($n -le 0) { break }
          $read += $n
        }
        [System.IO.File]::WriteAllBytes($childOut, $buf)
        $Stats.Value.Files++
      }
      $Stats.Value.Bytes += $size
    } catch {
      $Stats.Value.Errors++
      Write-Audit 'warn' "共享投影：写入失败 $childRel :: $($_.Exception.Message.Split([char]10)[0])"
    }
  }
}

function Repair-SharedScope {
  <# 从已安装的 app.asar 重建 <DSH_HOME>\profiles\node_modules。返回 @{ ok; stats; reason }。 #>
  $exe = Resolve-DesktopAppPath
  if (-not $exe) { return [pscustomobject]@{ ok = $false; reason = 'desktop-app-missing' } }
  $paths = Get-DesktopPaths $exe
  $root = Get-SharedScopePath
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $stats = [pscustomobject]@{ Files = 0; Unpacked = 0; Skipped = 0; Links = 0; Missing = 0; Errors = 0; Bytes = [int64]0 }
  $stream = $null
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  if (-not (Test-Path -LiteralPath $paths.asar -PathType Leaf)) {
    # unpacked 布局（bridge/补丁工具把 asar 解开了）：直接复制真实目录，比解 asar 更快
    $srcNm = Join-Path $paths.runtimeDir 'node_modules'
    if (-not (Test-Path -LiteralPath $srcNm -PathType Container)) {
      $sw.Stop()
      return [pscustomobject]@{ ok = $false; reason = 'desktop-runtime-missing'; stats = $stats }
    }
    try {
      & (Get-SystemTool 'robocopy') $srcNm $root /E /NFL /NDL /NJH /NJS /NP /R:2 /W:1 *> $null
      $stats.Files = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue).Count
      $stats.Bytes = [int64]((Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
    } catch {
      $sw.Stop()
      return [pscustomobject]@{ ok = $false; reason = ('copy-failed: ' + $_.Exception.Message.Split([char]10)[0]); stats = $stats }
    }
    $sw.Stop()
    return [pscustomobject]@{ ok = (Test-SharedScope); stats = $stats; reason = 'copied'; elapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
  }
  try {
    $asar = Read-AsarIndex $paths.asar
    $dshNode = $asar.Index.files.dsh
    if ($null -eq $dshNode) { return [pscustomobject]@{ ok = $false; reason = 'asar-layout-unknown' } }
    $stream = [System.IO.File]::OpenRead($paths.asar)
    $nmNode = $dshNode.files.node_modules
    if ($null -eq $nmNode) { return [pscustomobject]@{ ok = $false; reason = 'asar-node-modules-missing' } }
    $ref = [ref]$stats
    Expand-AsarTree -Node $nmNode.files -RelPath 'node_modules' -OutDir $root -Stream $stream -DataStart $asar.DataStart -UnpackedRoot (Join-Path (Split-Path $paths.asar -Parent) 'app.asar.unpacked\dsh') -Stats $ref
  } catch {
    return [pscustomobject]@{ ok = $false; reason = ('extract-failed: ' + $_.Exception.Message.Split([char]10)[0]); stats = $stats }
  } finally {
    if ($stream) { $stream.Dispose() }
  }
  $sw.Stop()
  return [pscustomobject]@{ ok = (Test-SharedScope); stats = $stats; reason = 'extracted'; elapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

function Backup-ProfileConfig {
  <# 重启前把用户的 cordis.patch.yml 留一份（保留最近 5 份）——配置管理器重写文件时不至于无迹可寻。 #>
  if (-not $Profile) { return }
  $src = Join-Path $DshHome ('profiles\' + $Profile + '\cordis.patch.yml')
  if (-not (Test-Path -LiteralPath $src)) { return }
  try {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dst = $src + '.bak-dsh-restart-' + $stamp
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $keep = @(Get-ChildItem -LiteralPath (Split-Path $src -Parent) -Filter 'cordis.patch.yml.bak-dsh-restart-*' -File |
      Sort-Object LastWriteTime -Descending | Select-Object -Skip 5)
    foreach ($old in $keep) { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue }
  } catch {
    Write-Audit 'warn' ("配置备份失败：" + $_.Exception.Message.Split([char]10)[0])
  }
}



function Repair-ShadowedBasePackages {
  <#
    第三方插件会把 @deepseek-ai/* 作为依赖装进 profile 的 node_modules（pnpm 提升到顶层），
    从而**遮蔽** App 自带的基础包。实测：profile 里出现 @deepseek-ai/dsh-settings@0.1.0-rc.8
    （App 是 0.2.2-rc.3）→ settings 服务永远不注册 → 依赖它的 6 个插件全部 PENDING →
    欢迎窗口的 settings RPC 失败，App 显示「无法使用 / Web RPC failed」。
    这里把版本与共享投影不一致的基础包移进 .stale-packages（可回溯），让解析落回 App 自带版本。
  #>
  $shared = Join-Path $DshHome 'profiles\node_modules\@deepseek-ai'
  if (-not (Test-Path -LiteralPath $shared)) { return [pscustomobject]@{ ok = $false; moved = @(); reason = 'shared-scope-missing' } }
  $nm = Join-Path $DshHome ('profiles\' + $Profile + '\node_modules\@deepseek-ai')
  $moved = New-Object System.Collections.ArrayList
  if (Test-Path -LiteralPath $nm) {
    $stale = Join-Path $DshHome ('profiles\' + $Profile + '\.stale-packages')
    New-Item -ItemType Directory -Force -Path $stale | Out-Null
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    foreach ($dir in @(Get-ChildItem -LiteralPath $nm -Directory -ErrorAction SilentlyContinue)) {
      $sharedPkg = Join-Path $shared ($dir.Name + '\package.json')
      $localPkg = Join-Path $dir.FullName 'package.json'
      if (-not (Test-Path -LiteralPath $sharedPkg) -or -not (Test-Path -LiteralPath $localPkg)) { continue }
      $lv = ''; $sv = ''
      try {
        $lv = [string](Get-Content -LiteralPath $localPkg -Raw -Encoding UTF8 | ConvertFrom-Json).version
        $sv = [string](Get-Content -LiteralPath $sharedPkg -Raw -Encoding UTF8 | ConvertFrom-Json).version
      } catch { continue }
      if (-not $lv -or -not $sv -or $lv -eq $sv) { continue }
      $dst = Join-Path $stale ($dir.Name + '-' + $lv + '-' + $stamp)
      try {
        Move-Item -LiteralPath $dir.FullName -Destination $dst -Force -ErrorAction Stop
        [void]$moved.Add(($dir.Name + '@' + $lv + ' -> ' + $sv))
      } catch { }
    }
  }
  return [pscustomobject]@{ ok = $true; moved = @($moved.ToArray()); reason = 'checked' }
}

# ---------------------------------------------------------------- DSH Desktop（Electron 宿主）
#
# 与 `dsh web` 的四处硬差异（本机实测 2026-11-14，DSH 0.2.2-rc.3）：
#   ① 宿主不是 node.exe，而是 Electron 主进程 spawn 的 Node 模式子进程：进程名
#      `DeepSeek Harness.exe`，命令行含 `...\app.asar\dsh\node_modules\@deepseek-ai\
#      dsh-desktop-host\lib\index.js`（`--expose-internals` 打头），父进程是 Electron 主进程；
#   ② 它用 `--port 0` 启动，端口每次随机 → 端口不是配置，必须用 netstat 反查；
#   ③ 真正的「关闭」是杀 Electron 主进程整棵树；只杀宿主子进程会把壳留在 host crash 状态；
#   ④ 单实例锁：再启动 exe 只会聚焦旧窗口 → 深度验证必须直接起宿主入口，不能靠「再开一个 App」。
# 这四条就是 desktop 分支的全部依据；web 分支的语义一字未改。

function Get-SystemTool([string]$Name) {
  <#
    系统工具一律用绝对路径：只用裸名字时，调用方的 PATH 是唯一线索 —— git-bash / MSYS、
    精简 PATH 的计划任务、或 PATH 里塞了同名的 unix 工具时，netstat/taskkill 会解析到别的程序
    或直接找不到（实测：宿主被停后引擎判成 web，再去 netstat 反查就什么都查不到）。
    顺序：System32 → 找不到就用裸名（保持老行为）。
  #>
  $cand = Join-Path $env:SystemRoot ('System32\' + $Name + '.exe')
  if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
  return ($Name + '.exe')
}

function Get-NetstatListenerRows {
  <#
    一次 netstat 扫描，解析成 @{ port; pid; host } 行。整个进程只该在这里调 netstat：
    以前 Get-ListeningPorts 每调一次就重扫整张表，一次 -Status 里要扫两三遍，
    本机实测单次 ~200ms（408 行），端口候选一多，耗时全落在「等 netstat」上。
    解析只看本地地址段的最后一个冒号，IPv6 的 [::]:port 同样成立。
    进程内缓存 $MaxAgeMs（默认 3s）：一次 -Status 里 discovery / 探测 / 复检各要一份端口表，
    原来每一处都重扫一遍，三次 netstat 就是三个 ~200ms。缓存过期或被显式 -Refresh 踩掉才重扫。
  #>
  param([int]$MaxAgeMs = 3000, [switch]$Refresh)
  if (-not $Refresh -and $null -ne $script:NetstatRows -and @($script:NetstatRows).Count -ge 0 -and $script:NetstatStamp) {
    if (((Get-Date) - $script:NetstatStamp).TotalMilliseconds -lt $MaxAgeMs) { return @($script:NetstatRows) }
  }
  $rows = New-Object System.Collections.ArrayList
  foreach ($r in @(& (Get-SystemTool 'netstat') -ano -p TCP 2>$null | Select-String 'LISTENING')) {
    if (-not $r -or -not $r.Line) { continue }
    $t = @((([string]$r.Line) -split '\s+') | Where-Object { $_ -ne '' })
    if ($t.Count -lt 5) { continue }
    $local = [string]$t[1]
    $idx = $local.LastIndexOf(':')
    if ($idx -lt 1) { continue }
    $p = 0
    if (-not [int]::TryParse($local.Substring($idx + 1), [ref]$p)) { continue }
    $owner = 0
    if (-not [int]::TryParse([string]$t[-1], [ref]$owner)) { continue }
    [void]$rows.Add([pscustomobject]@{
      port = $p
      pid  = $owner
      host = $local.Substring(0, $idx)
    })
  }
  $script:NetstatRows = @($rows.ToArray())
  $script:NetstatStamp = Get-Date
  return $script:NetstatRows
}

function Get-ListeningPorts([int]$Pid_, $Rows = $null) {
  # 反查某个 pid 的 LISTENING 端口（netstat 是权威；Get-NetTCPConnection 在沙箱下不可靠）。
  # $Rows 可传入 Get-NetstatListenerRows 的结果，避免在循环里反复扫描同一张表。
  if ($null -eq $Rows) { $Rows = Get-NetstatListenerRows }
  $out = New-Object System.Collections.ArrayList
  foreach ($row in @($Rows)) {
    if ([int]$row.pid -ne $Pid_) { continue }
    [void]$out.Add([int]$row.port)
  }
  return @($out | Sort-Object -Unique)
}

function Get-ProcessIndex {
  <#
    一次 CIM 全表换成按 pid 查的字典。以前每个候选宿主都要单独
    Get-CimInstance -Filter "ProcessId=…"（有的路径一轮查好几个），加起来就是秒级。
    与端口表一样做进程内缓存（默认 3s），-Refresh 强制重取。

    默认**不取** CommandLine：本机实测 520 个进程里带上命令行要 ~250-373ms，去掉只要 ~133ms，
    而大多数调用点只看「父进程是谁、exe 在哪」。需要命令行的调用点显式 -WithCommandLine
    （同一 TTL 内会被复用，不会为同一个问题去问两遍 CIM）。
  #>
  param([int]$MaxAgeMs = 3000, [switch]$Refresh, [switch]$WithCommandLine)
  $fresh = $false
  if ($script:ProcStamp -and ((Get-Date) - $script:ProcStamp).TotalMilliseconds -lt $MaxAgeMs) { $fresh = -not $Refresh }
  if ($fresh -and $null -ne $script:ProcIndex -and ($script:ProcHasCmd -or -not $WithCommandLine)) { return $script:ProcIndex }
  $map = @{}
  $gotCmd = $false
  if ($WithCommandLine) {
    foreach ($pr in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) { $map[[int]$pr.ProcessId] = $pr }
    $gotCmd = $true
  } else {
    # 不带 -CommandLine 的查询省掉最多的那一段开销（~240ms）
    foreach ($pr in @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name,ExecutablePath,CreationDate -ErrorAction SilentlyContinue)) {
      $map[[int]$pr.ProcessId] = $pr
    }
  }
  $script:ProcIndex = $map
  $script:ProcHasCmd = $gotCmd
  $script:ProcStamp = Get-Date
  return $map
}

function Find-DesktopHostRows {
  <#
    一次 WMI 查询拿回「命令行像宿主的行」，同一进程内复用（-Refresh 才重问）。
    注意不是「同一次调用内永久缓存」：等待循环里宿主集会变，那边传 -Refresh。
  #>
  param([switch]$Refresh)
  if (-not $Refresh -and $null -ne $script:HostRows) { return @($script:HostRows) }
  $rows = @()
  # 带命令行的查询（~270ms 首次）比按名字查（~110ms）+ 逐个取命令行（~110ms/个）都便宜：
  # 名字不稳定（改名的壳），而逐个取命令行在 500 个进程上就是几十秒。
  try { $rows = @(Get-CimInstance Win32_Process -ErrorAction Stop) } catch { $rows = @() }
  if ($rows.Count -eq 0) {
    # 全表失败时退回服务端筛（WMI 有过滤器上限，但这条路至少能活）
    try { $rows = @(Get-CimInstance Win32_Process -Filter "CommandLine LIKE '%dsh-desktop-host%'" -ErrorAction Stop) } catch { $rows = @() }
  }
  $script:HostRows = @($rows)
  return @($rows)
}

function Get-DesktopHostProcesses {
  param([switch]$Refresh)
  <#
    命令行含 dsh-desktop-host\lib\index.js 的进程 = 桌面版宿主子进程。
    恒返回数组；CIM 不可用/查不到时返回空数组（由调用方按 web 处理或明确报错）。

    发现放在 WMI 服务端做：一条 CommandLine LIKE 让 WMI 只回那几行，不再把 500+ 个进程的
    完整命令行拉进 PowerShell 再筛（本机实测：全表带命令行 ~250-373ms，服务端筛完只要 ~120ms）。
    过滤器只筛一段**不带反斜杠的**字面量（'%dsh-desktop-host%'）：WQL 的 LIKE 里反斜杠要写四层
    才等于一层，写错会静默返回 0 行（实测踩到）。完整路径的严格判定交给下面的正则。
    不按进程名写死（官方壳叫 DeepSeek Harness.exe，改名的壳同样要认出来）。
  #>
  $out = New-Object System.Collections.ArrayList
  if (-not (Get-CimAvailable)) { return @() }
  # 每次调用只问一次：-Status 里 Resolve-HostKind / Resolve-DesktopProfileName / 实例发现
  # 都会问「宿主在哪」，一次 130ms 的 WMI 查询问三遍就是 400ms。
  $script:HostHits = @(Find-DesktopHostRows -Refresh:$Refresh)
  foreach ($p in @($script:HostHits)) {
    $cmd = [string]$p.CommandLine
    if (-not $cmd) { continue }
    if ($cmd -notmatch 'dsh-desktop-host[\\/]lib[\\/]index\.js') { continue }
    # Electron 主进程判定：渲染/GPU/工具进程的命令行都带 --type=
    if ($cmd -match '--type=') { continue }
    # CreationDate 是「这个子进程是不是本次启动生出来的」的硬判据：父进程 pid 在父退出后会被
    # 别的进程复用，而 CreationDate 不会说谎。WMI 的 CreationDate 是 DMTF 字符串，直接转 DateTime。
    $born = $null
    try {
      if ($p.CreationDate) {
        $born = if ($p.CreationDate -is [datetime]) { $p.CreationDate } else { [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$p.CreationDate) }
      }
    } catch { $born = $null }
    [void]$out.Add([pscustomobject]@{
      pid         = [int]$p.ProcessId
      name        = [string]$p.Name
      mainPid     = [int]$p.ParentProcessId
      createdAt   = $born
      commandLine = $cmd
    })
  }
  return @($out.ToArray())
}

function Resolve-GlobalPnpm {
  # 没有 DSH Desktop 布局时（npm 全局安装的 `dsh web`），pnpm 只存在于 npm 全局目录；
  # 引擎原先只认 Desktop 的 resources\runtime，install_plugin 因此报「找不到 pnpm.mjs」。
  $candidates = @(
    (Join-Path $env:APPDATA 'npm\node_modules\pnpm\bin\pnpm.mjs'),
    (Join-Path $env:ProgramFiles 'nodejs\node_modules\pnpm\bin\pnpm.mjs')
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
  }
  return ''
}

function Get-DesktopPaths([string]$MainPath) {
  # 桌面版的目录形状（全部从可执行文件位置推导，不猜安装路径）。
  # 两种布局都要支持：
  #   asar     ：resources\app.asar 是文件，运行时代码在 asar 里（官方原版）
  #   unpacked ：resources\app\dsh 是真实目录（bridge/补丁工具会把 asar 解开，
  #              2026-11-18 本机实测：app.asar 被改名为 app.asar.before-bridge，宿主从 resources\app\dsh 启动）
  $appRoot  = Split-Path -Path $MainPath -Parent
  $asar     = Join-Path $appRoot 'resources\app.asar'
  $unpacked = Join-Path $appRoot 'resources\app\dsh'
  $runtimeDir = $null
  if (Test-Path -LiteralPath $asar -PathType Leaf) {
    $runtimeDir = Join-Path $appRoot 'resources\app.asar\dsh'
  } elseif (Test-Path -LiteralPath $unpacked -PathType Container) {
    $runtimeDir = $unpacked
  } else {
    $runtimeDir = Join-Path $appRoot 'resources\app.asar\dsh'
  }
  return [pscustomobject]@{
    exe            = $MainPath
    appRoot        = $appRoot
    runtimeDir     = $runtimeDir
    entry          = (Join-Path $runtimeDir 'node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js')
    asar           = $asar
    unpacked       = $unpacked
    layout         = $(if (Test-Path -LiteralPath $asar -PathType Leaf) { 'asar' } elseif (Test-Path -LiteralPath $unpacked -PathType Container) { 'unpacked' } else { 'unknown' })
    primaryRuntime = (Join-Path $appRoot 'resources\runtime\primary-runtime')
    pnpm           = (Join-Path $appRoot 'resources\runtime\primary-runtime\dependencies\pnpm\bin\pnpm.mjs')
    pnpmFallback   = (Join-Path $appRoot 'resources\app\runtime\primary-runtime\dependencies\pnpm\bin\pnpm.mjs')
    nodeBin        = (Join-Path $appRoot 'resources\runtime\bin')
    # 安装自带的 CLI 入口（解包布局下是 dsh-builtin-browser 的桥）。
    # 为什么要有：解包之后官方自己的 `dsh plugin install` 会在多出来的 app\ 段上找 pnpm
    # （resources\app\runtime\...\pnpm.mjs 不存在），装插件直接失败。走这个入口能把
    # DSH_APP / ELECTRON_RUN_AS_NODE 交给 App 自己决定，是唯一不靠猜的绕法。
    cliCmd         = (Join-Path $appRoot 'resources\runtime\cli\bin\dsh.cmd')
    cliCmdFallback = (Join-Path $appRoot 'resources\cli\bin\dsh.cmd')
  }
}

function Resolve-FirstPath([string[]]$Candidates) {
  # 返回第一个存在的候选路径；一个都没有时返回 $null（调用方自己决定怎么报错）
  foreach ($c in @($Candidates)) {
    if (-not $c) { continue }
    if (Test-Path -LiteralPath $c) { return [string]$c }
  }
  return $null
}

function Get-DesktopNodeExe {
  <#
    宿主自带的 node.exe（<appRoot>\resources\runtime\bin\node.exe）。外部工具（如 scripts\dsh-plugin-install.ps1）
    跑 pnpm 时应该用它，而不是去要求用户 PATH 上有 node —— 装在非默认目录的机器上 PATH 往往没有。
    找不到就退回 PATH 上的 node，再没有就返回空串（调用方自己决定是否报错）。
  #>
  $inst = @(Get-DesktopInstances) | Select-Object -First 1
  if ($inst -and $inst.nodeBin) {
    $cand = Join-Path ([string]$inst.nodeBin) 'node.exe'
    if (Test-Path -LiteralPath $cand) { return $cand }
  }
  $exe = Resolve-DesktopAppPath
  if ($exe) {
    $paths = Get-DesktopPaths $exe
    $cand = Join-Path ($paths.appRoot + '\resources\runtime\bin') 'node.exe'
    if (Test-Path -LiteralPath $cand) { return $cand }
  }
  return [string](Get-Command node -ErrorAction SilentlyContinue).Source
}

function Get-MachineIdentity {
  <#
    机器身份只认一份：从运行中的宿主自己的事实推出来，缓存到状态目录。
    为什么不用 `dsh --dump-config`：桌面 profile 被 App 独占托管，CLI 直接拒绝
    （error: profile "desktop" is managed exclusively by the Electron application），
    这条路在本机永远走不通 —— 别再试。
    为什么不用 machine.json 当身份：它是 App 装在默认目录时的探测结果，App 挪过位置后
    它就是错的（本机实测：machine-config 说 C:\deepseekharness 之外的位置，而真实宿主在
    C:\deepseekharness）。运行中的宿主给出的目录形状才是机器事实。
    缓存键 = 宿主 exe + 运行时目录 + 主进程 pid 的启动时刻：App 一被替换/重启，键就变。
  #>
  if ($script:MachineIdentity) { return $script:MachineIdentity }
  $cacheFile = Get-StatePath 'machine-identity.json'
  $cache = $null
  if (Test-Path -LiteralPath $cacheFile) {
    try { $cache = Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cache = $null }
  }
  $exe = Resolve-DesktopAppPath
  if (-not $exe) { return $null }
  $shape = Get-DesktopPaths $exe
  $key = ('{0}|{1}' -f $exe, $shape.runtimeDir)
  $script:MachineIdentity = [pscustomobject]@{
    desktopApp = $exe
    runtimeDir = $shape.runtimeDir
    pnpm       = $shape.pnpm
    cliCmd     = (Resolve-FirstPath @($shape.cliCmd, $shape.cliCmdFallback))
    appRoot    = $shape.appRoot
    layout     = $shape.layout
    dshHome    = $DshHome
    profile    = $Profile
    source     = 'runtime-shape'
    key        = $key
    capturedAt = (Get-Date).ToString('o')
  }
  return $script:MachineIdentity
}

function Test-DesktopRuntime($Paths) {
  # asar 布局下 Test-Path 看不到 asar 内部，只能看 asar 文件本身；unpacked 布局看真实目录。
  if (-not $Paths) { return $false }
  if (Test-Path -LiteralPath $Paths.asar -PathType Leaf) { return $true }
  if (Test-Path -LiteralPath $Paths.runtimeDir -PathType Container) { return $true }
  return $false
}

function Get-HostFaceRank([int]$Status) {
  <#
    端口名次的唯一口径：0 = 宿主主面（200），1 = 认证面（401），2 = token 重定向（303），99 = 兜底。
    为什么 200 排第一在这台机器上会错：宿主同时监听 4173（dsh-browser 的 CDP，**任何时刻都回
    200**）和它自己的面板面（无 token 时 401）。按「200 最先」排，4173 每次都赢 —— 实测
    -Status 报 resolvedPort=4173，面板上的「访问地址」指向浏览器调试协议，而真正的宿主面
    19920 被判成附件面写进了建议表。
    但也不能简单把 401 排第一：「域名提示」这类面会先回 404 再回 401，这时 200 要先赢。
    所以判据是「同一次采样里，200 和 401 谁先占位」——
      主面（401）在 netstat 里先出现 → 它就是宿主面；
      4173（200）先出现但**不是**宿主面 → 由「端口号不是被建议表标记的附件」+ 调用方的
      「已选定就不换」共同约束。
    实现上把这条判断留给调用方，这里只提供一致的名次表：401 > 200 > 303 > 其他。
    理由：宿主自己的面在**没 token 时必然是 401 或 200**，而附件面（CDP）稳定 200 且永不认证；
    优先认 401 不会漏掉宿主面（带 token 的地址在 200 那条路上另有 Resolve-WebAuthUrl 兜底）。
  #>
  switch ($Status) { 401 { 0 } 200 { 1 } 303 { 2 } default { 99 } }
}

function Resolve-HostPort {
  <#
    从某个 pid 的监听端口里挑出「这个宿主自己那根 HTTP 面」。返回 @{ port; status; order; probed; contentType }。
    为什么不能「第一个回应的就是」：本机实测一个桌面宿主同时监听 4 个端口 ——
      3082 = dsh web 面（200）、4173 = dsh-browser 的 CDP（也是 200，但它是浏览器调试协议）、
      48xxx = 宿主自身的面板端口（401）、48xxx+5 = 兜底路由（404 + application/json）。
    旧逻辑按 netstat 顺序无脑逐个 GET，全部按 6s 超时，一次 -Status 要白等十几秒；
    而且「第一个回应」会挑到 4173 —— 端口是随机的，那个顺序并不稳定。

    判据（按优先级，全部来自实测）：
      1. 401 是宿主面：端口已绑、认证层在要 token —— 路由挂上了，只是要先认证；
      2. 200 是默认面：不带 token 直接 200 的，是宿主给本机打开的那一面；
      3. 303 是 token 重定向：带 token 的访问地址过这一面，同样是活的服务；
      4. 404 / 连不上只能兜底，且明确不算「就绪」（404 = 端口绑了但路由还没挂完）。
    同分时按 netstat 顺序，保持既有行为可预测。

    2026-11-27 真机两次修（-Status 报 35877/404 而不是 35863/401）：
      * **content-type: application/json 的 404** 是宿主的路由兜底面（几毫秒就答），从来不是
        宿主面。它和 401 面平等做兜底候选时，401 面一次读超时（0）就让它胜出。现在它只做
        最后的兜底，并且会被 Get-DesktopInstances 学成 aux，下次直接跳过。
      * 401 面「连上了但没回话」（0）不是终局：还有别的端口在听时，对这一组再问一遍。
        这一遍只发生在「本来就要报一个不健康面」的坏路径上，好路径一个字节都不多花。
  #>
  param([int[]]$Ports = @(), [string]$Host_ = $BindHost, [int]$ConnectTimeoutMs = 1500, [int[]]$SkipPorts = @(), [int]$DeadlineMs = 3000, [switch]$ProbeAll)
  $order = New-Object System.Collections.ArrayList
  $all = @($Ports | Where-Object { $_ -gt 0 })
  if ($all.Count -eq 0) { return [pscustomobject]@{ port = 0; status = 0; order = @(); probed = 0; contentType = '' } }
  $best = $null; $bestRank = 99; $bestStatus = 0
  $fallback = $null        # 非 JSON 的兜底面（优先）
  $fallbackJson = $null    # JSON 兜底面（最后才用）
  $probed = 0
  $unprobed = New-Object System.Collections.ArrayList
  $zero = New-Object System.Collections.ArrayList
  foreach ($p in @($all | Sort-Object)) {
    if (@($SkipPorts) -contains [int]$p) {
      # 已知不是宿主的面（实测过的浏览器调试端口等）。不探、不占预算，也**不算**兜底候选。
      [void]$order.Add([pscustomobject]@{ port = $p; status = -1; ms = 0; stage = 'skipped'; known = 'aux'; ct = '' })
      continue
    }
    if ($bestRank -eq 0 -and -not $ProbeAll) {
      # 已经确定是宿主面了（401）。剩下的端口在 -ProbeAll 那一轮再补探，这一轮先记账。
      [void]$unprobed.Add([int]$p)
      continue
    }
    Add-Phase ("probe:" + $p)
    $s = Invoke-HttpProbe -Port $p -Host_ $Host_ -ConnectTimeoutMs $ConnectTimeoutMs
    $probed++
    [void]$order.Add([pscustomobject]@{ port = $p; status = $s.status; ms = $s.ms; stage = $s.stage; ct = [string]$s.contentType })
    # 200 是宿主给本机开的默认面；401 是认证层在要 token —— 两者都说明「端口绑了、路由挂上了」。
    # 顺序固定为 401 > 200 > 303 > 其他：主面偶尔读慢（实测先 404、隔一秒 401），若把 401 排末位，
    # 那个稳定回 404 的兜底端口就会胜出，-Status 于是报一个并不存在的「就绪」面。
    # 4173 那种浏览器调试端口也是 200，只能靠「已经选定了就别再换」+ 建议表避开，不能靠猜端口号。
    $rank = Get-HostFaceRank $s.status
    # 只在「端口通了但给了状态码」时重问；连不上 / 连接超时不重问（那是在给一台死端口翻倍等待）
    if ($rank -eq 99 -and $s.stage -eq 'http' -and $s.status -gt 0) {
      # 端口是通的、只是「这一眼」还没挂上路由：等一下再问一次（宿主启动早期就是这个形状）
      Start-Sleep -Milliseconds 700
      $again = Invoke-HttpProbe -Port $p -Host_ $Host_ -ConnectTimeoutMs $ConnectTimeoutMs
      $probed++
      [void]$order.Add([pscustomobject]@{ port = $p; status = $again.status; ms = $again.ms; stage = $again.stage; ct = [string]$again.contentType; retry = $true })
      $s = $again
      $rank = Get-HostFaceRank $s.status
    }
    # 连上了、却一个字都没回：这一眼不能算终局（宿主忙时 401 面会先读超时），先记账，坏路径上再补一次。
    if ($rank -eq 99 -and $s.status -eq 0 -and $s.stage -eq 'http') { [void]$zero.Add([int]$p) }
    if ($rank -lt $bestRank) { $bestRank = $rank; $best = $p; $bestStatus = $s.status }
    if ($s.status -ne 0) {
      if ([string]$s.contentType -like 'application/json*') {
        if (-not $fallbackJson) { $fallbackJson = $p }
      } elseif (-not $fallback) { $fallback = $p }
    }
  }
  # 第二遍：只在「没有任何一面试就绪，而且刚才有人一个字都没回」时补一次。见函数头 2026-11-27 第二条。
  if ($bestRank -eq 99 -and -not $ProbeAll -and @($all).Count -gt 1 -and @($zero).Count -gt 0) {
    foreach ($p in @($zero)) {
      Add-Phase ("probe2:" + $p)
      $s2 = Invoke-HttpProbe -Port $p -Host_ $Host_ -ConnectTimeoutMs $ConnectTimeoutMs -RequestTimeoutMs 5000
      $probed++
      [void]$order.Add([pscustomobject]@{ port = [int]$p; status = $s2.status; ms = $s2.ms; stage = $s2.stage; ct = [string]$s2.contentType; retry = $true; pass = 2 })
      $r2 = Get-HostFaceRank $s2.status
      if ($r2 -lt $bestRank) { $bestRank = $r2; $best = $p; $bestStatus = $s2.status }
    }
  }
  # 没探的那些明确标成 unprobed —— 「没看过」和「看过没回」是两件事，消费方要能分清
  foreach ($q in @($unprobed)) {
    [void]$order.Add([pscustomobject]@{ port = [int]$q; status = -1; ms = 0; stage = 'unprobed'; ct = '' })
  }
  if ($bestRank -lt 99) {
    $bestEntry = @($order.ToArray() | Where-Object { [int]$_.port -eq [int]$best -and [int]$_.status -eq [int]$bestStatus })[0]
    return [pscustomobject]@{ port = [int]$best; status = $bestStatus; order = @($order.ToArray()); probed = $probed; contentType = [string]$bestEntry.ct }
  }
  $pick = if ($fallback) { $fallback } else { $fallbackJson }
  $status = 0
  $ct = ''
  if ($pick) {
    $e = @($order.ToArray() | Where-Object { [int]$_.port -eq [int]$pick })[0]
    $status = [int]$e.status
    $ct = [string]$e.ct
  }
  return [pscustomobject]@{ port = [int]$pick; status = $status; order = @($order.ToArray()); probed = $probed; contentType = $ct }
}

function Get-AuxPortHint([int]$MainPid_) {
  <#
    **建议性**缓存：上一次实测认出「不是宿主 HTTP 面」的端口（典型：dsh-browser 的 CDP 端口，
    同 pid 也在监听、也回 200，但它不是宿主的面 —— 本机实测它曾吃掉一次 10s 的连接超时）。
    存进 state\aux-ports.json，按 Electron 主进程 pid 归属：pid 变了（App 重启）就不认老结论。
    只影响「先探谁」，不影响任何判定：被跳过的端口在 order 里标 stage=skipped，
    并且只有在本轮**已经确定**选到 200/401 面时才写回。
  #>
  if (-not $MainPid_) { return @() }
  $path = Get-StatePath 'aux-ports.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
  try {
    $o = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int](Get-JsonField $o 'mainPid') -ne [int]$MainPid_) { return @() }
    return @((Get-JsonField $o 'ports') | Where-Object { $_ -and [int]$_ -gt 0 } | ForEach-Object { [int]$_ })
  } catch { return @() }
}

function Save-AuxPortHint([int]$MainPid_, [int[]]$Ports) {
  # 把「本次实测确认不是宿主面」的端口记下来（供下次先跳过）。失败不影响任何行为。
  # 合并而不是覆盖：CDP 的 200 面与路由兜底的 JSON 404 面是两次独立发现，
  # 覆盖写入会让后一次把前一次学过的东西丢掉（于是每次都要重新踩一遍）。
  if (-not $MainPid_ -or @($Ports).Count -eq 0) { return }
  try {
    $old = @(Get-AuxPortHint $MainPid_)
    $all = @(@($old) + @($Ports) | Where-Object { $_ -and [int]$_ -gt 0 } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    $rec = [ordered]@{ mainPid = [int]$MainPid_; ports = @($all); savedAt = (Get-Date).ToString('o') }
    New-Utf8NoBom (Get-StatePath 'aux-ports.json') ($rec | ConvertTo-Json -Compress)
  } catch { }
}

function Get-DesktopInstances {
  # 参数：-Refresh 强制重扫端口表与进程表（等待循环里用，每轮宿主集会变）。
  param([switch]$Refresh, [switch]$ProbeAll)  <#
    桌面版实例 = 宿主子进程 + 它的 Electron 主进程 + 实测监听端口。
    身份四要素（缺一不可，防误杀）：
      a) 进程名 DeepSeek Harness.exe 且命令行含 dsh-desktop-host\lib\index.js；
      b) 父进程是同目录下的 DeepSeek Harness.exe，且命令行里没有 --type=（不是渲染/GPU 子进程）；
      c) <appRoot>\resources\app.asar 是真实文件；
      d) 宿主命令行里包含由 (b) 推导出的 runtimeDir。
    端口：netstat 反查宿主 pid 的 LISTENING 端口，逐个 GET /，取 401/200 的那个。
  #>
  Add-Phase 'host-kind'
  $list = New-Object System.Collections.ArrayList
  # 一次 netstat + 一次 CIM 全表：以前每个候选都要重扫一遍端口表、每个父进程都要单独查一次
  # Get-CimInstance（~135ms 一次），候选一多就变成秒级。
  $rows = Get-NetstatListenerRows -Refresh:$Refresh
  $procMap = Get-ProcessIndex -Refresh:$Refresh
  # 一次取成数组变量：function 返回单元素集合时 @() 之外再写 $h.xxx 会踩严格模式的
  # 「在此对象上找不到属性 commandLine」（实测，服务端筛完只剩 1 个宿主时必现）
  $hostProcs = @(Get-DesktopHostProcesses)
  foreach ($h in $hostProcs) {
    if (-not $procMap.ContainsKey([int]$h.mainPid)) { continue }
  $main = $procMap[[int]$h.mainPid]
    if (-not $main) { continue }
    $mainPath = [string]$main.ExecutablePath
    if (-not $mainPath) { continue }
    if ([string]$main.CommandLine -match '--type=') { continue }
    $paths = Get-DesktopPaths $mainPath
    if (-not (Test-DesktopRuntime $paths)) { continue }
    if ($h.commandLine -notlike ('*' + $paths.runtimeDir + '*')) { continue }
    $profileName = ''
    if ($h.commandLine -match '[\\/]profiles[\\/]([A-Za-z0-9][A-Za-z0-9._-]{0,63})') { $profileName = $Matches[1] }
    $ports = @(Get-ListeningPorts $h.pid $rows)
    # 跳过的端口：已知附件面（上次学会的）+ 本进程内上一轮采样已确认「不是宿主面」的。
    $skip = @(Get-AuxPortHint $h.mainPid)
    if (-not $ProbeAll) {
      foreach ($pp in @($script:ProbedPorts.Keys)) {
        $pObj = $script:ProbedPorts[[int]$pp]
        if ($pObj -and [int]$pObj.status -gt 0 -and -not $pObj.chosen) { $skip += [int]$pp }
      }
    }
    $pick = Resolve-HostPort $ports -SkipPorts $skip -ProbeAll:$ProbeAll
    # 本轮实测：记住每个给过状态码的端口（供本轮第二次采样与建议表使用）
    foreach ($o in @($pick.order)) {
      if ([int]$o.status -gt 0) {
        $script:ProbedPorts[[int]$o.port] = @{ status = [int]$o.status; chosen = ([int]$o.port -eq [int]$pick.port) }
      }
    }
    # 附件面 = 探了、给了状态码、却不是被选中的那一面，而且**不是 401**：
    # 401 = 端口绑了、认证层在要 token（宿主自己的面在启动早期就是这个形状）——
    # 把 401 当附件面跳过，会漏掉「主面还没挂上、认证面先起来」的那一瞬。
    # 只在本次选中的那面确实就绪（200/401）时才写回：自己都没看清时，别断定别人是附件。
    $aux = @($pick.order | Where-Object {
        $_.stage -eq 'http' -and $_.status -gt 0 -and $_.status -ne 401 -and [int]$_.port -ne [int]$pick.port
      } | ForEach-Object { [int]$_.port })
    $pickReady = ([int]$pick.status -eq 200 -or [int]$pick.status -eq 401)
    if ($aux.Count -gt 0 -and $pick.port -gt 0 -and $pickReady) { Save-AuxPortHint $h.mainPid $aux }
    # JSON + 404 是路由兜底面（几毫秒就答、content-type 明确），从来不是宿主面 ——
    # 这条结论不依赖「本轮选没选中就绪面」。学不到它，下一次 401 面一忙（读超时）
    # 它就会赢（2026-11-27 实测 35877/404 胜 35863/401）。
    $auxJson = @($pick.order | Where-Object {
        $_.stage -eq 'http' -and [int]$_.status -eq 404 -and ([string]$_.ct -like 'application/json*') -and [int]$_.port -ne [int]$pick.port
      } | ForEach-Object { [int]$_.port })
    if ($auxJson.Count -gt 0) { Save-AuxPortHint $h.mainPid $auxJson }
    $proc = Get-Process -Id $h.pid -ErrorAction SilentlyContinue
    [void]$list.Add([pscustomobject]@{
      pid            = $h.pid
      name           = 'DeepSeek Harness'
      port           = $pick.port
      ports          = @($ports)
      probe          = $pick.order
      isNode         = $true
      kind           = 'desktop-host'
      mainPid        = $h.mainPid
      profile        = $profileName
      mainPath       = $mainPath
      exe            = $paths.exe
      appRoot        = $paths.appRoot
      runtimeDir     = $paths.runtimeDir
      entry          = $paths.entry
      asar           = $paths.asar
      primaryRuntime = $paths.primaryRuntime
      pnpm           = $paths.pnpm
      nodeBin        = $paths.nodeBin
      http           = $pick.status
      start          = $(try { $proc.StartTime.ToString('o') } catch { '' })
      ws_mb          = $(if ($proc) { [math]::Round($proc.WorkingSet64 / 1MB, 1) } else { 0 })
      handles        = $(try { $proc.HandleCount } catch { -1 })
      source         = 'desktop-host'
    })
  }
  Add-Phase 'instances'
  return @($list.ToArray())
}

function Resolve-HostKind {
  <#
    auto 的判据顺序（先活的事实，再落盘的机器事实，最后才是默认值）：

      ① 有桌面版宿主进程在跑                      → desktop（唯一不需要推断的证据）
      ② <StateDir>\machine.json 说这台机器是 desktop → desktop
      ③ 启动档案里的命令是 Desktop 的 exe          → desktop
      ④ 桌面版 App 就装在本机、而 web 宿主不可启动  → desktop
      ⑤ 以上都不成立                              → web（保持老行为，连“找不到 dsh web”的失败文案都不变）

    为什么必须加 ②③ 的对称性（2026-11-23 冷启动实测）：旧版只看「有没有进程」和「启动档案里有没有
    exe 字面量」。开机后 DSH 还没起来时两条都不成立，于是这台**明确是桌面版**的机器被判成 web，
    接着去跑 `cmd /c dsh web --no-open ...`：那条命令在没装 dsh CLI 的机器上要等到 PATH 解析失败
    才报错，中间既没有 exe 被拉起、也没有任何一行提示 —— 机主看到的就是「点了没反应」。
    机器已经用 dsh-config / 安装器记录过 hostKind=desktop 时，没有理由把它推翻。
  #>
  if ($script:HostKindRequested -ne 'auto') {
    $script:HostKind = $script:HostKindRequested
    $script:HostKindSource = 'explicit'
    return
  }
  if (@(Get-DesktopHostProcesses).Count -gt 0) {
    $script:HostKind = 'desktop'
    $script:HostKindSource = 'running-instance'
    return
  }
  $mc = Get-MachineConfig
  if ($mc -and [string]$mc.hostKind -eq 'desktop') {
    $script:HostKind = 'desktop'
    $script:HostKindSource = 'machine.json'
    return
  }
  $rec = Get-BootRecord
  # machine.json 存在时它的 hostKind 就是这台机器的属性；启动档案只能补「它没说」的空。
  # 否则一份旧的启动档案会把一台 web 机器永久钉在 desktop 上（反过来更糟：热启动时被忽视）。
  $machineSaid = [bool]($mc -and $mc.hostKind)
  if (-not $machineSaid -and $rec -and $rec.command -and ([string]$rec.command -match '(?i)DeepSeek Harness\.exe')) {
    $script:HostKind = 'desktop'
    $script:HostKindSource = 'boot-record'
    return
  }
  # 启动档案只说了一条命令（任意 exe），它的 hostKind 字段来自「上一次是谁在跑」，
  # 不是这台机器的属性 —— 不能拿它推翻 machine.json 明确声明的 web。
  if (-not $machineSaid -and $rec -and [string]$rec.hostKind -eq 'desktop') {
    $script:HostKind = 'desktop'
    $script:HostKindSource = 'boot-record'
    return
  }
  $script:HostKind = 'web'
  $script:HostKindSource = 'default'
}

function Resolve-DesktopProfileName {
  <#
    桌面版下 -Profile 的默认值（web）是错的：宿主只跑 desktop。若用户没显式给 -Profile，
    从运行中宿主的命令行（...\profiles\<name>）推导，其次用启动档案里的 profile。
    必须在 -Preflight / -VerifyOnly 分支之前调用 —— 那条路不经过实例发现。
  #>
  if ($script:ProfileExplicit) { return }
  if ($script:HostKind -ne 'desktop') { return }
  foreach ($h in @(Get-DesktopHostProcesses)) {
    if ($h.commandLine -match '[\\/]profiles[\\/]([A-Za-z0-9][A-Za-z0-9._-]{0,63})') {
      $name = [string]$Matches[1]
      if ($name -and $name -ne $Profile) {
        Add-Step 'profile' "profile 自动取自运行中的宿主：$name（默认值 $Profile 是 dsh web 的）" 'ok'
        $script:Profile = $name
      }
      return
    }
  }
  $rec = Get-BootRecord
  if ($rec -and $rec.profile -and [string]$rec.profile -ne $Profile) {
    Add-Step 'profile' "profile 自动取自启动档案：$($rec.profile)" 'ok'
    $script:Profile = [string]$rec.profile
    return
  }
  # 冷启动时既没有运行中的宿主、也没有启动档案：machine.json 是这台机器唯一的落盘事实。
  $mc = Get-MachineConfig
  if ($mc -and $mc.profile -and [string]$mc.profile -ne $Profile) {
    Add-Step 'profile' "profile 自动取自 machine.json：$($mc.profile)" 'ok'
    $script:Profile = [string]$mc.profile
  }
}

function Get-MachineConfig {
  <#
    读 <StateDir>\machine.json（scripts\dsh-config.ps1 写入）。读不到/解析失败一律返回 $null ——
    配置是加速与兜底，不是前置条件，缺失时按候选列表照旧探测。
  #>
  $path = Get-StatePath 'machine.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Resolve-DesktopAppPath {
  <#
    顺序（先事实，后声称）：显式指定 → 运行中的实例 → 启动档案里的 exe → 本次已解析 →
    机器配置 → 常见安装位置 → 系统登记处/快捷方式。
    运行中的实例排在机器配置之前：machine.json 是探测时写下的「以为装在哪」，App 挪过
    位置后它就是错的；正在跑的进程是可执行文件位置的定义性事实。
    （早期版本把机器配置放第一位，实测在挪过位置的机器上报告了错误的 desktopAppSource。）
  #>
  $cands = New-Object System.Collections.ArrayList
  if ($DesktopApp) {
    # 显式指定优先于一切探测（用户已经给出了唯一确定的事实）
    [void]$cands.Add([pscustomobject]@{ path = [string]$DesktopApp; source = 'explicit' })
  }
  foreach ($i in @(Get-DesktopInstances)) { if ($i.exe) { [void]$cands.Add([pscustomobject]@{ path = [string]$i.exe; source = 'running-instance' }) } }
  $rec = Get-BootRecord
  if ($rec -and $rec.command) {
    $m = [regex]::Match([string]$rec.command, '"([^"]+\.exe)"|^\s*([^\s]+\.exe)')
    if ($m.Success) {
      $picked = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
      [void]$cands.Add([pscustomobject]@{ path = $picked; source = 'boot-record' })
    }
  }
  if ($script:DesktopAppPath) { [void]$cands.Add([pscustomobject]@{ path = [string]$script:DesktopAppPath; source = 'resolved' }) }
  $machineCfg = Get-MachineConfig
  if ($machineCfg -and $machineCfg.desktopApp) {
    [void]$cands.Add([pscustomobject]@{ path = [string]$machineCfg.desktopApp; source = 'machine-config' })
  }
  [void]$cands.Add([pscustomobject]@{ path = (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'); source = 'default-location' })
  [void]$cands.Add([pscustomobject]@{ path = (Join-Path $env:ProgramFiles 'DeepSeek Harness\DeepSeek Harness.exe'); source = 'default-location' })
  foreach ($c in @(Get-DesktopInstallPaths)) { [void]$cands.Add([pscustomobject]@{ path = [string]$c; source = 'registry/shortcut' }) }
  foreach ($entry in $cands) {
    if (-not $entry -or -not $entry.path) { continue }
    if (-not (Test-Path -LiteralPath $entry.path -PathType Leaf)) { continue }
    $script:DesktopAppPath = [string]$entry.path
    $script:DesktopAppPathSource = [string]$entry.source
    return $script:DesktopAppPath
  }
  return $null
}

function Get-DesktopInstallPaths {
  <#
    用户把 App 装在非默认位置时（本机实测：<盘>\<目录>\<exe>，既不在 Program Files 也不在
    %LOCALAPPDATA%\Programs），固定候选必然落空。这里从系统自己的登记处反查，不猜目录名：
      ① 卸载登记（HKCU/HKLM 的 Uninstall\*，DisplayName/DisplayIcon/InstallLocation）
      ② App Paths（HKLM/HKCU ...\App Paths\<exe>）
      ③ 开始菜单快捷方式（.lnk 的 TargetPath）
    全部失败就返回空数组 —— 由调用方明确报错（fail-closed），绝不去扫整盘。
  #>
  $exeName = 'DeepSeek Harness.exe'
  $out = New-Object System.Collections.ArrayList
  $seen = @{}
  $add = {
    param([string]$Path_)
    if (-not $Path_) { return }
    $cand = $Path_
    if (Test-Path -LiteralPath $cand -PathType Container) { $cand = Join-Path $cand $exeName }
    if ($cand -notlike '*.exe') { return }
    if (-not (Test-Path -LiteralPath $cand -PathType Leaf)) { return }
    $key = $cand.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { return }
    $seen[$key] = $true
    [void]$out.Add($cand)
  }

  # ① 卸载登记。路径拼装走 Join-Path，不写字面量反斜杠路径 —— 仓库的去本机化规则（parity M-01）
  #    把任何「盘符或带反斜杠的绝对路径」都判成安装位置；注册表路径同样该由构造得出。
  $uninstallRoots = @(
    [pscustomobject]@{ Hive = 'HKCU'; Base = 'Software' },
    [pscustomobject]@{ Hive = 'HKLM'; Base = 'Software' },
    [pscustomobject]@{ Hive = 'HKLM'; Base = 'Software\WOW6432Node' }
  )
  foreach ($root in $uninstallRoots) {
    $registryPath = (@($root.Base, 'Microsoft', 'Windows', 'CurrentVersion', 'Uninstall') -join '\')
    $providerPath = Join-Path ($root.Hive + ':') $registryPath
    foreach ($sub in @(Get-ChildItem -LiteralPath $providerPath -ErrorAction SilentlyContinue)) {
      # StrictMode 2.0：注册表项往往缺这些值，必须逐项安全取（$props.DisplayName 会直接抛）
      $display = ''
      $icon = ''
      $loc = ''
      try { $display = [string]$sub.GetValue('DisplayName', '') } catch { }
      if ($display -notmatch '(?i)deepseek|harness') { continue }
      try { $icon = [string]$sub.GetValue('DisplayIcon', '') } catch { }
      try { $loc = [string]$sub.GetValue('InstallLocation', '') } catch { }
      if ($icon) { & $add (($icon -replace ',\s*-?\d+$', '').Trim('"')) }
      if ($loc) { & $add $loc }
    }
  }

  # ② App Paths
  foreach ($hive in @('HKCU:', 'HKLM:')) {
    $appPathsRoot = @($hive, 'Software', 'Microsoft', 'Windows', 'CurrentVersion', 'App Paths') -join '\'
    $key = Join-Path $appPathsRoot $exeName
    if (-not (Test-Path -LiteralPath $key)) { continue }
    try { & $add ([string](Get-Item -LiteralPath $key -ErrorAction Stop).GetValue('', '')) } catch { }
  }

  # ③ 开始菜单快捷方式（用户级 + 全局）
  $shell = New-Object -ComObject WScript.Shell
  foreach ($dir in @(
      (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
      (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'))) {
    foreach ($lnk in @(Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
      if ($lnk.Name -notmatch '(?i)deepseek|harness') { continue }
      try { & $add ([string]$shell.CreateShortcut($lnk.FullName).TargetPath) 'start-menu' } catch { }
    }
  }

  # ④ 桌面快捷方式（很多人只用桌面图标启动）
  foreach ($dir in @((Join-Path $env:USERPROFILE 'Desktop'), (Join-Path $env:PUBLIC 'Desktop'))) {
    foreach ($lnk in @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
      if ($lnk.Name -notmatch '(?i)deepseek|harness') { continue }
      try { & $add ([string]$shell.CreateShortcut($lnk.FullName).TargetPath) 'desktop-shortcut' } catch { }
    }
  }
  return @($out.ToArray())
}

function Get-DesktopLaunch {
  $exe = Resolve-DesktopAppPath
  if (-not $exe) { return $null }
  $cwd = Split-Path -Path $exe -Parent
  $rec = Get-BootRecord
  if ($rec -and $rec.cwd -and (Test-Path -LiteralPath $rec.cwd)) { $cwd = [string]$rec.cwd }
  return [pscustomobject]@{ file = $exe; args = @(); cwd = $cwd; source = 'desktop-app'; raw = $exe }
}

function Get-OrphanDesktopHosts {
  <#
    找「父进程已经不在了」的桌面宿主：taskkill /T 只顺着 pid 树杀，而树关系在父进程死掉那一刻
    就断了。2026-11-23 的现场：一次调试连做 11 次重启，每次都拉起新的 Electron 主进程，
    taskkill 杀掉新的那棵树，前一次的主进程却先自行退出 → 它名下的宿主成了孤儿，一直活着，
    最后 5 个孤儿共占 ~1.8GB、各自占两个端口、各自跑一份 profile 的后台任务。
    判据用身份（命令行含本机 dsh-desktop-host 入口）而不是 pid 树，才收得到孤儿。
    恒返回数组。
  #>
  param([switch]$Refresh)
  $out = New-Object System.Collections.ArrayList
  if (-not (Get-CimAvailable)) { return @() }
  $alive = @{}
  foreach ($r in @(Find-DesktopHostRows -Refresh:$Refresh)) { if ($r) { $alive[[int]$r.ProcessId] = $r } }
  foreach ($h in @(Get-DesktopHostProcesses -Refresh:$Refresh)) {
    if ($alive.ContainsKey($h.mainPid)) { continue }
    [void]$out.Add([pscustomobject]@{
      pid       = $h.pid
      mainPid   = $h.mainPid
      createdAt = $h.createdAt
      name      = $h.name
    })
  }
  return @($out.ToArray())
}

function Stop-OrphanDesktopHosts {
  <#
    收掉孤儿宿主（见 Get-OrphanDesktopHosts）。带 -DryRunOnly 时只报告不杀。
    返回 @{ killed = @(pid...); skipped = @(pid...) }；绝不 throw —— 清扫失败不该把一次成功
    的重启变成失败，调用方把它写成 warn 步。
  #>
  param([switch]$DryRunOnly)
  $killed = New-Object System.Collections.ArrayList
  $skipped = New-Object System.Collections.ArrayList
  $orphans = @(Get-OrphanDesktopHosts -Refresh)
  if ($orphans.Count -eq 0) { return [pscustomobject]@{ killed = @(); skipped = @() } }
  foreach ($o in $orphans) {
    if ($DryRunOnly) {
      Add-Step 'orphan' ("残留宿主 pid=" + $o.pid + "（原主进程 " + $o.mainPid + " 已退出）→ -DryRun 下不回收") 'warn'
      [void]$skipped.Add($o.pid)
      continue
    }
    $proc = Get-Process -Id $o.pid -ErrorAction SilentlyContinue
    if (-not $proc) { continue }
    & (Get-SystemTool 'taskkill') /PID $o.pid /T /F *> $null
    Start-Sleep -Milliseconds 300
    if (Get-Process -Id $o.pid -ErrorAction SilentlyContinue) {
      try { Stop-Process -Id $o.pid -Force -ErrorAction Stop } catch { }
      Start-Sleep -Milliseconds 200
    }
    if (Get-Process -Id $o.pid -ErrorAction SilentlyContinue) {
      [void]$skipped.Add($o.pid)
    } else {
      [void]$killed.Add($o.pid)
    }
  }
  if ($killed.Count -gt 0) {
    Add-Step 'orphan' ("已回收残留桌面宿主 " + $killed.Count + " 个（父进程已退出的孤儿，taskkill /T 顺树杀不到）：" +
      ($killed -join '、')) 'ok'
  }
  if ($skipped.Count -gt 0) {
    Add-Step 'orphan' ("还有残留宿主未回收：" + ($skipped -join '、') + "（权限或正在退出）") 'warn'
  }
  return [pscustomobject]@{ killed = @($killed.ToArray()); skipped = @($skipped.ToArray()) }
}

function Stop-DesktopApp([int]$MainPid_, [int]$HostPid_, [int]$WaitSeconds) {
  <#
    桌面版的停机 = 杀 Electron 主进程整棵树（taskkill /T /F）。
    为什么不走温和 /T：GUI 的 WM_CLOSE 会触发 App 自己的「有任务在跑，确认退出？」对话框，
    graceSec 内必然等不到退出，随后还是强杀 —— 只是多闪一个框。续跑通知在停机前已写好。
    身份复核：mainPid 必须仍对应一个通过四要素校验的桌面实例，且宿主子进程没换过。
  #>
  $inst = $null
  foreach ($i in @(Get-DesktopInstances)) { if ($i.mainPid -eq $MainPid_) { $inst = $i; break } }
  if (-not $inst) {
    Add-Step 'stop' "main pid=$MainPid_ 不是可识别的 DSH Desktop 主进程 → 拒绝停机（fail-closed）" 'fail'
    return $false
  }
  if ($HostPid_ -gt 0 -and $inst.pid -ne $HostPid_) {
    Add-Step 'stop' "宿主子进程已变化（发现 $($inst.pid)，期望 $HostPid_）→ 拒绝停机" 'fail'
    return $false
  }
  Add-Step 'stop' "taskkill /PID $MainPid_ /T /F（DSH Desktop 主进程整棵树；续跑通知已写）" 'ok'
  $o = & (Get-SystemTool 'taskkill') /PID $MainPid_ /T /F 2>&1
  $rc = $LASTEXITCODE
  $deadline = (Get-Date).AddSeconds([Math]::Max($WaitSeconds, 15))
  while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process -Id $MainPid_ -ErrorAction SilentlyContinue)) {
      Add-Step 'stop' "DSH Desktop 已退出（taskkill rc=$rc）" 'ok'
      # 主进程树杀完之后再按身份清扫一遍：前几轮调试遗留的孤儿宿主不在任何 pid 树上（见
      # Get-OrphanDesktopHosts 的注释），不清掉它们会继续占端口、继续跑同一个 profile 的后台任务。
      try { [void](Stop-OrphanDesktopHosts -DryRunOnly:$DryRun) } catch { Add-Step 'orphan' ('清扫残留宿主失败：' + $_.Exception.Message) 'warn' }
      return $true
    }
    Start-Sleep -Milliseconds 500
  }
  Add-Step 'stop' "DSH Desktop 主进程 $MainPid_ 未退出（taskkill rc=$rc：$(Format-KillOutput $o)）" 'fail'
  return $false
}

function Start-DesktopApp {
  # 拉起 GUI：绝不能 -WindowStyle Hidden（会把整个 App 藏掉）；重定向只为收 boot token。
  $envPlan = Sync-ProcessEnvironment
  Add-Step 'launch' ('环境块已按注册表重建：' + $envPlan.TotalCount + ' 项；PATH ' + $envPlan.PathItems + ' 项') 'ok'
  $plan = Get-DesktopLaunch
  if (-not $plan) {
    throw '找不到 DSH Desktop 可执行文件：先用 -Record -RecordCommand "\"<path>\DeepSeek Harness.exe\"" 记录一次'
  }
  $shadow = Repair-ShadowedBasePackages
  if ($shadow.moved.Count -gt 0) {
    Add-Step 'shadowed' ("profile 里的旧版基础包会遮蔽 App 自带版本（settings 服务会起不来）→ 已移走：" +
      ($shadow.moved -join '；') + "（备份在 .stale-packages）") 'warn'
  }
  if (-not (Test-SharedScope)) {
    Add-Step 'shared-scope' '共享投影缺失（宿主会连基础包都 import 不到、App 直接打不开）→ 从 app.asar 重建' 'warn'
    $rep = Repair-SharedScope
    if (-not $rep.ok) { throw ('共享投影重建失败：' + $rep.reason + '；可单独跑 dsh-restart-win -RepairSharedScope') }
    Add-Step 'shared-scope' ("已重建 " + $rep.stats.Files + " 个文件（" + $rep.elapsedSec + "s）") 'ok'
  }
  $env:DSH_HOME = $DshHome
  if ($env:DSH_RESTART_INJECT_HOST_ENV -ne '0') {
    $env:DSH_UC_PROFILE_NODE_MODULES = Join-Path $DshHome 'profiles\node_modules'
    $env:NPM_CONFIG_LEGACY_PEER_DEPS = 'true'
    Add-Step 'launch' "已注入宿主环境 DSH_HOME=$env:DSH_HOME、DSH_UC_PROFILE_NODE_MODULES=$env:DSH_UC_PROFILE_NODE_MODULES" 'ok'
  } else {
    Add-Step 'env' '按 DSH_RESTART_INJECT_HOST_ENV=0 跳过宿主环境注入' 'skip'
  }
  $webOut = Get-StatePath (Get-HostLogName 'out')
  $webErr = Get-StatePath (Get-HostLogName 'err')
  if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
  foreach ($f in @($webOut, $webErr)) {
    $banner = ("`n===== dsh-restart {0} 拉起 DSH Desktop cmd={1} =====`r`n" -f (Get-Date -Format o), $plan.raw)
    try { [System.IO.File]::AppendAllText($f, $banner, (New-Object System.Text.UTF8Encoding($false))) } catch { }
  }
  $script:HostOutPath = $webOut
  $script:HostErrPath = $webErr
  # 桌面版曾经**不能**重定向 stdin/stdout/stderr：
  #   本机实测（2026-11-23 前后）给 Electron 主进程做这三个重定向，进程起来约 10s 后自己退出
  #   （日志停在 dsh-browser-bridge listening 那一行），单实例锁于是把启动转给还在跑的旧 App，
  #   引擎等的是一个永远不会出现的宿主 —— 表现就是「重启后永远等不到就绪」。
  #   那次的真凶是管道继承，已由 Hide-StdHandleInheritance（句柄层面关继承）解决。
  # 反过来完全不重定向也有代价（2026-11-23 现场）：Electron 继承的是启动者那一代控制台的管道，
  # 启动者一退出管道读端就没了 —— 主进程 console.error 直接抛 write EPIPE，
  # 表现就是「A JavaScript error occurred in the main process」弹窗 + 日志里 ECONNRESET 刷屏。
  # 所以现在：stdout/stderr 给文件（有归属、可排查），stdin 保持不重定向（GUI 不需要，
  # 也不给宿主一个指向死管道的输入句柄）。GUI 自己的窗口不受影响。
  $p = Start-Process -FilePath $plan.file -WorkingDirectory $plan.cwd -PassThru `
       -RedirectStandardOutput $webOut -RedirectStandardError $webErr
  $script:NewPid = $p.Id
  $script:NewMainPid = $p.Id
  Add-Step 'launch' "已拉起 DSH Desktop pid=$($p.Id)（$($plan.file)），stdout/stderr→$StateDir\host.desktop.*.log" 'ok'
  return $p
}

function Wait-DesktopHostReady([int]$MainPid_, [int]$MaxSec, [datetime]$MainStart, [string]$UserDataDir = '') {
  # 就绪判据：出现「本次启动生出来的」宿主子进程 + 它监听的端口 401/200。
  # 为什么不能只看 pid：Windows 会复用 pid —— 本机实测一次重启里 pid 7080 是上一轮早已死掉的
  # 主进程，32044 这个**别人的**实例恰好复用了它；只按 pid 判「主进程还活着」就会一直等，
  # 等到超时为止（240s 白等）。所以调用方把启动那一刻的时间戳传进来，pid + 启动时刻一起核。
  $oldHostPid = 0
  if ($script:Desktop) { $oldHostPid = [int]$script:Desktop.pid }
  $newMainStart = $null
  if ($MainStart -and $MainStart.Year -gt 1) { $newMainStart = $MainStart }
  if (-not $newMainStart) {
    try { $newMainStart = (Get-Process -Id $MainPid_ -ErrorAction Stop).StartTime } catch { $newMainStart = $null }
  }
  # 主进程启动期失败的判据：Electron 会写 <userData>\logs\crash-*-main.log 并**继续存活**
  # （弹「应用无法启动」窗口），所以 HasExited 永远为 false —— 只看进程/端口会白等到超时。
  # 2026-11-27 实测：主进程 70s 前就写下了 DSH_DESKTOP_UPDATE_CHECK_INTERVAL_MS 越界，
  # 引擎却继续等到预算耗尽，最后只报「未发现宿主子进程的监听端口」。
  # 显式传入的 userData 优先：看门狗探针跑在临时 userData 上，走缓存/探测会读到生产目录。
  $udDir = $UserDataDir
  if (-not $udDir) {
    try {
      $udExe = Resolve-DesktopAppPath
      if ($udExe) { $udDir = Get-DesktopUserDataDir $udExe }
    } catch { }
  }
  $crashSince = if ($newMainStart) { $newMainStart.AddSeconds(-5) } else { (Get-Date).AddSeconds(-120) }
  $nextCrashScan = (Get-Date)
  $deadline = (Get-Date).AddSeconds($MaxSec)
  # 本次动作的总预算封顶：深度验证/停机/启动已经花掉的要从就绪等待里扣掉，不让每一层
  # 各自重新计一个 90s（否则一次失败的重启可以合法地耗掉 7 分钟以上而全程无声）。
  if ($script:ActionDeadline -and $script:ActionDeadline -lt $deadline) { $deadline = $script:ActionDeadline }
  $lastPorts = @()
  $round = 0
  $waitStart = Get-Date
  # 端口表每轮只扫一次，交给本轮所有宿主候选复用（每次 netstat 实测 ~200ms，循环里每 900ms 一轮）
  $script:NetstatRows = @()
  $nextScan = (Get-Date).AddYears(-1)
  while ((Get-Date) -lt $deadline) {
    $round++
    if ((Get-Date) -ge $nextScan) { $script:NetstatRows = Get-NetstatListenerRows -Refresh; $nextScan = (Get-Date).AddSeconds(2) }
    $mainAlive = $false
    try {
      $mp = Get-Process -Id $MainPid_ -ErrorAction Stop
      # pid 被复用时不认：启动时刻对不上就说明这是另一个进程
      $mainAlive = ($null -eq $newMainStart -or [Math]::Abs(($mp.StartTime - $newMainStart).TotalSeconds) -le 5)
    } catch { $mainAlive = $false }
    if (-not $mainAlive) {
      $live = @(Get-DesktopInstances -Refresh)
      if ($live.Count -gt 0) {
        Add-Step 'ready' "新进程已退出，但机器上已有 DSH Desktop 宿主（main pid=$($live[0].mainPid)）→ 单实例锁把启动转成了聚焦旧窗口" 'fail'
        return [pscustomobject]@{ ok = $false; reason = 'desktop-single-instance' }
      }
      Add-Step 'ready' "DSH Desktop 主进程 $MainPid_ 已退出（未就绪）" 'fail'
      Show-LaunchFailure $script:HostOutPath $script:HostErrPath
      return [pscustomobject]@{ ok = $false; reason = 'exited' }
    }
    # 崩溃日志扫描（每 3s 一次，够快也不抢 netstat 的预算）
    if ($udDir -and (Get-Date) -ge $nextCrashScan) {
      $nextCrashScan = (Get-Date).AddSeconds(3)
      $crash = Get-MainCrashRecord $udDir $crashSince $MainPid_
      if ($crash -and $crash.error) {
        Add-Step 'ready' ('主进程启动失败（' + (Split-Path $crash.path -Leaf) + '）：' + $crash.error) 'fail'
        return [pscustomobject]@{ ok = $false; reason = 'main-crashed'; error = $crash.error }
      }
    }
    # 必须 -Refresh：不刷新就一直是启动前那次 WMI 快照（那时还没有新宿主），循环永远看不到它。
    foreach ($h in @(Get-DesktopHostProcesses -Refresh)) {
      # 只排掉「本次启动之前就存在、且确实还是那一代」的宿主。pid 会被复用：本机复现过
      # oldHostPid 恰好等于新宿主 pid 的情形（上一代被复用），无条件跳过就会永远等不到就绪。
      # 判据仍是出生时刻——它晚于本次启动，就不是我们要排掉的那一代。
      $isOldGen = ($oldHostPid -gt 0 -and $h.pid -eq $oldHostPid -and
        ($null -eq $h.createdAt -or $null -eq $newMainStart -or $h.createdAt -lt $newMainStart.AddSeconds(-30)))
      if ($isOldGen) { continue }
      # 硬判据 =「比这次启动更晚出生」。WMI 的 ParentProcessId 在父进程退出后保持不变
      # （Windows 不回收那段记录），所以旧实例的遗留行会一直声称自己是某个 pid 的孩子；
      # CreationDate 不会说谎。容差 30s：本机实测新宿主有同秒/早 1 秒的形状。
      $born = $h.createdAt
      $fresh = ($null -ne $born -and $newMainStart -and $born -ge $newMainStart.AddSeconds(-30))
      if (-not $fresh) { continue }
      # 别再用 `$script:NewPid` 过滤候选：拉起时那个变量记的是 Electron **主进程** pid
      # （Start-DesktopApp 里赋的），拿它去比对宿主**子进程** pid 永远不相等 —— 本机实测
      # 于是每一轮都 continue，240s 白等到超时，而宿主其实一直在正常服务。
      $ports = @(Get-ListeningPorts $h.pid $script:NetstatRows)
      if ($ports.Count -gt 0) { $lastPorts = $ports }
      $pick = Resolve-HostPort $ports
      if ($pick.port -gt 0 -and ($pick.status -eq 401 -or $pick.status -eq 200)) {
        $script:NewPid = $h.pid
        $script:NewMainPid = $MainPid_
        $script:Port = $pick.port
        Add-Step 'ready' "新宿主 pid=$($h.pid)（主进程 pid=$MainPid_）端口 $($pick.port) HTTP=$($pick.status)（本次探测 $($pick.probed) 个端口）" 'ok'
        return [pscustomobject]@{ ok = $true; http = $pick.status; authed = ($pick.status -eq 200); pid = $h.pid; mainPid = $MainPid_; port = $pick.port }
      }
    }
    Write-Activity 'ready' ("等待 DSH Desktop 宿主就绪：主进程 pid=" + $MainPid_ + "，第 " + $round + " 轮，端口 " +
      $(if (@($lastPorts).Count -gt 0) { $lastPorts -join ',' } else { '(尚未监听)' }) +
      "，已等 " + [int]((Get-Date) - $waitStart).TotalSeconds + "s，剩余预算 " + $(if ($null -ne (Get-BudgetLeftSec)) { (Get-BudgetLeftSec).ToString() + 's' } else { '不限' }))
    Write-ProgressLine 'ready' ("宿主 pid=" + $MainPid_ + "，第 " + $round + " 轮，端口 " +
      $(if (@($lastPorts).Count -gt 0) { $lastPorts -join ',' } else { '尚未监听' }))
    Start-Sleep -Milliseconds 900
  }
  $diag = if (@($lastPorts).Count -gt 0) { "端口 $($lastPorts -join ',') 已绑定但未就绪" } else { '未发现宿主子进程的监听端口' }
  Add-Step 'ready' "等待 DSH Desktop 就绪超时 ${MaxSec}s：$diag" 'fail'
  return [pscustomobject]@{ ok = $false; reason = 'timeout' }
}

function Remove-TreeSafe([string]$Dir) {
  # 含 junction 的目录：cmd rmdir 只删链接本身；PS5.1 的 Remove-Item -Recurse 可能跟进目标。
  if (-not (Test-Path -LiteralPath $Dir)) { return }
  try {
    $rp = Start-Process -FilePath (Get-SystemTool 'cmd') `
          -ArgumentList @('/c', 'rmdir', '/s', '/q', ('"' + $Dir + '"')) -PassThru -WindowStyle Hidden -ErrorAction Stop
    [void]$rp.WaitForExit(60000)
  } catch {
    & cmd.exe /c "rmdir /s /q `"$Dir`"" *> $null
  }
}

# ---------------------------------------------------------------- 主进程启动校验（gui-smoke）
# 深验证只证明「dsh-desktop-host 能起来」。Electron **主进程**自己的启动期校验（环境变量、
# 设置文件、policy）不在它的覆盖范围内。2026-11-27 实测：隔离宿主 401 通过，真主进程却因
# DSH_DESKTOP_UPDATE_CHECK_INTERVAL_MS 越界直接弹「应用无法启动」，而且主进程**继续存活**
# （只剩错误窗口）—— 旧的就绪等待只看 HasExited / 端口，白等到超时还说不出原因。
# 两层必须分开验：deep-verify 覆盖宿主，gui-smoke 覆盖主进程。

function Get-DesktopUserDataDir([string]$Exe) {
  if ($script:DesktopUserData) { return $script:DesktopUserData }
  $found = ''
  if ($Exe) {
    try {
      $paths = Get-DesktopPaths $Exe
      if ($paths) {
        $pkg = Join-Path $paths.appRoot 'package.json'
        if (Test-Path -LiteralPath $pkg -PathType Leaf) {
          $doc = Get-Content -LiteralPath $pkg -Raw -Encoding UTF8 | ConvertFrom-Json
          $name = [string]$doc.name
          if ($name -and $env:APPDATA) {
            $cand = Join-Path $env:APPDATA $name
            if (Test-Path -LiteralPath $cand) { $found = $cand }
          }
        }
      }
    } catch { }
  }
  if (-not $found -and $env:APPDATA) {
    # 布局无关的兜底：Electron 的崩溃日志固定在 <userData>\logs\crash-*-main.log。
    # 只扫两层（<vendor>\<app>），不递归整个 APPDATA。
    try {
      $hits = New-Object System.Collections.ArrayList
      foreach ($vendor in @(Get-ChildItem -LiteralPath $env:APPDATA -Directory -ErrorAction SilentlyContinue)) {
        foreach ($app in @(Get-ChildItem -LiteralPath $vendor.FullName -Directory -ErrorAction SilentlyContinue)) {
          $logs = Join-Path $app.FullName 'logs'
          if (-not (Test-Path -LiteralPath $logs)) { continue }
          $crash = Get-ChildItem -LiteralPath $logs -Filter 'crash-*-main.log' -File -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1
          if ($crash) { [void]$hits.Add([pscustomobject]@{ dir = $app.FullName; stamp = $crash.LastWriteTime }) }
        }
      }
      if ($hits.Count -gt 0) { $found = (@($hits | Sort-Object stamp -Descending)[0]).dir }
    } catch { }
  }
  $script:DesktopUserData = $found
  return $found
}

function Get-MainCrashRecord([string]$UserDataDir, [datetime]$Since, [int]$MainPid_) {
  <#
    读「主进程启动期崩溃」记录，返回最近一份 crash-*-main.log 的 Error 行。
    -MainPid_ > 0 时只认 shell pid 与它一致的文件（pid 复用/上一代残留都不会误报）。
  #>
  if (-not $UserDataDir) { return $null }
  $logs = Join-Path $UserDataDir 'logs'
  if (-not (Test-Path -LiteralPath $logs)) { return $null }
  $files = @(Get-ChildItem -LiteralPath $logs -Filter 'crash-*-main.log' -File -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -ge $Since } | Sort-Object LastWriteTime -Descending)
  foreach ($f in $files) {
    $head = @(Get-Content -LiteralPath $f.FullName -TotalCount 40 -ErrorAction SilentlyContinue)
    $shellPid = 0
    $pidLine = @($head | Where-Object { $_ -match '^shell pid:\s*(\d+)' } | Select-Object -First 1)
    if ($pidLine.Count -gt 0 -and $pidLine[0] -match '^shell pid:\s*(\d+)') { $shellPid = [int]$Matches[1] }
    if ($MainPid_ -gt 0 -and $shellPid -gt 0 -and $shellPid -ne $MainPid_) { continue }
    $errLine = @($head | Where-Object { $_ -match '^Error:' } | Select-Object -First 1)
    $msg = ''
    if ($errLine.Count -gt 0) { $msg = ([string]$errLine[0]).Trim() }
    return [pscustomobject]@{ path = $f.FullName; shellPid = $shellPid; error = $msg; time = $f.LastWriteTime }
  }
  return $null
}

function Invoke-WatchdogProbe([int]$MainPid, [string]$UserDataDir, [datetime]$SpawnedAt) {
  <#
    真机验证「就绪阶段崩溃看门狗」：在**临时** userData 里写一份主进程崩溃记录
    （shell pid 与本次冒烟的主进程一致），然后直接调用生产用的 Wait-DesktopHostReady，
    要求它在秒级内以 reason=main-crashed 失败，并把原始的 Error 行透传出来。

    边界要说清：注入的是一份崩溃**记录**，不是真的崩溃 —— 但读它的是生产代码、进程是真的、
    userData 是隔离的。「冒烟通过之后主进程才崩」在本机无法安全制造（那要把生产实例弄坏），
    所以这一层用注入来覆盖：检查的正是「崩溃日志出现 → 立即失败」这条分支。
  #>
  $logs = Join-Path $UserDataDir 'logs'
  New-Item -ItemType Directory -Force -Path $logs | Out-Null
  $text = "shell pid: $MainPid`r`nError: watchdog-probe injected crash record (expected)`r`n"
  $file = Join-Path $logs ('crash-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '-main.log')
  [System.IO.File]::WriteAllText($file, $text, (New-Object System.Text.UTF8Encoding($false)))
  $before = $script:Steps.Count
  $t0 = Get-Date
  $wd = Wait-DesktopHostReady $MainPid 15 $SpawnedAt -UserDataDir $UserDataDir
  $sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  # 探针借用了生产函数，它会往 steps 里写自己的 'ready' 行；那是探针的中间态，
  # 不该出现在本次动作的终态里（更不能把一次成功的重启变成 ok=false）。
  while ($script:Steps.Count -gt $before) { $script:Steps.RemoveAt($script:Steps.Count - 1) }
  $detected = (-not $wd.ok) -and ([string]$wd.reason -eq 'main-crashed') -and ([string]$wd.error -like '*watchdog-probe*')
  Add-Step 'watchdog' $(if ($detected) {
      "就绪阶段看门狗在 ${sec}s 内识别注入的崩溃记录（reason=main-crashed，错误文本已透传）"
    } else {
      "看门狗没有按预期识别注入的崩溃记录：ok=$($wd.ok) reason=$($wd.reason) error=$($wd.error)"
    }) $(if ($detected) { 'ok' } else { 'warn' })
  try { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue } catch { }
  return [pscustomobject]@{ ok = $detected; sec = $sec }
}

function Test-DesktopGuiStartup {
  param([switch]$WatchdogProbe)
  <#
    真起一次 Electron **主进程**（不是宿主），确认它能过启动期校验并拉起自己的宿主。
    隔离：--user-data-dir 指向临时目录（Electron 的单实例锁按 userData 分域，实测不会碰
    正在跑的生产实例），DSH_HOME 也指向临时目录。
    判据只到「宿主子进程出现」：主进程已解析完配置并进入 spawn 阶段；宿主能否服务由
    deep-verify 负责，不在这里重复等 60-140s。
  #>
  $exe = Resolve-DesktopAppPath
  if (-not $exe) {
    Add-Step 'gui-smoke' '找不到 DSH Desktop 可执行文件 → 无法做主进程冒烟（深度验证仍会真起宿主）' 'warn'
    return [pscustomobject]@{ ok = $true; reason = 'app-missing'; skipped = $true }
  }
  $root = if ($VerifyTempRoot) { $VerifyTempRoot } else { $env:TEMP }
  if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
  $probe = Join-Path $root ('dsh-gui-smoke.' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $ud = Join-Path $probe 'userdata'
  $home2 = Join-Path $probe 'home'
  $p = $null
  $start = Get-Date
  try {
    New-Item -ItemType Directory -Force -Path $ud, $home2 | Out-Null
    # 真实 settings.json 里可能有启动期会读的开关；复制过去，避免「临时 userData = 首次运行」。
    try {
      $realUd = Get-DesktopUserDataDir $exe
      if ($realUd) {
        $srcSettings = Join-Path $realUd 'desktop\settings.json'
        if (Test-Path -LiteralPath $srcSettings -PathType Leaf) {
          New-Item -ItemType Directory -Force -Path (Join-Path $ud 'desktop') | Out-Null
          Copy-Item -LiteralPath $srcSettings -Destination (Join-Path $ud 'desktop\settings.json') -Force
        }
      }
    } catch { }

    $plan = Get-RegistryEnvironmentBlock
    $env2 = @{}
    foreach ($n in $plan.Names) { if ($n -and $n -ine 'Path') { $env2[$n] = [string]$plan.Block[$n] } }
    $env2['PATH'] = [string]$plan.PathValue
    $env2['DSH_HOME'] = $home2
    if ($env2.ContainsKey('ELECTRON_RUN_AS_NODE')) { $env2.Remove('ELECTRON_RUN_AS_NODE') }

    $p = Start-Process -FilePath $exe -ArgumentList @("--user-data-dir=$ud") -WorkingDirectory (Split-Path $exe -Parent) -Environment $env2 -PassThru
    $deadline = $start.AddSeconds(25)
    while ((Get-Date) -lt $deadline) {
      $crash = Get-MainCrashRecord $ud $start.AddSeconds(-3) $p.Id
      if ($crash -and $crash.error) {
        $keep = Join-Path $StateDir ('gui-smoke-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        try { Copy-Item -LiteralPath $crash.path -Destination $keep -Force } catch { }
        Add-Step 'gui-smoke' ('主进程启动即失败：' + $crash.error + '（崩溃日志：' + $keep + '）') 'fail'
        return [pscustomobject]@{ ok = $false; reason = 'main-crashed'; error = $crash.error; log = $keep }
      }
      if ($p.HasExited) {
        Add-Step 'gui-smoke' ('主进程在 ' + [int]((Get-Date) - $start).TotalSeconds + 's 内退出（exit=' + $p.ExitCode + '），没有拉起宿主') 'fail'
        return [pscustomobject]@{ ok = $false; reason = 'exited'; error = '' }
      }
      $kids = @(Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $p.Id) -ErrorAction SilentlyContinue)
      foreach ($k in $kids) {
        if ($k.CommandLine -and $k.CommandLine -match 'dsh-desktop-host[\\/]lib[\\/]index\.js') {
          Add-Step 'gui-smoke' ('主进程 ' + [int]((Get-Date) - $start).TotalSeconds + 's 内完成启动期校验并拉起宿主 pid=' + $k.ProcessId + '（临时 userData，未触碰生产实例）') 'ok'
          if ($WatchdogProbe) {
            $wd = Invoke-WatchdogProbe -MainPid $p.Id -UserDataDir $ud -SpawnedAt $start
            # 普通重启：探针失败只留 warn（检测层坏了不该拦住一次能成功的重启）；
            # -Preflight 是验收闸门：它不过就不许停生产实例。
            if (-not $wd.ok -and $Preflight) {
              Add-Step 'abort' '就绪阶段看门狗对注入的崩溃记录没有反应 → -Preflight 判定验收失败，停机前中止' 'fail'
              return [pscustomobject]@{ ok = $false; reason = 'watchdog-probe-failed' }
            }
          }
          return [pscustomobject]@{ ok = $true; reason = 'host-spawned'; hostPid = [int]$k.ProcessId }
        }
      }
      Start-Sleep -Milliseconds 600
    }
    Add-Step 'gui-smoke' '主进程 25s 内既没拉起宿主、也没写崩溃日志 → 无法确认它能启动（fail-closed）' 'fail'
    return [pscustomobject]@{ ok = $false; reason = 'timeout' }
  } finally {
    if ($p -and -not $p.HasExited) { try { & (Get-SystemTool 'taskkill') /PID $p.Id /T /F *> $null } catch { } }
    Start-Sleep -Milliseconds 600
    try { Remove-TreeSafe $probe } catch { }
  }
}

function Test-DesktopVerify {
  <#
    桌面版深度验证：用 App 自带的 Electron（Node 模式）直接起宿主入口，隔离 DSH_HOME +
    复制出来的 profile（node_modules 逐项 junction）。与主进程 spawn 的形状一致，
    端口是 --port 0 分配的，起来后用 netstat 反查。
  #>
  $root = if ($VerifyTempRoot) { $VerifyTempRoot } else { $env:TEMP }
  if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
  $v = Join-Path $root ("dsh-desktop-verify." + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $p = $null
  $keepLog = $false
  $vPort = 0
  try {
    New-Item -ItemType Directory -Path $v -Force | Out-Null
    $vProfile = Join-Path $v ('profiles\' + $Profile)
    New-Item -ItemType Directory -Path $vProfile -Force | Out-Null
    # 共享投影：宿主解析 @deepseek-ai/* 用的是 <home>\profiles\node_modules（pnpm install 会删掉它，
    # 2026-11-15 实测：删掉后桌面版 App 连基础包都 import 不到、直接起不来）。
    # 隔离实例必须把这份投影也带上，否则深度验证会误报「基础包找不到」。
    $sharedSrc = Join-Path $DshHome 'profiles\node_modules'
    $sharedDst = Join-Path $v 'profiles\node_modules'
    if ((Test-Path -LiteralPath $sharedSrc) -and -not (Test-Path -LiteralPath $sharedDst)) {
      New-Item -ItemType Directory -Force -Path (Join-Path $v 'profiles') | Out-Null
      try { New-Item -ItemType Junction -Path $sharedDst -Target $sharedSrc -ErrorAction Stop | Out-Null } catch { }
    }
    $srcProfile = Join-Path $DshHome ('profiles\' + $Profile)
    if (-not (Test-Path -LiteralPath $srcProfile)) {
      $existing = @(Get-ChildItem -LiteralPath (Join-Path $DshHome 'profiles') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
      $why = "真实 profile 不存在：$srcProfile（-Profile '$Profile' 是否正确？现有 profile：$($existing -join ', ')）"
      Add-Step 'deep-verify' $why 'fail'
      return [pscustomobject]@{ ok = $false; reason = 'profile-missing' }
    }
    foreach ($f in (Get-ChildItem -LiteralPath $srcProfile -File -Force -ErrorAction SilentlyContinue)) {
      Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $vProfile $f.Name) -Force -ErrorAction SilentlyContinue
    }
    $srcFallback = Join-Path $srcProfile '.dsh-module-fallback'
    if (Test-Path -LiteralPath $srcFallback) {
      Copy-TreeWithLinks $srcFallback (Join-Path $vProfile '.dsh-module-fallback')
    }
    $srcNm = Join-Path $srcProfile 'node_modules'
    if (-not (Test-Path -LiteralPath $srcNm)) {
      $why = "真实 profile 缺少 node_modules（$srcNm）→ 隔离验证实例组装不出依赖"
      Add-Step 'deep-verify' $why 'fail'
      return [pscustomobject]@{ ok = $false; reason = 'profile-missing-node-modules' }
    }
    $vNm = Join-Path $vProfile 'node_modules'
    New-Item -ItemType Directory -Force -Path $vNm | Out-Null
    foreach ($it in (Get-ChildItem -LiteralPath $srcNm -Force -ErrorAction SilentlyContinue)) {
      $linkPath = Join-Path $vNm $it.Name
      if ($it.Name -like '@*' -and $it.PSIsContainer) {
        # 作用域目录里可能是 pnpm 的**相对**符号链接（link: 依赖）：整个目录做 junction
        # 会让相对目标按临时路径解析而失效（实测：bundle 被跳过且只在 stderr 留一行）。
        # 这里复刻一层真目录，子项各自用绝对路径 junction，链接目标维持真实位置。
        New-Item -ItemType Directory -Force -Path $linkPath | Out-Null
        foreach ($sub in (Get-ChildItem -LiteralPath $it.FullName -Force -ErrorAction SilentlyContinue)) {
          try { New-Item -ItemType Junction -Path (Join-Path $linkPath $sub.Name) -Target $sub.FullName -ErrorAction Stop | Out-Null } catch { }
        }
      } else {
        try { New-Item -ItemType Junction -Path $linkPath -Target $it.FullName -ErrorAction Stop | Out-Null } catch { }
      }
    }
    $vnFb = Join-Path $vProfile '.dsh-module-fallback\node_modules'
    foreach ($entry in (Get-ChildItem -LiteralPath $vnFb -Force -ErrorAction SilentlyContinue)) {
      if ($entry.Name -like '@*' -and $entry.PSIsContainer) {
        foreach ($sub in (Get-ChildItem -LiteralPath $entry.FullName -Force -ErrorAction SilentlyContinue)) {
          $link = Join-Path (Join-Path $vNm $entry.Name) $sub.Name
          if (-not (Test-Path -LiteralPath $link)) {
            New-Item -ItemType Directory -Force -Path (Split-Path $link -Parent) | Out-Null
            try { New-Item -ItemType Junction -Path $link -Target $sub.FullName -ErrorAction Stop | Out-Null } catch { }
          }
        }
      } elseif (-not (Test-Path -LiteralPath (Join-Path $vNm $entry.Name))) {
        try { New-Item -ItemType Junction -Path (Join-Path $vNm $entry.Name) -Target $entry.FullName -ErrorAction Stop | Out-Null } catch { }
      }
    }

    $paths = $null
    $exe = Resolve-DesktopAppPath
    if ($exe) { $paths = Get-DesktopPaths $exe }
    if (-not $paths) {
      Add-Step 'deep-verify' '找不到 DSH Desktop 可执行文件 → 无法做桌面版深度验证；用 -Record 记录启动命令后重试' 'fail'
      return [pscustomobject]@{ ok = $false; reason = 'desktop-app-missing' }
    }
    if (-not (Test-DesktopRuntime $paths)) {
      Add-Step 'deep-verify' "找不到桌面版运行时（既没有 app.asar，也没有 resources\app\dsh）：$($paths.appRoot)\resources" 'fail'
      return [pscustomobject]@{ ok = $false; reason = 'desktop-entry-missing' }
    }

    $out = Join-Path $v 'boot.out'
    $err = Join-Path $v 'boot.err'
    $env2 = @{
      ELECTRON_RUN_AS_NODE = '1'
      DSH_HOME = $v
      DSH_UC_PROFILE_NODE_MODULES = $vNm
    }
    $vArgs = @('--expose-internals', $paths.entry, $paths.runtimeDir, $vProfile, $paths.primaryRuntime, $paths.pnpm, $paths.nodeBin)
    $p = Start-Process -FilePath $paths.exe -ArgumentList $vArgs `
         -WorkingDirectory $vProfile -WindowStyle Hidden -Environment $env2 `
         -RedirectStandardOutput $out -RedirectStandardError $err -PassThru

    $deadline = (Get-Date).AddSeconds($VerifyReadySec)
    # 动作总预算同样封顶（见 Set-ActionBudget）：桌面版深验证是整条链里最长的一段，
    # 实测本机就要 70s+，机器慢或插件多时能顶到 150s。
    if ($script:ActionDeadline -and $script:ActionDeadline -lt $deadline) { $deadline = $script:ActionDeadline }
    $lastHttp = 0
    $fatal = ''
    $lastScan = Get-Date
    $verifyStart = Get-Date
    $verifyRound = 0
    $script:NetstatRows = @()
    $nextNetstat = (Get-Date).AddYears(-1)
    while ((Get-Date) -lt $deadline) {
      $verifyRound++
      # 心跳：这一步在本机要 70s 起步，没有这行台账，命令行和「卡死」长得一模一样。
      Write-Activity 'deep-verify' ("等待隔离桌面宿主就绪：第 " + $verifyRound + " 轮，已等 " +
        [int]((Get-Date) - $verifyStart).TotalSeconds + "s / 预算 " + $VerifyReadySec + "s" +
        $(if ($null -ne (Get-BudgetLeftSec)) { "（本次动作剩余 " + (Get-BudgetLeftSec) + "s）" } else { '' }) +
        $(if ($lastHttp -gt 0) { "，最后 HTTP=$lastHttp" } else { '' }))
      Write-ProgressLine 'deep-verify' ("隔离桌面宿主，第 " + $verifyRound + " 轮" +
        $(if ($lastHttp -gt 0) { "，HTTP " + $lastHttp } else { '，尚未监听' }))
      if ((Get-Date) -ge $nextNetstat) { $script:NetstatRows = Get-NetstatListenerRows -Refresh; $nextNetstat = (Get-Date).AddSeconds(2) }
      if ($p.HasExited) { break }
      # 启动期致命错误要立刻收手：某些插件在隔离宿主里会挂住（例如 tailscale 入口冲突反复重试），
      # 干等预算只会让一次 -Preflight/重启看起来像卡死。
      if (((Get-Date) - $lastScan).TotalSeconds -ge 4) {
        $lastScan = Get-Date
        try {
          if (Test-Path -LiteralPath $err) {
            $tailText = (@(Get-Content -LiteralPath $err -Tail 60 -ErrorAction SilentlyContinue) -join "`n")
            foreach ($marker in @('StartupError', 'DesktopHostFatalError', 'desktop welcome: Web RPC failed')) {
              if ($tailText -like ('*' + $marker + '*')) { $fatal = $marker; break }
            }
          }
        } catch { }
        if ($fatal) { break }
      }
      $ports = @(Get-ListeningPorts $p.Id $script:NetstatRows)
      if ($ports.Count -gt 0) {
        $pick = Resolve-HostPort $ports
        $lastHttp = $pick.status
        if ($pick.port -gt 0 -and ($pick.status -eq 401 -or $pick.status -eq 200)) {
          $vPort = $pick.port
          Add-Step 'deep-verify' ("桌面宿主隔离实例 $($pick.port) 就绪 HTTP=$($pick.status)（Electron Node 模式 + 临时 home，探测 $($pick.probed) 个端口）") 'ok'
          return [pscustomobject]@{ ok = $true; port = $pick.port; http = $pick.status; logdir = $v }
        }
      }
      Start-Sleep -Milliseconds 800
    }
    $keepLog = $true
    $tail = @()
    foreach ($f in @($out, $err)) {
      if (Test-Path -LiteralPath $f) {
        $l = @(Get-Content -LiteralPath $f -Encoding UTF8 -ErrorAction SilentlyContinue)
        $tail += ($l | Select-Object -Last 15)
        $tail += ($l | Select-String -Pattern 'error|throw|failed|EPERM|EADDRINUSE|unknown option' | Select-Object -First 10 | ForEach-Object { $_.Line })
      }
    }
    $script:VerifyTail = $tail
    $why = if ($fatal) { "启动期致命错误（$fatal）" }
           elseif ($p.HasExited) { "进程已退出（exit=$($p.ExitCode)）" }
           elseif ($lastHttp -eq 404) { "端口已绑但 $VerifyReadySec s 内路由未就绪（404）" }
           elseif ($lastHttp -eq 0) { "$VerifyReadySec s 内端口未响应（进程仍存活，多半是插件在启动期挂住）" }
           else { "最后状态码 $lastHttp" }
    Add-Step 'deep-verify' ("桌面宿主隔离实例未就绪：$why；日志保留在 $v") 'fail'
    return [pscustomobject]@{ ok = $false; reason = 'not-ready'; logdir = $v; tail = $tail; retryable = [bool]$p.HasExited }
  } catch {
    Add-Step 'deep-verify' "桌面验证实例启动异常: $($_.Exception.Message)" 'fail'
    return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
  } finally {
    if ($p) {
      try {
        $tk = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\taskkill.exe') `
              -ArgumentList @('/PID', [string]$p.Id, '/T', '/F') -PassThru -WindowStyle Hidden -ErrorAction Stop
        [void]$tk.WaitForExit(8000)
      } catch { try { & (Get-SystemTool 'taskkill') /PID $p.Id /T /F *> $null } catch { } }
      Start-Sleep -Milliseconds 400
    }
    if ($keepLog) { Add-Step 'deep-verify-cleanup' "失败日志保留：$v" 'warn' }
    else { Remove-TreeSafe $v }
  }
}

# ================================================================ 主流程

$exit = 1
try {
  # ---- -0. 交接模式（desktop host）：先把自己的 pid 写进 launch 记录。
  #      独立执行的 supervisor 可能已经被宿主进程树带走，宿主侧靠这条记录跟踪引擎。
  if ($LaunchRecord) {
    try {
      $rec = [ordered]@{ phase = 'engine-running'; enginePid = $PID; at = (Get-NowIso); via = 'handoff' }
      New-Utf8NoBom $LaunchRecord ($rec | ConvertTo-Json -Compress)
    } catch { }
  }

  Add-Phase 'prepare'
  # ---- 0. 分离执行支撑的入参（新增参数：只影响入参校验，不改任何既有退出码语义）
  #   -ResultFile 必须先证明写得进去再动手：否则一次重启成功后却拿不到结果文件，消费方
  #   只能靠超时判失败。写不进去属于「入参不可用」，按既有 invalid-args 语义退出 2。
  if ($ResultFile) {
    if (-not [System.IO.Path]::IsPathRooted($ResultFile)) { $ResultFile = Join-Path (Get-Location).Path $ResultFile }
    $ResultFile = [System.IO.Path]::GetFullPath($ResultFile)
    $resultDir = Split-Path -Path $ResultFile -Parent
    if ($resultDir -and -not (Test-Path -LiteralPath $resultDir)) {
      try { New-Item -ItemType Directory -Force -Path $resultDir | Out-Null }
      catch {
        Add-Step 'result-file' ("-ResultFile 的目录无法创建：" + $resultDir + " :: " + $_.Exception.Message.Split([char]10)[0]) 'fail'
        Write-Terminal 'invalid-args' 2
        exit 2
      }
    }
    $writeProbe = $null
    try {
      $writeProbe = Join-Path -Path $resultDir -ChildPath ('.dsh-restart-probe-' + [guid]::NewGuid().ToString('N'))
      [System.IO.File]::WriteAllText($writeProbe, 'probe', (New-Object System.Text.UTF8Encoding($false)))
      Remove-Item -LiteralPath $writeProbe -Force -ErrorAction Stop
      $writeProbe = $null
    } catch {
      Add-Step 'result-file' ("-ResultFile 不可写：" + $ResultFile + " :: " + $_.Exception.Message.Split([char]10)[0]) 'fail'
      Write-Terminal 'invalid-args' 2
      exit 2
    } finally {
      if ($writeProbe -and (Test-Path -LiteralPath $writeProbe)) { Remove-Item -LiteralPath $writeProbe -Force -ErrorAction SilentlyContinue }
    }
    Add-Step 'result-file' ("结果将落盘到 " + $ResultFile) 'ok'
  }
  if ($NoWait -and -not $ResultFile) {
    # 不是错误：-NoWait 单独用只是「收尾不等待」，但分离执行方因此读不到结果文件 —— 明确提示
    Add-Step 'no-wait' '-NoWait 已开启但没有 -ResultFile：结果只写日志与 restart-history.jsonl，分离执行方读不到' 'warn'
  }

  # ---- 0-host. 宿主形态（auto → web/desktop）：必须在取锁之前，互斥体名字依赖它
  Add-Phase 'pre-check'
  Resolve-HostKind
  Add-Phase 'host-kind'
  Add-Step 'host-kind' $(if ($script:HostKind -eq 'desktop') { 'desktop：DSH Desktop（Electron 主进程 + dsh-desktop-host 子进程，端口实测）' } else { 'web：dsh web 进程（按端口发现）' }) 'ok'
  Resolve-DesktopProfileName

  if ($UnregisterTask) {
    $o = & (Get-SystemTool 'schtasks') /Delete /TN $TaskName /F 2>&1
    Add-Step 'unregister-task' (("$o") -replace "`r?`n", ' ').Trim() $(if ($LASTEXITCODE -eq 0) { 'ok' } else { 'fail' })
    Write-Terminal 'task-unregistered' $(if ($LASTEXITCODE -eq 0) { 0 } else { 1 })
    # 必须用 Write-Terminal 算出来的退出码（旧引擎这里写死 exit 0）：schtasks /Delete 失败时
    # 信封里已是 ok=false/exitCode=1，但进程退出码若是 0，命令行调用方一判 $LASTEXITCODE 就假成功。
    exit $script:ExitCode
  }

  if ($RegisterTask) {
    $ok = Register-RestartTask
    Write-Terminal $(if ($ok) { 'task-registered' } else { 'task-register-failed' }) $(if ($ok) { 0 } else { 1 })
    exit $(if ($ok) { 0 } else { 1 })
  }

  if ($ViaTask) {
    # 用户入口：让计划任务去跑真正的重启，本进程立刻返回（执行者因此脱离 DSH 进程树）
    $ok = Invoke-ViaTask
    if (-not $ok) {
      Add-Step 'via-task' "提示：先跑 dsh-restart -RegisterTask 注册任务；若任务不存在会失败" 'warn'
      Write-Terminal 'via-task-failed' 9
      exit 9
    }
    Add-Step 'via-task' '已交给计划任务执行；本次重启的终态记录见 $StateDir\dsh-restart.log（由任务内的进程写入）' 'ok'
    Write-Terminal 'via-task-dispatched' 0
    exit 0
  }

  if ($CheckShadowed) {
    $shadow = Repair-ShadowedBasePackages
    if (-not $shadow.ok) {
      Add-Step 'shadowed' ("无法检查：" + $shadow.reason) 'fail'
      Write-Terminal 'shadowed-check-failed' 1
      exit 1
    }
    if ($shadow.moved.Count -eq 0) {
      Add-Step 'shadowed' 'profile 里没有遮蔽基础包的旧版本（@deepseek-ai/* 版本与 App 一致）' 'ok'
    } else {
      Add-Step 'shadowed' ("已移走旧版本：" + ($shadow.moved -join '；') + "（备份在 .stale-packages）") 'warn'
    }
    Write-Terminal 'shadowed-checked' 0
    exit 0
  }

  if ($CleanupOrphans) {
    $res = Stop-OrphanDesktopHosts -DryRunOnly:$DryRun
    $code = 0
    if ($res.skipped.Count -gt 0 -and $res.killed.Count -eq 0 -and -not $DryRun) { $code = 1 }
    Write-Terminal $(if ($res.killed.Count -gt 0) { 'orphans-cleaned' } elseif ($DryRun) { 'orphans-listed' } else { 'orphans-none' }) $code
    exit $code
  }

  if ($RepairSharedScope) {
    if ($DryRun) {
      # 演练：只回答「会从哪来、到哪去、现在是什么形状」，一个字节都不写。
      # 旧行为是 -DryRun 照样重建（要几十秒、动 <DSH_HOME>\profiles\node_modules），
      # 与「演练不写入」的承诺矛盾 —— 2026-11-27 修。
      $exe = Resolve-DesktopAppPath
      $root = Get-SharedScopePath
      $curFiles = 0; $curBytes = [int64]0
      if (Test-Path -LiteralPath $root) {
        $cur = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue)
        $curFiles = $cur.Count
        if ($curFiles -gt 0) { $curBytes = [int64](($cur | Measure-Object Length -Sum).Sum) }
      }
      $layout = 'missing'
      $srcNote = '(找不到 DSH Desktop)'
      if ($exe) {
        $paths = Get-DesktopPaths $exe
        if (Test-Path -LiteralPath $paths.asar -PathType Leaf) { $layout = 'app.asar'; $srcNote = $paths.asar }
        elseif (Test-Path -LiteralPath (Join-Path $paths.runtimeDir 'node_modules') -PathType Container) {
          $layout = 'unpacked'; $srcNote = (Join-Path $paths.runtimeDir 'node_modules')
        }
      }
      Add-Step 'shared-scope' ("-DryRun：将用 $layout 重建 $root（当前 $curFiles 个文件 / " +
        [math]::Round($curBytes / 1MB, 1) + "MB）；源：" + $srcNote + "；不写盘") 'warn'
      Write-Terminal 'dry-run' 0
      exit 0
    }
    $rep = Repair-SharedScope
    if ($rep.ok) {
      Add-Step 'shared-scope' ("已重建共享投影 " + (Get-SharedScopePath) + "：" + $rep.stats.Files + " 个文件、" +
        [math]::Round($rep.stats.Bytes / 1MB, 1) + "MB、" + $rep.elapsedSec + "s（unpacked " + $rep.stats.Unpacked +
        "，跳过 " + $rep.stats.Skipped + "）") 'ok'
      Write-Terminal 'shared-scope-repaired' 0
      exit 0
    }
    Add-Step 'shared-scope' ("重建共享投影失败：" + $rep.reason) 'fail'
    Write-Terminal 'shared-scope-failed' 1
    exit 1
  }

  if ($Record) {
    # 桌面版：给了 -DesktopApp 就以它为准构造启动命令，省掉手写引号的坑。
    if ($script:HostKind -eq 'desktop' -and $DesktopApp -and -not $RecordCommand) {
      $RecordCommand = '"' + $DesktopApp + '"'
    }
    $cmd = if ($RecordCommand) { $RecordCommand } else { 'pnpm dsh web --no-open --host 127.0.0.1 --port {PORT}' }
    $cwd = if ($RecordWorkingDirectory) { $RecordWorkingDirectory } else { (Get-Location).Path }
    $r = Save-BootRecord $cmd $cwd
    Add-Step 'record' "启动档案已写入 $((Get-StatePath 'boot-record.json'))：$cmd (cwd=$cwd)" 'ok'
    Write-Terminal 'recorded' 0
    exit 0
  }

  # ---- 0. 锁（只读的 -Status 不取锁：面板每 8s 刷一次状态，取锁会把真正的动作挤成 locked）
  if (-not $Status) {
    if (-not (Enter-RestartLock)) {
      Add-Step 'lock' "已有另一个 dsh-restart 在跑（$(Get-MutexName)），立刻退出" 'fail'
      Write-Terminal 'locked' 2
      exit 2
    }
    Add-Step 'lock' ("已取得互斥体 " + (Get-MutexName) + "（句柄不继承）") 'ok'
    # 从这一刻起「有人在干活」是可观察的了：先落一行台账，再算本次动作的预算。
    # 顺序要紧 —— 台账必须在第一个可能耗时的步骤（幂等闸门里的进程/端口探测、深度验证）之前。
    Set-ActionBudget
    $script:ActivityOn = $true
    Write-Activity 'lock' ("取得重启锁；本次动作预算 " + $script:ActionBudgetSec + "s")
    if ($script:ActionBudgetSec -gt 0) {
      Add-Step 'budget' ("本次动作预算 " + $script:ActionBudgetSec + "s = " + (Format-BudgetParts) +
        "；每层等待都引用这个截止时刻，超出即明确失败") 'ok'
      # 人读模式先打一行「怎么读这几行输出」，避免把进度行当成新的问题。
      if (-not $Json) { Write-Diag ('      （等待中每 ' + $ProgressSec + 's 打一行「..」进度，人读模式写到控制台、-Json 写到 stderr）') }
    }
  } else {
    Add-Step 'lock' '只读状态：不取重启锁（不阻塞也不会被阻塞）' 'skip'
  }

  # ---- 0a. 引擎能力闸门：验证型重启需要 pwsh 7（5.1 缺 Start-Process -Environment 与
  #      New-Item -ItemType SymbolicLink）。必须在**停机之前**明确报错 —— 否则异常会落在
  #      深度验证/回滚阶段，把机器留在更难收拾的状态。
  $needsDeepVerify = ($VerifyOnly -or $Preflight) -or `
    ((-not $Status) -and (-not $Stop) -and (-not $Start) -and (-not $Fast) -and (-not $DryRun))
  if ($needsDeepVerify) {
    $ps7 = Get-Ps7RuntimeStatus
    if (-not $ps7.Ok) {
      Add-Step 'engine' ("当前引擎 " + $ps7.Reason + "：验证型重启需要的 Start-Process -Environment 与符号链接在 Windows PowerShell 5.1 上不可用") 'fail'
      Add-Step 'engine' '请改用 pwsh 7 运行：pwsh -NoProfile -File "$env:LOCALAPPDATA\dsh-restart\bin\dsh-restart.ps1" -Preflight；或用 pwsh 重跑 -RegisterTask，让计划任务引擎也指向 pwsh.exe' 'fail'
      Write-Terminal 'engine-requires-pwsh' 2
      exit 2
    }
  }

  if ($Status) { Show-Status; Write-Terminal 'status' 0; exit 0 }

  # ---- 0b. 只跑深度验证配方（验收/排障用，完全不碰生产实例）
  # 主进程冒烟也属于「验证配方」：深验证只覆盖 dsh-desktop-host，主进程自己的启动期校验
  # （DSH_DESKTOP_* 环境变量、设置、policy）不在其中。先真起一次主进程（临时 userData），
  # 2-5s 就能给出结论；失败时不用白等 60-150s 的深验证。
  if (($VerifyOnly -or $Preflight) -and $script:HostKind -eq 'desktop') {
    if ($SkipGuiProbe) { Add-Step 'gui-smoke' '-SkipGuiProbe：跳过主进程冒烟（主进程启动期校验未覆盖）' 'warn' }
    else {
      $gui = Test-DesktopGuiStartup -WatchdogProbe
      if (-not $gui.ok) { Write-Terminal 'verify-only-failed' 4; exit 4 }
    }
  }
  if ($VerifyOnly -or $Preflight) {
    # 存储预检是验证配方的一部分：workspace.json 写坏时，深验证会「真起一个宿主」，
    # 而那个宿主同样会在 workspace 域 FAILED —— 先在这里把根因说清楚。
    if (-not (Test-StorageGate)) { Write-Terminal 'storage-invalid' 3; exit 3 }
    $symOk = Test-SymlinkPrivilege
    $script:VerifyTail = @()
    # 这一步以前只有「开始」和「结果」两条记录，中间的 60-200s 完全静默 —— 命令行里看起来
    # 就是没反应。先打一条预算，再让 Test-DeepVerify 的循环每 2s 更新台账心跳。
    Add-Step 'deep-verify' ("开始隔离实例验证（上限 " + $VerifyReadySec + "s" +
      $(if ($null -ne (Get-BudgetLeftSec)) { "，本次动作剩余预算 " + (Get-BudgetLeftSec) + "s" } else { '' }) +
      "）：起步就要复制 profile 并拉起一个一次性的桌面宿主，这一段是本工具最长的等待") 'ok'
    $dv = Invoke-DeepVerifyWithRetry
    if ($dv -and $dv.ok) { Write-Terminal 'verify-only-ok' 0; exit 0 }
    # StrictMode 2.0：$dv 可能是 catch 路径返回的 { ok; error }（没有 tail 属性），
    # 直接写 `$dv.tail` 会抛 PropertyNotFoundException → 失败路径变成 exit 1 而不是约定的 4。
    # 因此经 PSObject.Properties 安全取，缺失就当作没有 tail。
    $dvTail = @()
    if ($dv) {
      $tailProp = $dv.PSObject.Properties['tail']
      if ($tailProp -and $tailProp.Value) { $dvTail = @($tailProp.Value) }
    }
    if ($dvTail.Count -gt 0) { $dvTail | ForEach-Object { Write-Diag "      | $_" } }
    if (-not $symOk) {
      Add-Step 'conclusion' '根因：本机无开发者模式且当前非管理员 → 宿主无法建符号链接。这不是脚本缺陷；按上面的修复路径处理后重跑本命令即可通过。' 'fail'
    }
    Write-Terminal 'verify-only-failed' 4
    exit 4
  }

  # ---- 1. 发现目标实例（@() 强制成数组：严格模式 2.0 下单元素数组会被解包成单对象，没有 .Count）
  $instances = @(Get-DshInstances)
  if ($instances.Count -gt 1) {
    Add-Step 'discover' "端口 $Port 有多个监听者：$($instances.pid -join ',')" 'warn'
  }
  if ($instances.Count -ge 1) {
    $script:TargetPid = $instances[0].pid
    Add-Step 'discover' "目标 pid=$($script:TargetPid) name=$($instances[0].name) 内存=$($instances[0].ws_mb)MB 启动=$($instances[0].start)" 'ok'
  } else {
    Add-Step 'discover' "端口 $Port 无监听者（冷启动或已停）" $(if ($Start) { 'ok' } else { 'warn' })
  }

  # ---- 1a. desktop：端口是实测值，停机目标是 Electron 主进程（不是宿主子进程）
  if ($script:HostKind -eq 'desktop') {
    if ($instances.Count -ge 1) {
      $script:Desktop = $instances[0]
      $script:MainPid = $instances[0].mainPid
      $script:DesktopAppPath = $instances[0].exe
      if (-not $script:ProfileExplicit -and $instances[0].profile -and $Profile -ne $instances[0].profile) {
        Add-Step 'profile' "profile 自动取自运行中的宿主：$($instances[0].profile)（默认值 $Profile 是 dsh web 的）" 'ok'
        $Profile = [string]$instances[0].profile
      }
      if ($instances[0].port -gt 0) { $Port = $instances[0].port; $script:ResolvedPort = $Port }
      Add-Step 'discover' "桌面版：主进程 pid=$($script:MainPid)，宿主 pid=$($instances[0].pid)，实测端口 $(if ($instances[0].port -gt 0) { $instances[0].port } else { '未就绪' })（配置端口 $($script:ConfiguredPort) 仅作期望值）" 'ok'
    } else {
      Add-Step 'discover' "桌面版：没有运行中的 DSH Desktop 宿主（冷启动；启动档案 exe=$(if (Resolve-DesktopAppPath) { Resolve-DesktopAppPath } else { '未找到' })）" $(if ($Start) { 'ok' } else { 'warn' })
      $bootRec = Get-BootRecord
      if (-not $script:ProfileExplicit -and $bootRec -and $bootRec.profile) {
        Add-Step 'profile' "profile 自动取自启动档案：$($bootRec.profile)" 'ok'
        $Profile = [string]$bootRec.profile
      }
    }
  }

  # ---- 1b. 只停机（-Stop）：不深度验证、不写续跑通知、不拉起 —— 跨端口迁移/彻底关停用
  #      为什么必须有：实例发现是**按端口**做的，重启路径只会停 $Port 上的实例；旧实例在
  #      另一个端口时（例如从 <旧端口> 迁到 <新端口>）就没有任何原语能停掉它，只能手工 taskkill。
  if ($Stop) {
    if ($Start) {
      Add-Step 'stop' '-Stop 与 -Start 互斥：-Stop 只停机、不拉起' 'fail'
      Write-Terminal 'invalid-args' 2
      exit 2
    }
    if ($DryRun) {
      if ($script:TargetPid) {
        Add-Step 'dry-run' "将执行的停机: taskkill /PID $($script:TargetPid) /T /F（先温和 /T 再强杀），随后等端口 $Port 释放；**不拉起、不写续跑通知**" 'ok'
      } else {
        Add-Step 'dry-run' "端口 $Port 无监听者：无停机动作；**不拉起、不写续跑通知**" 'warn'
      }
      Write-Terminal 'dry-run' 0
      exit 0
    }
    if (-not $script:TargetPid) {
      Add-Step 'stop' "端口 $Port 无监听者，无需停机" 'skip'
      Write-Terminal 'stopped' 0
      exit 0
    }
    if (-not $instances[0].isNode) {
      Add-Step 'stop' "端口 $Port 的占用者是 $($instances[0].name)（pid=$($script:TargetPid)），不是 node/dsh/bun → 拒绝 -Stop，避免误杀无关进程" 'fail'
      Write-Terminal 'stop-refused' 12
      exit 12
    }
    # 门禁保留：正在进行的配置操作（导入/插件安装）期间停机会留下半残状态
    $stopGate = Test-ConfigOperationGate
    if ($stopGate -and @($stopGate).Count -gt 0) {
      $stopAdvice = Get-StaleEnvLockAdvice
      if ($stopAdvice) {
        Add-Step 'gate' "检测到配置操作残留（$(@($stopGate).Count) 项）：$((@($stopGate) | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ',') → 拒绝停机（fail-closed）" 'fail'
        Add-Step 'gate' $stopAdvice 'fail'
      } else {
        Add-Step 'gate' "检测到进行中的配置操作痕迹（$(@($stopGate).Count) 项）：$((@($stopGate) | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ',') → 拒绝停机" 'fail'
      }
      Write-Terminal 'gate-blocked' 5
      exit 5
    }
    Add-Step 'gate' '无进行中的配置操作痕迹' 'ok'
    if (-not (Test-HostAlive $script:TargetPid $Port)) {
      Add-Step 'stop' "目标 pid=$($script:TargetPid) 未通过判活复核（R14），按已消失处理" 'warn'
    } else {
      if ($TryCtrlC) { [void](Invoke-TryCtrlC $script:TargetPid); Start-Sleep -Seconds 2 }
      $stopMain = $(if ($script:HostKind -eq 'desktop' -and $script:MainPid) { [int]$script:MainPid } else { 0 })
      if (-not (Stop-DshInstance $script:TargetPid $GraceSec $stopMain)) { Write-Terminal 'stop-failed' 6; exit 6 }
    }
    if (-not (Wait-PortFree $Port $PortFreeSec)) {
      $owner = @(Get-PortOwner $Port)
      Add-Step 'port-free' "端口 $Port 在 ${PortFreeSec}s 内未释放，占用者 pid=$($owner -join ',')" 'fail'
      Write-Terminal 'port-busy' 7
      exit 7
    }
    Add-Step 'port-free' "端口 $Port 已释放" 'ok'
    Add-Step 'stopped' "已停机：旧 pid=$($script:TargetPid)；-Stop 只停机、不拉起（需要时请自行 dsh-restart）" 'ok'
    Write-Diag ''
    Write-Diag ("  DSH 已停机：端口 {0} 已释放（本命令不负责拉起）" -f $Port) -ForegroundColor Yellow
    Write-Diag ''
    Write-Terminal 'stopped' 0
    exit 0
  }

  # ---- 2. 组合校验（R2 的便宜前置闸门）
  #      Windows 注意：任何 dsh profile 命令都会「真 boot 并写 cordis.yml」。
  #      因此这一步等价于一次浅启动，不能当作安全判据，只作为快速失败信号。
  if ($script:HostKind -eq 'desktop') {
    Add-Step 'dump-config' 'desktop：CLI 拒绝 --profile desktop，跳过组合校验（深度验证会真起一个桌面宿主）' 'skip'
  } elseif (-not $Start) {
    $dumpOk = $null
    try {
      $node = (Get-Command node -ErrorAction Stop).Source
      $dshBin = Get-DshEntry
      if (-not $dshBin) { Add-Step 'dump-config' '找不到 dsh 本体，跳过（深度验证仍会真启一次）' 'warn' }
      else {
        $o = & $node $dshBin --profile $Profile --dump-config 2>&1
        $rcDump = $LASTEXITCODE
        # 注意：dsh 组装 profile 时会写 <profile>\cordis.yml。所以这一步可能因
        # 「写不了」而失败（EPERM/拒绝访问），那不是配置错误 —— 必须区分，
        # 否则会把权限问题误报成「配置无效」，误导成去改 YAML。
        $joined = ($o | Out-String)
        $permish = ($joined -match 'EPERM|EACCES|拒绝访问|Access is denied|cannot resolve profile bundle')
        if ($rcDump -eq 0) {
          $dumpOk = $true
          Add-Step 'dump-config' "exit=0（组合树可打印）" 'ok'
        } elseif ($permish) {
          Add-Step 'dump-config' "无法完成组合校验（非配置错误）：$((($o | Select-Object -Last 3) -join ' | '))" 'warn'
          $dumpOk = $null     # 判据不明 → 不拦截，交给深度验证给出真实结论（fail-closed 在下一步）
        } else {
          $dumpOk = $false
          Add-Step 'dump-config' ("exit=$rcDump 输出尾部: " + (($o | Select-Object -Last 5) -join ' | ')) 'fail'
        }
      }
    } catch {
      Add-Step 'dump-config' "无法执行（$($_.Exception.Message.Split([char]10)[0])）" 'warn'
    }
    if ($dumpOk -eq $false) { Write-Terminal 'config-invalid' 3; exit 3 }
  } else { Add-Step 'dump-config' '仅启动模式，跳过' 'skip' }

  # ---- 2b. 主进程冒烟（R1 的上一层）：真起一次 Electron 主进程，确认它能过启动期校验。
  #      deep-verify 覆盖的是 dsh-desktop-host；主进程自己的校验（DSH_DESKTOP_* 环境变量、
  #      设置文件、policy）不在其中。2026-11-27 实测：隔离宿主 401 通过，真主进程却因
  #      DSH_DESKTOP_UPDATE_CHECK_INTERVAL_MS 越界立刻弹「应用无法启动」。这一步必须在停机之前。
  if ($script:HostKind -eq 'desktop' -and -not $Start -and -not $DryRun -and -not $Fast) {
    if ($SkipGuiProbe) {
      Add-Step 'gui-smoke' '-SkipGuiProbe：跳过主进程冒烟（主进程启动期校验未覆盖，失败时只能靠就绪阶段兜底）' 'warn'
    } else {
      $gui = Test-DesktopGuiStartup -WatchdogProbe
      if (-not $gui.ok) {
        Add-Step 'abort' '主进程无法完成启动期校验 → 在停机之前中止，旧实例保持不动（R1）' 'fail'
        Write-Terminal 'verify-failed' 4
        exit 4
      }
    }
  }

  # ---- 3. 深度验证（R1/R2/R16）：真启一次，能服务才算过
  #       R1 硬约束：没有「证明新组合能起来」，就绝不动在跑的实例。
  #       因此 -Fast（跳过深度验证）在存在运行实例时默认**拒绝继续**，而不是放行。
  if (-not $Start -and -not $Fast -and -not $DryRun) {
    [void](Test-SymlinkPrivilege)   # 先预检宿主启动的硬前提，失败原因更直白

    # 权限预检：宿主若运行在更高完整性级别、而当前进程没有提升，stop 必然 Access is denied。
    # 这一步排在进行深度验证（约 60s、要起一个临时实例）之前 —— 注定失败就别白跑。
    $permPid = $(if ($script:HostKind -eq 'desktop' -and $script:MainPid) { [int]$script:MainPid } else { $script:TargetPid })
    if ($permPid) {
      $perm = Test-StopPermission $permPid
      if (-not $perm.ok) {
        $taskOk = Get-TaskRegistered
        Add-Step 'elev-gate' ("宿主 pid=$permPid 运行在更高完整性级别，而当前进程 Elevated=False" +
          " → 停机必然 Access is denied。已跳过深度验证。") 'fail'
        Add-Step 'elev-gate' ("两条出路：① 在**管理员**窗口里重跑 dsh-restart；" +
          "② 用 dsh-restart -ViaTask 让计划任务以完整令牌执行（任务当前" +
          $(if ($taskOk) { '已注册 ✓' } else { '未注册 ✗' }) + "）。") 'fail'
        Write-Terminal 'stop-failed' 6
        exit 6
      }
      Add-Step 'elev-gate' ("可尝试终止宿主 pid=$permPid（" + $perm.reason + "）") 'ok'
    }

    $script:VerifyTail = @()
    $dv = Invoke-DeepVerifyWithRetry
    if ($dv -and -not $dv.ok) {
      if ($script:VerifyTail) { $script:VerifyTail | ForEach-Object { Write-Diag "      | $_" } }
      Write-Terminal 'verify-failed' 4
      exit 4
    }
    if (-not $dv) { Add-Step 'deep-verify' '验证被跳过（找不到 dsh 本体）' 'warn' }
  } elseif ($Fast) {
    Add-Step 'deep-verify' '-Fast：按参数跳过深度验证' 'warn'
    if ($script:TargetPid -and -not $ForceUnverified) {
      Add-Step 'verify-gate' "存在运行实例 pid=$($script:TargetPid) 且未做深度验证 → 拒绝停机（R1）。" 'fail'
      Add-Step 'verify-gate' '若你确认新组合一定能起来，需显式加 -ForceUnverified；否则请去掉 -Fast 让脚本先真启一次验证。' 'fail'
      Write-Terminal 'verify-required' 10
      exit 10
    }
    if ($script:TargetPid) { Add-Step 'verify-gate' '-ForceUnverified：已显式承担"未验证即停机"的风险' 'warn' }
  } elseif ($DryRun) { Add-Step 'deep-verify' '-DryRun：跳过（不做副作用）' 'skip' }

  # ---- 3b. 存储预检（fail-closed）：workspace.json 一旦写坏，宿主下次启动整域 FAILED，
  #      侧栏工作区变空、十个依赖插件 PENDING。必须在停机之前拦住，别去动正在跑的实例。
  #      -DryRun 只报告不中止（演练本来就不写盘）。
  if (-not (Test-StorageGate -Rehearsal:$DryRun)) { Write-Terminal 'storage-invalid' 3; exit 3 }

  if ($DryRun) {
    $launch = Resolve-Launch
    [void](Test-LaunchPrereq $launch.raw $launch.cwd)
    # 只读演练：算一遍「拉起时会写进新实例的环境块」，不改当前进程环境（-DryRun 不做副作用）
    $envPlan = Get-RegistryEnvironmentBlock
    $envNote = '拉起时将重建环境块：' + $envPlan.TotalCount + ' 项（继承底 ' + $envPlan.InheritedCount +
               '，覆盖 machine ' + $envPlan.MachineCount + ' / user ' + $envPlan.UserCount +
               '，跳过 ' + $envPlan.SkippedCount + '）；PATH ' + $envPlan.PathItems + ' 项（Machine 在前、去重）'
    if ($envPlan.MachineFailed -or $envPlan.UserFailed) { $envNote = $envNote + '；注意：某层注册表读取失败，该层退化为继承值' }
    Add-Step 'env' $envNote 'ok'
    if ($script:HostKind -eq 'desktop') {
      Add-Step 'dry-run' "将执行的停机: taskkill /PID $($script:MainPid) /T /F（DSH Desktop 主进程整棵树）" 'ok'
      Add-Step 'dry-run' "将执行的拉起: $($launch.file)（DSH Desktop 主进程），随后用 netstat 反查新的随机端口" 'ok'
    } else {
      Add-Step 'dry-run' "将执行的停机: taskkill /PID $($script:TargetPid) /T /F（先温和 /T 再强杀）" 'ok'
      Add-Step 'dry-run' "将执行的拉起: $($launch.file) $($launch.args -join ' ')  cwd=$($launch.cwd)  [来源: $($launch.source)]" 'ok'
    }
    Add-Step 'dry-run' "将写续跑通知: $(Join-Path $DshHome '.smart-restart\pending-notice.json') session=$(Normalize-SessionId $Session)" 'ok'
    Write-Terminal 'dry-run' 0
    exit 0
  }

  # ---- 4. 门禁：进行中的配置操作（R10）
  #     注意顺序：拉起前置检查必须在**停机之前** —— 否则「命令注定拉不起来」也会先把旧实例停掉。
  $launchPlan = Resolve-Launch
  if (-not (Test-LaunchPrereq $launchPlan.raw $launchPlan.cwd)) {
    Add-Step 'abort' '拉起前置检查未通过 → 在停机之前中止，旧实例保持不动（R1）' 'fail'
    Write-Terminal 'launch-prereq-failed' 11
    exit 11
  }
  $gate = Test-ConfigOperationGate
  if ($gate -and @($gate).Count -gt 0) {
    $gateAdvice = Get-StaleEnvLockAdvice
    if ($gateAdvice) {
      Add-Step 'gate' "检测到配置操作残留（$(@($gate).Count) 项）：$((@($gate) | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ',') → 拒绝重启（fail-closed）" 'fail'
      Add-Step 'gate' $gateAdvice 'fail'
    } else {
      Add-Step 'gate' "检测到进行中的配置操作痕迹（$(@($gate).Count) 项）：$((@($gate) | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ',') → 拒绝重启" 'fail'
    }
    Write-Terminal 'gate-blocked' 5
    exit 5
  }
  Add-Step 'gate' '无进行中的配置操作痕迹' 'ok'

  # ---- 5. 等空闲（R11）
  if ($WaitIdleSec -gt 0) { [void](Wait-SessionIdle ([Math]::Min($WaitIdleSec, $IdleMaxSec))) }

  # ---- 6. 停机前写续跑通知（R12：Windows 必须先写，不能指望停机钩子）
  if (-not $Start) {
    $sid = Normalize-SessionId $Session
    [void](Write-PendingNotice $sid $Reason)
  }

  # ---- 6b. 重启前给 profile 配置留一份（Live Config 会重写 cordis.patch.yml）
  if (-not $Start) { Backup-ProfileConfig }

  # ---- 7. 停机
  if ($script:TargetPid) {
    if (-not (Test-HostAlive $script:TargetPid $Port)) {
      Add-Step 'stop' "目标 pid=$($script:TargetPid) 未通过判活复核（R14），按已消失处理" 'warn'
    } else {
      if ($TryCtrlC) { [void](Invoke-TryCtrlC $script:TargetPid); Start-Sleep -Seconds 2 }
      $stopMain = $(if ($script:HostKind -eq 'desktop' -and $script:MainPid) { [int]$script:MainPid } else { 0 })
      $stopped = Stop-DshInstance $script:TargetPid $GraceSec $stopMain
      if (-not $stopped) { Write-Terminal 'stop-failed' 6; exit 6 }
    }
  } else { Add-Step 'stop' '无目标实例，跳过停机（冷启动）' 'skip' }
  # 【P3 抢救的触发依据】记下「确实停过旧实例」：此后任何**意外异常**（catch）都必须先尝试
  # 把宿主拉回来，绝不能就这么退出、把机器留在「DSH 已停」状态（用户能直接感知到的最坏结果）。
  if ($script:TargetPid) { $script:StoppedPid = $script:TargetPid }

  # ---- 7b. 回收旧实例遗留的孤儿 DSH 子进程（R22）
  [void](Remove-OrphanDshChildren)

  # ---- 8. 等端口释放（R5）：等不到就报占用者并放弃启动
  if (-not (Wait-PortFree $Port $PortFreeSec)) {
    $owner = Get-PortOwner $Port
    Add-Step 'port-free' "端口 $Port 在 ${PortFreeSec}s 内未释放，占用者 pid=$($owner -join ',')；**放弃启动**（不制造半残实例）" 'fail'
    Write-Terminal 'port-busy' 7
    exit 7
  }
  Add-Step 'port-free' "端口 $Port 已释放" 'ok'

  # ---- 9. 拉起（前置检查已在第 4 步做过，此处直接拉起）
  $proc = Start-DshInstance

  # ---- 10. 就绪校验（R3/R7/R14）
  $ready = Wait-HostReady $proc.Id $Port $ReadySec $(try { $proc.StartTime } catch { $null })
  if (-not $ready.ok) {
    # 回收：优先杀**真实服务器 pid**（NewPid），并连同启动器一起带走，避免留孤儿
    $killPids = @()
    if ($script:NewPid) { $killPids += $script:NewPid }
    if ($proc -and $proc.Id -ne $script:NewPid) { $killPids += $proc.Id }
    Add-Step 'abort-cleanup' "新实例未就绪，回收自己起的实例（R20）：$($killPids -join ',')" 'warn'
    foreach ($kp in $killPids) { & (Get-SystemTool 'taskkill') /PID $kp /T /F *> $null }
    # 再按端口兜底：若 $Port 仍被本次启动链里的进程占着，一并清掉
    Start-Sleep -Milliseconds 800
    foreach ($o in @(Get-PortOwner $Port)) {
      $pp = (Get-CimInstance Win32_Process -Filter "ProcessId=$o" -ErrorAction SilentlyContinue).ParentProcessId
      if ($killPids -contains $o -or $killPids -contains $pp) {
        Add-Step 'abort-cleanup' "端口 $Port 仍被 pid=$o（本次启动链）占用，强制回收" 'warn'
        & (Get-SystemTool 'taskkill') /PID $o /T /F *> $null
      }
    }
    Write-Terminal ('ready-failed:' + $ready.reason) 8
    exit 8
  }

  # ---- 11. 扫尾（R8/R9）
  if ($script:HostKind -eq 'desktop') {
    Add-Step 'sweep' 'DSH Desktop：进程树由 Electron 管理，跳过 node 残留扫描' 'skip'
  } else {
    $resid = @(Get-ResidualChildren $proc.Id)
    if ($resid.Count) { Add-Step 'sweep' "仍有 $($resid.Count) 个 node 进程存活（可能是本实例的 MCP/隧道子进程，属正常）：$($resid.pid -join ',')" 'warn' }
    else { Add-Step 'sweep' '无其他 node 残留' 'ok' }
  }

  # ---- 12. 两层生效提示（R15）
  Add-Step 'client-plugin' '客户端插件由宿主启动时生成分发（rev= 带 immutable 缓存）→ 浏览器需硬刷新 Ctrl+Shift+R 才生效' 'ok'

  # ---- 13. 公布访问地址：宿主 stdout 被重定向，只有本脚本能把它转达给用户
  # R23：token 行只在 loader 全部 settle + 启动审计通过后才打印；实测可能落到
  # 启动后 60~200s（2026-11-10 实测 117s）。R24：只等 20s，拿不到不阻塞退出、退出码不变。
  # R25：判据改用 boot token —— dsh web 每次启动都打印新 token，**token 变化**才证明新进程
  #      真的接管了（比只核对端口 owner 多一层证明）；拿到就落盘，供 -Status/后续步骤读取。
  # -NoWait（分离模式）：收尾不停留 —— 只做一次非阻塞扫描，不再占着前台等这 20s。
  # 拿不到仍然只 WARN（退出码不变）；地址稍后由 `dsh-restart -Status` 校验并补写。
  # 等待预算：桌面宿主把地址写进自己的 `web-auth-url.txt`，stdout 上未必有那行 ——
  # 所以「等日志」只给一个短窗口（5s），剩下的时间交给按 pid 认记录的兜底，
  # 否则每次重启都要为一行可能永远不出现的内容额外付 20s。
  $tokenWaitMs = if ($NoWait) { 0 } elseif ($script:HostKind -eq 'desktop') { 5000 } else { 20000 }
  $script:HostUrl = Wait-NewHostToken $script:HostOutPath $tokenWaitMs
  # 兜底：桌面宿主把地址/令牌写进 `web-auth-url.txt`（那是它自己的落盘事实），
  # 而 stdout 那行在桌面布局里不保证出现。token 等待空手而归时读文件 —— 但只认
  # pid 等于本次新宿主的记录：旧实例的文件绝不能当成本次地址。
  if (-not $script:HostUrl -and $script:NewPid) {
    $script:HostUrl = Read-WebAuthUrlForPid ([int]$script:NewPid)
    if ($script:HostUrl) {
      Add-Step 'url' "stdout 未见新 boot token，但 $($script:NewPid) 的 boot 记录里有地址 → 采用（已核对 pid）" 'ok'
    }
  }
  if ($script:HostUrl) {
    [void](Save-WebAuthUrlRecord $script:HostUrl ([int]$script:NewPid) 'url 步（token 变化判据）')
    Add-Step 'url' "访问地址 $($script:HostUrl)（token 已变化 → 新实例接管；已落盘 $(Get-WebAuthUrlPath)）" 'ok'
    Write-Diag ''
    Write-Diag ("  DSH 访问地址: {0}" -f $script:HostUrl) -ForegroundColor Green
    Write-Diag ''
  } else {
    Add-Step 'url' "20s 内未等到新的 boot token（宿主实测 60~200s 才打印该行，属正常）；地址稍后由 `dsh-restart -Status` 校验并补写到 $(Get-WebAuthUrlPath)，也可直接看 $($script:HostOutPath)" 'warn'
  }
  Write-Terminal 'restarted-ok' 0
  exit 0
}
catch {
  $script:ErrorText = [string]$_.Exception.Message
  Add-Step 'fatal' $_.Exception.Message 'fail'
  if ($env:DSH_RESTART_DEBUG) {
    Write-Diag "---- DEBUG ----" -ForegroundColor Red
    Write-Diag ("Type      : " + $_.Exception.GetType().FullName)
    Write-Diag ("Message   : " + $_.Exception.Message)
    Write-Diag ("At        : " + $_.InvocationInfo.PositionMessage)
    Write-Diag ("ScriptStk : " + ($_.ScriptStackTrace -replace "`n", "  <==  "))
    Write-Diag "---- /DEBUG ----"
  }
  $fatal = $_.Exception.Message.Split([char]10)[0]
  # 【P3 抢救】中止若落在「旧实例已停」之后，机器正停在停机态 —— 这是最坏结果。
  # 尽力拉回来一次（拉不回来就如实报错，绝不假装成功）；只对真正的重启路径生效。
  if ($script:StoppedPid -and -not $Stop -and -not $DryRun -and -not $Status -and -not $VerifyOnly -and -not $Preflight) {
    if (Invoke-RescueLaunch $fatal) {
      if ($script:HostUrl) {
        Write-Diag ''
        Write-Diag ("  DSH 访问地址: {0}" -f $script:HostUrl) -ForegroundColor Green
        Write-Diag ''
      }
      try { Write-Terminal ("rescued-after-abort:" + $fatal) 0 } catch { }
      exit 0
    }
  }
  try { Write-Terminal ("aborted:" + $fatal) 1 } catch { }
  exit 1
}
finally {
  # 兜底：任何没走到 Write-Terminal 的路径（异常、提前 return）也要留下终态结果文件，
  # 否则 -ResultFile 的消费方只能等到超时。已写过则幂等跳过（第一个结论即结论）。
  if (-not $script:ResultWritten) {
    try { Write-EngineResult }
    catch { [Console]::Error.WriteLine('[dsh-restart] ERROR: 终态兜底落盘失败：' + $_.Exception.Message) }
  }
  Exit-RestartLock
}
