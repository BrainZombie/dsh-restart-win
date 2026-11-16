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
  [int]$ReadySec        = 90,   # 重启后就绪等待上限
  [int]$VerifyReadySec  = 150,  # 深度验证实例就绪等待上限（2026-09-20：75s 偶发假失败，见 Invoke-DeepVerifyWithRetry）
  [int]$GraceSec        = 3,    # 优雅停机宽限（R21：实测 /T 温和路径从未成功，10s 纯浪费）
  [int]$PortFreeSec     = 30,   # 等端口释放上限
  [int]$WaitIdleSec     = 0,    # >0 则重启前等会话空闲，超时行为写日志（R11）
  [int]$IdleMaxSec      = 300,

  # 动作
  [switch]$Status,
  [switch]$DryRun,
  [switch]$Start,
  [switch]$Stop,          # 只停机（不深度验证、不写续跑通知、不拉起）：跨端口迁移/彻底关停用
  [switch]$Json,
  [switch]$Fast,          # 跳过深度验证；存在运行实例时默认仍拒绝停机（需 -ForceUnverified）
  [switch]$ForceUnverified, # 显式承担「未验证即停机」的风险（与 -Fast 配套，R1 的唯一豁免）
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
  [string]$LaunchRecord = ''  # 内部：交接模式下引擎自报 pid（见 lib/delayed-spawn.mjs 的 handoff）
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

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
$script:StartedAt     = Get-Date
$script:ResultWritten = $false
$script:Extra         = [ordered]@{}
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
  if (-not $Json) {
    $mark = switch ($state) { 'ok' { '  ok ' } 'warn' { ' WARN' } 'skip' { ' skip' } default { ' FAIL' } }
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
    durationMs = [int]((Get-Date) - $script:StartedAt).TotalMilliseconds
    stateDir   = [string]$StateDir
    logPath    = [string]$script:LogPath
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
  $o = & schtasks.exe /Create /TN $TaskName /XML $path /F 2>&1
  $ok = ($LASTEXITCODE -eq 0)
  Add-Step 'register-task' ("$o" -replace "`r?`n", ' ').Trim() $(if ($ok) { 'ok' } else { 'fail' })
  return $ok
}

function Invoke-ViaTask {
  # 通过计划任务执行 —— 执行者脱离 DSH 进程树；任务里以 -ViaTaskInner 跑真正的重启
  $o = & schtasks.exe /Run /TN $TaskName 2>&1
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

function Get-HostAuthUrlRecord([string]$LogPath) {
  <#
    取宿主 stdout 日志里**最后一条** `dsh web: http://…/?token=…`，返回 @{ Url; Token } 或 $null。
    用 Select-String 读（按 FileShare.ReadWrite 打开）：宿主正持有该文件的写入句柄时，
    [IO.File]::ReadAllLines 会因共享模式冲突直接抛「being used by another process」（实测）。
  #>
  if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return $null }
  $hit = Select-String -LiteralPath $LogPath -Pattern 'dsh\s+web:\s*(https?://\S+)' -ErrorAction SilentlyContinue |
         Select-Object -Last 1
  if (-not $hit -or $hit.Matches.Count -eq 0) { return $null }
  $url = $hit.Matches[0].Groups[1].Value.TrimEnd('.', ',', ')', '"', "'")
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

function Test-WebAuthUrl([string]$Url) {
  <#
    token 是否被**当前运行实例**接受：带 token 请求根路径。
    本机实测：有效 token → 303（重定向到应用页）；缺失/伪造 token → 401。
    2xx/3xx = 有效；401/403 = 无效；0/404（进程未就绪/路由未注册） = 尚未证明。
    探测本身走 Get-HttpStatusCode（内部已对 5.1 做 HttpWebRequest 兜底）。
  #>
  if (-not $Url) { return $false }
  $code = Get-HttpStatusCode $Url 6
  return ($code -ge 200 -and $code -lt 400)
}

function Resolve-WebAuthUrl($CurrentPids) {
  <#
    -Status 用：返回 @{ Url; State = 'ok'|'stale'|'unknown'; Detail; Refreshed }。
    旧地址绝不能被当成当前有效地址 —— 必须同时满足：
      ① 持久文件里的记录带 pid 且等于当前端口监听者 pid（否则是上一次 boot 的旧记录）；
      ② 带 token 的 HTTP 探测被当前实例接受（旧进程的 token 会被新进程拒绝）。
    文件缺失/过期时做一次「只读修复」：若日志里已经有**当前实例**的 token（同样以 HTTP
    探测证明），就补写持久文件。补写的只是状态目录里的一个缓存文件，不碰 DSH 实例 ——
    这样 20s 窗口错过 token 行（实测 117s）后，用户仍能在 -Status 里拿到地址。
  #>
  $pids = @()
  foreach ($p in @($CurrentPids)) { if ($null -ne $p) { $pids += [int]$p } }
  $file = Get-WebAuthUrlPath
  if ($pids.Count -eq 0) {
    return [pscustomobject]@{ Url = $null; State = 'stale'; Detail = '当前没有运行实例（端口无监听者）'; Refreshed = $false }
  }

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
  } elseif (Test-WebAuthUrl $rec.Url) {
    return [pscustomobject]@{ Url = $rec.Url; State = 'ok'; Detail = ('持久文件 pid=' + $rec.Pid + '，token 已被当前实例接受'); Refreshed = $false }
  } else {
    $why = '持久文件里的 token 未被当前实例接受（pid=' + $rec.Pid + '；宿主可能仍在启动，或该记录已过期）'
  }

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
  # netstat 是权威（本机 Get-NetTCPConnection 在沙箱下不可靠）
  $rows = netstat -ano -p TCP 2>$null | Select-String "LISTENING" | Select-String ":$p\s"
  return [bool]$rows
}

