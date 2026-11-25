# 复现 dsh-restart.ps1 Invoke-TryCtrlC 之后外部进程调用失败的问题。
#
# 背景：2026-11-25 18:30 的那次 restart（-TryCtrlC）在 graceful 之后以
#   「程序'netstat.exe'运行失败：获取控制台模式时发生 Win32 内部错误 句柄无效 0x6」
# 中止。DshCtrlC.Send 先 FreeConsole 再 AttachConsole；AttachConsole 失败时直接
# return，进程此时已无控制台，随后 pwsh 调外部 exe 时 GetConsoleMode 拿到无效句柄。
#
# 本脚本必须在**无控制台**的进程里跑（WMI / 计划任务启动），否则看不出差别。
# 用法：pwsh -NoProfile -File console-probe.ps1 -Mode {baseline|freeonly|alloc}
param(
  [ValidateSet('baseline', 'freeonly', 'alloc')]
  [string]$Mode = 'baseline',
  [string]$OutLog = ''
)

$ErrorActionPreference = 'Continue'

function Write-Probe([string]$text) {
  $line = "[$Mode] $text"
  Write-Output $line
  if ($OutLog) { Add-Content -LiteralPath $OutLog -Value $line -Encoding utf8 }
}

Write-Probe ("console handle check: " + $(try { [Console]::Out.GetHashCode() } catch { 'no-console-object' }))

if (-not ('DshCtrlCProbe' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DshCtrlCProbe {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint dwProcessId);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AllocConsole();
  // 复刻 Invoke-TryCtrlC 的顺序；pid=0 保证 AttachConsole 失败。
  public static bool Send(uint pid, bool allocOnFail) {
    FreeConsole();
    if (!AttachConsole(pid)) {
      if (allocOnFail) AllocConsole();
      return false;
    }
    bool ok = GenerateConsoleCtrlEvent(0, 0);
    FreeConsole();
    return ok;
  }
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);
}
'@ -ErrorAction Stop
}

# 先证明基线状态下外部进程可用
try {
  $base = & netstat.exe -ano -p TCP 2>&1 | Select-Object -First 1
  Write-Probe ("baseline netstat ok: " + ($base -ne $null))
} catch {
  Write-Probe ("baseline netstat FAILED: " + $_.Exception.Message)
}

switch ($Mode) {
  'baseline' { }
  'freeonly' { $null = [DshCtrlCProbe]::Send(0, $false) }
  'alloc'    { $null = [DshCtrlCProbe]::Send(0, $true) }
}

# AttachConsole(0) 失败后，模拟引擎的下一步：调外部进程
try {
  $after = & netstat.exe -ano -p TCP 2>&1 | Select-Object -First 3
  Write-Probe ("after-TryCtrlC netstat ok: " + (@($after).Count -gt 0))
  if (@($after).Count -gt 0) {
    Write-Probe ("after-TryCtrlC sample: " + ([string]@($after)[0]).Trim())
  }
} catch {
  Write-Probe ("after-TryCtrlC netstat FAILED: " + $_.Exception.Message)
}

# 再从 PowerShell 侧调一次（不同的句柄路径）
try {
  $cmdOut = & "$env:SystemRoot\System32\taskkill.exe" /? 2>&1 | Select-Object -First 1
  Write-Probe ("after-TryCtrlC taskkill ok: " + ($cmdOut -ne $null))
} catch {
  Write-Probe ("after-TryCtrlC taskkill FAILED: " + $_.Exception.Message)
}

Write-Probe "probe-finished"
