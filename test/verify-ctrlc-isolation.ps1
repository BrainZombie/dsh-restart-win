# 验证 Invoke-TryCtrlC 改成子进程之后，主引擎不再被 FreeConsole 破坏控制台。
# 必须在**无控制台**环境跑（本脚本由 verify-ctrlc-isolation-run.ps1 用 WMI 拉起）。
param([string]$OutLog = '', [string]$Root = '')

$ErrorActionPreference = 'Continue'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$sender = Join-Path $Root 'scripts\dsh-ctrlc-sender.ps1'

function Write-Probe([string]$text) {
  Write-Output $text
  if ($OutLog) { Add-Content -LiteralPath $OutLog -Value $text -Encoding utf8 }
}

Write-Probe ("sender exists: " + (Test-Path -LiteralPath $sender))

# 基线：外部进程可用
$base = & netstat.exe -ano -p TCP 2>&1 | Select-Object -First 1
Write-Probe ("baseline netstat ok: " + ($null -ne $base))

# 复刻 Invoke-TryCtrlC：只起子进程，主进程不碰自己的控制台。pid=0 保证 AttachConsole 失败。
$self = (Get-Process -Id $PID).Path
$proc = Start-Process -FilePath $self -ArgumentList @(
  '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
  '-File', $sender, '-TargetPid', '0'
) -WindowStyle Hidden -PassThru
$null = $proc.WaitForExit(15000)
Write-Probe ("sender exited: " + $proc.HasExited + " rc=" + $(if ($proc.HasExited) { $proc.ExitCode } else { 'n/a' }))

# 关键断言：主进程此刻仍能调外部 exe（旧实现这里会以 0x6 崩掉）
$after = & netstat.exe -ano -p TCP 2>&1 | Select-Object -First 3
Write-Probe ("after-sender netstat ok: " + (@($after).Count -gt 0))
if (@($after).Count -gt 0) { Write-Probe ("sample: " + ([string]@($after)[0]).Trim()) }

$tk = & "$env:SystemRoot\System32\taskkill.exe" /? 2>&1 | Select-Object -First 1
Write-Probe ("after-sender taskkill ok: " + ($null -ne $tk))

Write-Probe 'verify-finished'