function Get-PortOwner([int]$p) {
  $rows = netstat -ano -p TCP 2>$null | Select-String "LISTENING" | Select-String ":$p\s"
  $pids = @()
  foreach ($r in $rows) {
    # 【严格模式 2.0 陷阱 · 2026-09-12 真实事故】管道只产出一项时结果是**标量**，
    # 标量没有 .Count（非严格模式下 PowerShell 才会给标量补 Count=1）→ 必须 @() 包成数组。
    # 该次中止就发生在本行：restart-history.jsonl 18:15:03 aborted: 在此对象上找不到属性 Count
    if (-not $r -or -not $r.Line) { continue }
    $t = @(($r.Line -split '\s+') | Where-Object { $_ -ne '' })
    if ($t.Count -ge 5) { $pids += [int]$t[-1] }
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
  # 全量实例视图（恒为数组）
  if ($script:HostKind -eq 'desktop') { return @(Get-DesktopInstances) }
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
    & taskkill.exe /PID $ProcId /T /F *> $null
    Start-Sleep -Milliseconds 600
  }
  if ($ProcPort) {
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
      $owners = @(Get-PortOwner $ProcPort)
      if ($owners.Count -eq 0) { break }
      foreach ($o in $owners) {
        Write-Audit 'warn' "验证实例残留：端口 $ProcPort 仍被 pid=$o 占用，强制回收"
        & taskkill.exe /PID $o /T /F *> $null
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
    $tokenSeen = $false
    while ((Get-Date) -lt $deadline) {
      if ($p.HasExited) { break }
      if (-not $tokenSeen) {
        foreach ($f in @($out, $err)) {
          if (Test-Path -LiteralPath $f) {
            $txt = Get-Content -LiteralPath $f -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($txt -match 'token=') { $tokenSeen = $true }
          }
        }
      }
      $probe = Test-HttpServing ("http://127.0.0.1:$vPort/")
      # 只认 401/200（404 = 路由还没注册完，不算就绪）
      if ($probe.ready) { break }
      Start-Sleep -Milliseconds 800
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
  if (-not $Id) { return $null }
  if ($Id -eq 'auto') { return (Get-NewestSessionId) }
  return ($Id -replace '^session-', '')
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
  try {
    if (-not ('DshCtrlC' -as [type])) {
      Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DshCtrlC {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint dwProcessId);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);
  public static bool Send(uint pid) {
    FreeConsole();
    if (!AttachConsole(pid)) return false;
    bool ok = GenerateConsoleCtrlEvent(0, 0);
    FreeConsole();
    return ok;
  }
}
'@ -ErrorAction Stop
    }
    $ok = [DshCtrlC]::Send([uint32]$Pid_)
    Add-Step 'graceful' "AttachConsole+Ctrl+C 结果: $ok" $(if ($ok) { 'ok' } else { 'warn' })
    return $ok
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
  $o1 = & taskkill.exe /PID $Pid_ /T 2>&1
  $rc1 = $LASTEXITCODE
  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process -Id $Pid_ -ErrorAction SilentlyContinue)) {
      Add-Step 'stop' "进程 $Pid_ 已退出（温和路径，taskkill rc=$rc1）" 'ok'; return $true
    }
    Start-Sleep -Milliseconds 500
  }
  Add-Step 'stop' "宽限 ${WaitSeconds}s 内未退出（taskkill rc=$rc1：$(Format-KillOutput $o1)），强杀 /T /F" 'warn'
  $o2 = & taskkill.exe /PID $Pid_ /T /F 2>&1
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
    & taskkill.exe /PID $proc.Id /T /F *> $null
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

function Wait-HostReady([int]$Pid_, [int]$P, [int]$MaxSec) {
  if ($script:HostKind -eq 'desktop') { return (Wait-DesktopHostReady $Pid_ $MaxSec) }
  $url = "http://${BindHost}:$P/"
  $deadline = (Get-Date).AddSeconds($MaxSec)
  $last = [pscustomobject]@{ status = 0; serving = $false; authed = $false }
  $tokenSeen = $false
  while ((Get-Date) -lt $deadline) {
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
    Start-Sleep -Milliseconds 700
  }
  $diag = if ($last.status -eq 404) { '端口已绑但 $MaxSecs 内路由未就绪（404）' } elseif ($last.status -eq 0) { '$MaxSecs 内端口无响应' } else { "最后状态码 $($last.status)" }
  Add-Step 'ready' "等待就绪超时 ${MaxSec}s：$diag" 'fail'
  return [pscustomobject]@{ ok = $false; reason = 'timeout'; last = $last.status }
}

# ---------------------------------------------------------------- 锁（R11/R20：句柄不可被继承）

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

# ---------------------------------------------------------------- Status

function Show-Status {
  Resolve-HostKind
  $instances = @(Get-DshInstances)   # @() 强制成数组：函数返回空数组会被解包成 $null
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
  $rec = Get-BootRecord
  $last = $null
  $hist = Get-StatePath 'restart-history.jsonl'
  if (Test-Path -LiteralPath $hist) {
    $line = Get-Content -LiteralPath $hist -Tail 1 -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($line) { try { $last = $line | ConvertFrom-Json } catch { } }
  }
  $probe = Test-HttpServing "http://${BindHost}:$Port/"
  # 访问地址优先读持久文件（url 步/上次 -Status 落盘），并校验 pid 与 token 是否属于当前实例：
  # 旧 boot 的地址一律不展示，宁可明确说「未知/过期」。
  $currentHostPids = @()
  foreach ($inst in $instances) { $currentHostPids += [int]$inst.pid }
  $auth = Resolve-WebAuthUrl $currentHostPids
  $script:HostUrl = $auth.Url
  $stUrl = $script:HostUrl
  # 注意：`$x = if (...) { @() } else { @() }` 里的**空数组会被解包成 $null**，
  # 于是后面的 $x.Count 抛 PropertyNotFoundException（只在「无实例」这条路上触发，
  # 实测过一次：dsh 没启动时 `-Status` 走到这里崩掉）。所以整个 if 表达式要再套一层 @()。
  $children = @(if ($script:HostKind -eq 'desktop') { @() } elseif ($instances.Count) { Get-ResidualChildren $instances[0].pid } else { @() })

  if ($Json -or $ResultFile) {
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
      marker     = $(try { Get-Content (Join-Path $DshHome '.smart-restart\marker.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null })
    }
    # 信封里这两个字段在只读动作下同样有确切含义：targetPid=当前监听者、hostUrl=已校验地址
    if ($instances.Count -ge 1) { $script:TargetPid = $instances[0].pid }
    if ($auth.State -ne 'ok') { [void]$script:Warn.Add('launchUrl: ' + $auth.Detail) }
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
  Write-Diag ("  最近一次重启: {0}" -f $(if ($last) { "$($last.ts) result=$($last.result) rc=$($last.rc) 旧pid=$($last.target_pid) 新pid=$($last.new_pid)" } else { '(无记录)' }))

  # 托管形态判定（R13）
  # 原来分两段打（前缀 -NoNewline + 判定），现在拼成一行再输出：诊断统一走 Write-Diag，
  # 而它没有 -NoNewline。
  $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'dsh' }
  $task = (schtasks /Query /TN $TaskName /FO LIST 2>$null)
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
      $live = @(Get-DesktopInstances)
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
    $r = Wait-HostReady $p.Id $Port $ReadySec
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
    foreach ($kp in $killPids) { & taskkill.exe /PID $kp /T /F *> $null }
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
  if (-not (Test-Path -LiteralPath $paths.asar -PathType Leaf)) { return [pscustomobject]@{ ok = $false; reason = 'app-asar-missing' } }
  $root = Get-SharedScopePath
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $stats = [pscustomobject]@{ Files = 0; Unpacked = 0; Skipped = 0; Links = 0; Missing = 0; Errors = 0; Bytes = [int64]0 }
  $stream = $null
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
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

function Get-ListeningPorts([int]$Pid_) {
  # 反查某个 pid 的 LISTENING 端口（netstat 是权威；Get-NetTCPConnection 在沙箱下不可靠）
  $out = New-Object System.Collections.ArrayList
  foreach ($r in @(netstat -ano -p TCP 2>$null | Select-String 'LISTENING')) {
    if (-not $r -or -not $r.Line) { continue }
    $t = @((([string]$r.Line) -split '\s+') | Where-Object { $_ -ne '' })
    if ($t.Count -lt 5) { continue }
    if ([int]$t[-1] -ne $Pid_) { continue }
    $local = [string]$t[1]
    $idx = $local.LastIndexOf(':')
    if ($idx -lt 1) { continue }
    $p = 0
    if ([int]::TryParse($local.Substring($idx + 1), [ref]$p)) { [void]$out.Add($p) }
  }
  return @($out | Sort-Object -Unique)
}

function Get-DesktopHostProcesses {
  # 命令行含 dsh-desktop-host\lib\index.js 的进程 = 桌面版宿主子进程。
  # 恒返回数组；CIM 不可用时返回空数组（由调用方按 web 处理 / 明确报错）。
  $out = New-Object System.Collections.ArrayList
  if (-not (Get-CimAvailable)) { return @() }
  foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue)) {
    $cmd = [string]$p.CommandLine
    if (-not $cmd) { continue }
    if ($cmd -notmatch 'dsh-desktop-host[\\/]lib[\\/]index\.js') { continue }
    [void]$out.Add([pscustomobject]@{
      pid         = [int]$p.ProcessId
      mainPid     = [int]$p.ParentProcessId
      commandLine = $cmd
    })
  }
  return @($out.ToArray())
}

function Get-DesktopPaths([string]$MainPath) {
  # 桌面版的固定目录形状（全部从可执行文件位置推导，不猜安装路径）
  $appRoot    = Split-Path -Path $MainPath -Parent
  $runtimeDir = Join-Path $appRoot 'resources\app.asar\dsh'
  return [pscustomobject]@{
    exe            = $MainPath
    appRoot        = $appRoot
    runtimeDir     = $runtimeDir
    entry          = (Join-Path $runtimeDir 'node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js')
    asar           = (Join-Path $appRoot 'resources\app.asar')
    primaryRuntime = (Join-Path $appRoot 'resources\runtime\primary-runtime')
    pnpm           = (Join-Path $appRoot 'resources\runtime\primary-runtime\dependencies\pnpm\bin\pnpm.mjs')
    nodeBin        = (Join-Path $appRoot 'resources\runtime\bin')
  }
}

function Get-DesktopInstances {
  <#
    桌面版实例 = 宿主子进程 + 它的 Electron 主进程 + 实测监听端口。
    身份四要素（缺一不可，防误杀）：
      a) 进程名 DeepSeek Harness.exe 且命令行含 dsh-desktop-host\lib\index.js；
      b) 父进程是同目录下的 DeepSeek Harness.exe，且命令行里没有 --type=（不是渲染/GPU 子进程）；
      c) <appRoot>\resources\app.asar 是真实文件；
      d) 宿主命令行里包含由 (b) 推导出的 runtimeDir。
    端口：netstat 反查宿主 pid 的 LISTENING 端口，逐个 GET /，取 401/200 的那个。
  #>
  $list = New-Object System.Collections.ArrayList
  foreach ($h in @(Get-DesktopHostProcesses)) {
    $main = Get-CimInstance Win32_Process -Filter "ProcessId=$($h.mainPid)" -ErrorAction SilentlyContinue
    if (-not $main) { continue }
    $mainPath = [string]$main.ExecutablePath
    if (-not $mainPath) { continue }
    if ([string]$main.CommandLine -match '--type=') { continue }
    $paths = Get-DesktopPaths $mainPath
    if (-not (Test-Path -LiteralPath $paths.asar -PathType Leaf)) { continue }
    if ($h.commandLine -notlike ('*' + $paths.runtimeDir + '*')) { continue }
    $profileName = ''
    if ($h.commandLine -match '[\\/]profiles[\\/]([A-Za-z0-9][A-Za-z0-9._-]{0,63})') { $profileName = $Matches[1] }
    $ports = @(Get-ListeningPorts $h.pid)
    $chosen = 0
    $httpStatus = 0
    foreach ($p in $ports) {
      $s = Test-HttpServing ("http://${BindHost}:$p/")
      if ($s.ready) { $chosen = $p; $httpStatus = $s.status; break }
    }
    $proc = Get-Process -Id $h.pid -ErrorAction SilentlyContinue
    [void]$list.Add([pscustomobject]@{
      pid            = $h.pid
      name           = 'DeepSeek Harness'
      port           = $chosen
      ports          = @($ports)
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
      http           = $httpStatus
      start          = $(try { $proc.StartTime.ToString('o') } catch { '' })
      ws_mb          = $(if ($proc) { [math]::Round($proc.WorkingSet64 / 1MB, 1) } else { 0 })
      handles        = $(try { $proc.HandleCount } catch { -1 })
      source         = 'desktop-host'
    })
  }
  return @($list.ToArray())
}

function Resolve-HostKind {
  # auto：先看有没有桌面版宿主进程；其次看启动档案是不是记录着 Desktop 的 exe。
  # 两者都没有 → web（保持老行为，连“找不到 dsh web”的失败文案都不变）。
  if ($script:HostKindRequested -ne 'auto') { $script:HostKind = $script:HostKindRequested; return }
  if (@(Get-DesktopHostProcesses).Count -gt 0) { $script:HostKind = 'desktop'; return }
  $rec = Get-BootRecord
  if ($rec -and $rec.command -and ([string]$rec.command -match '(?i)DeepSeek Harness\.exe')) {
    $script:HostKind = 'desktop'; return
  }
  $script:HostKind = 'web'
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
  }
}

function Resolve-DesktopAppPath {
  # 依次：本次已解析 → 运行中的实例 → 启动档案里的 exe → 常见安装位置。
  $cands = New-Object System.Collections.ArrayList
  if ($script:DesktopAppPath) { [void]$cands.Add([string]$script:DesktopAppPath) }
  foreach ($i in @(Get-DesktopInstances)) { if ($i.exe) { [void]$cands.Add([string]$i.exe) } }
  $rec = Get-BootRecord
  if ($rec -and $rec.command) {
    $m = [regex]::Match([string]$rec.command, '"([^"]+\.exe)"|^\s*([^\s]+\.exe)')
    if ($m.Success) {
      if ($m.Groups[1].Success) { [void]$cands.Add($m.Groups[1].Value) }
      elseif ($m.Groups[2].Success) { [void]$cands.Add($m.Groups[2].Value) }
    }
  }
  [void]$cands.Add((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'))
  [void]$cands.Add((Join-Path $env:ProgramFiles 'DeepSeek Harness\DeepSeek Harness.exe'))
  foreach ($c in $cands) {
    if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { $script:DesktopAppPath = $c; return $c }
  }
  return $null
}

function Get-DesktopLaunch {
  $exe = Resolve-DesktopAppPath
  if (-not $exe) { return $null }
  $cwd = Split-Path -Path $exe -Parent
  $rec = Get-BootRecord
  if ($rec -and $rec.cwd -and (Test-Path -LiteralPath $rec.cwd)) { $cwd = [string]$rec.cwd }
  return [pscustomobject]@{ file = $exe; args = @(); cwd = $cwd; source = 'desktop-app'; raw = $exe }
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
  $o = & taskkill.exe /PID $MainPid_ /T /F 2>&1
  $rc = $LASTEXITCODE
  $deadline = (Get-Date).AddSeconds([Math]::Max($WaitSeconds, 15))
  while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process -Id $MainPid_ -ErrorAction SilentlyContinue)) {
      Add-Step 'stop' "DSH Desktop 已退出（taskkill rc=$rc）" 'ok'
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
  $stdinPath = Get-EmptyStdinPath
  $spArgs = @{
    FilePath = $plan.file; WorkingDirectory = $plan.cwd; PassThru = $true
    RedirectStandardOutput = $webOut; RedirectStandardError = $webErr
  }
  if ($stdinPath) { $spArgs['RedirectStandardInput'] = $stdinPath }
  $p = Start-Process @spArgs
  $script:NewPid = $p.Id
  $script:NewMainPid = $p.Id
  Add-Step 'launch' "已拉起 DSH Desktop pid=$($p.Id)（$($plan.file)），stdout→$webOut" 'ok'
  return $p
}

function Wait-DesktopHostReady([int]$MainPid_, [int]$MaxSec) {
  # 就绪判据：出现「新的」宿主子进程（pid ≠ 旧宿主）+ 它监听的端口 401/200。
  # 端口每次随机，所以不能沿用「同一端口换 pid」。
  $oldHostPid = 0
  if ($script:Desktop) { $oldHostPid = [int]$script:Desktop.pid }
  $deadline = (Get-Date).AddSeconds($MaxSec)
  $lastPorts = @()
  while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process -Id $MainPid_ -ErrorAction SilentlyContinue)) {
      $live = @(Get-DesktopInstances)
      if ($live.Count -gt 0) {
        Add-Step 'ready' "新进程已退出，但机器上已有 DSH Desktop 宿主（main pid=$($live[0].mainPid)）→ 单实例锁把启动转成了聚焦旧窗口" 'fail'
        return [pscustomobject]@{ ok = $false; reason = 'desktop-single-instance' }
      }
      Add-Step 'ready' "DSH Desktop 主进程 $MainPid_ 已退出（未就绪）" 'fail'
      Show-LaunchFailure $script:HostOutPath $script:HostErrPath
      return [pscustomobject]@{ ok = $false; reason = 'exited' }
    }
    foreach ($h in @(Get-DesktopHostProcesses)) {
      if ($h.mainPid -ne $MainPid_) { continue }
      if ($oldHostPid -gt 0 -and $h.pid -eq $oldHostPid) { continue }
      $ports = @(Get-ListeningPorts $h.pid)
      if ($ports.Count -gt 0) { $lastPorts = $ports }
      foreach ($p in $ports) {
        $s = Test-HttpServing ("http://${BindHost}:$p/")
        if ($s.ready) {
          $script:NewPid = $h.pid
          $script:NewMainPid = $MainPid_
          $script:Port = $p
          Add-Step 'ready' "新宿主 pid=$($h.pid)（父 pid=$MainPid_）端口 $p HTTP=$($s.status)" 'ok'
          return [pscustomobject]@{ ok = $true; http = $s.status; authed = $s.authed; pid = $h.pid; mainPid = $MainPid_; port = $p }
        }
      }
    }
    Start-Sleep -Milliseconds 700
  }
  $diag = if (@($lastPorts).Count -gt 0) { "端口 $($lastPorts -join ',') 已绑定但未就绪" } else { '未发现宿主子进程的监听端口' }
  Add-Step 'ready' "等待 DSH Desktop 就绪超时 ${MaxSec}s：$diag" 'fail'
  return [pscustomobject]@{ ok = $false; reason = 'timeout' }
}

function Remove-TreeSafe([string]$Dir) {
  # 含 junction 的目录：cmd rmdir 只删链接本身；PS5.1 的 Remove-Item -Recurse 可能跟进目标。
  if (-not (Test-Path -LiteralPath $Dir)) { return }
  & cmd.exe /c "rmdir /s /q `"$Dir`"" *> $null
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
    if (-not (Test-Path -LiteralPath $paths.asar -PathType Leaf)) {
      Add-Step 'deep-verify' "app.asar 不存在：$($paths.asar)" 'fail'
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
    $lastHttp = 0
    while ((Get-Date) -lt $deadline) {
      if ($p.HasExited) { break }
      $ports = @(Get-ListeningPorts $p.Id)
      foreach ($port in $ports) {
        $s = Test-HttpServing ("http://${BindHost}:$port/")
        $lastHttp = $s.status
        if ($s.ready) {
          $vPort = $port
          Add-Step 'deep-verify' ("桌面宿主隔离实例 $port 就绪 HTTP=$($s.status)（Electron Node 模式 + 临时 home）") 'ok'
          return [pscustomobject]@{ ok = $true; port = $port; http = $s.status; logdir = $v }
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
    $why = if ($p.HasExited) { "进程已退出（exit=$($p.ExitCode)）" }
           elseif ($lastHttp -eq 404) { "端口已绑但 $VerifyReadySec s 内路由未就绪（404）" }
           elseif ($lastHttp -eq 0) { "$VerifyReadySec s 内端口未响应" }
           else { "最后状态码 $lastHttp" }
    Add-Step 'deep-verify' ("桌面宿主隔离实例未就绪：$why；日志保留在 $v") 'fail'
    return [pscustomobject]@{ ok = $false; reason = 'not-ready'; logdir = $v; tail = $tail }
  } catch {
    Add-Step 'deep-verify' "桌面验证实例启动异常: $($_.Exception.Message)" 'fail'
    return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
  } finally {
    if ($p) { & taskkill.exe /PID $p.Id /T /F *> $null; Start-Sleep -Milliseconds 800 }
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
  Resolve-HostKind
  Add-Step 'host-kind' $(if ($script:HostKind -eq 'desktop') { 'desktop：DSH Desktop（Electron 主进程 + dsh-desktop-host 子进程，端口实测）' } else { 'web：dsh web 进程（按端口发现）' }) 'ok'
  Resolve-DesktopProfileName

  if ($UnregisterTask) {
    $o = & schtasks.exe /Delete /TN $TaskName /F 2>&1
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

  if ($RepairSharedScope) {
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
  if ($VerifyOnly -or $Preflight) {
    $symOk = Test-SymlinkPrivilege
    $script:VerifyTail = @()
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
  $ready = Wait-HostReady $proc.Id $Port $ReadySec
  if (-not $ready.ok) {
    # 回收：优先杀**真实服务器 pid**（NewPid），并连同启动器一起带走，避免留孤儿
    $killPids = @()
    if ($script:NewPid) { $killPids += $script:NewPid }
    if ($proc -and $proc.Id -ne $script:NewPid) { $killPids += $proc.Id }
    Add-Step 'abort-cleanup' "新实例未就绪，回收自己起的实例（R20）：$($killPids -join ',')" 'warn'
    foreach ($kp in $killPids) { & taskkill.exe /PID $kp /T /F *> $null }
    # 再按端口兜底：若 $Port 仍被本次启动链里的进程占着，一并清掉
    Start-Sleep -Milliseconds 800
    foreach ($o in @(Get-PortOwner $Port)) {
      $pp = (Get-CimInstance Win32_Process -Filter "ProcessId=$o" -ErrorAction SilentlyContinue).ParentProcessId
      if ($killPids -contains $o -or $killPids -contains $pp) {
        Add-Step 'abort-cleanup' "端口 $Port 仍被 pid=$o（本次启动链）占用，强制回收" 'warn'
        & taskkill.exe /PID $o /T /F *> $null
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
  $tokenWaitMs = if ($NoWait) { 0 } else { 20000 }
  $script:HostUrl = Wait-NewHostToken $script:HostOutPath $tokenWaitMs
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
