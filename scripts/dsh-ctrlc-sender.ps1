# 给目标进程的控制台发一次 Ctrl+C —— 由 dsh-restart.ps1 的 Invoke-TryCtrlC 以独立子进程调用。
#
# 为什么必须独立成进程（2026-11-25 实测）：FreeConsole + AttachConsole 失败之后，
# 调用进程会失去控制台，紧接着调 netstat.exe 会以
#   「程序'netstat.exe'运行失败：获取控制台模式时发生 Win32 内部错误 句柄无效。0x6」
# 直接终止，日志只写到一半。在 WMI/schtasks 脱离启动（父进程 WmiPrvSE、没有控制台）的
# 环境里 100% 复现，对照组 test/console-probe.ps1 三种模式的差异见该文件头注释。
# 隔离到子进程后，子进程崩掉只回一个非零退出码，主引擎继续走 taskkill 强杀。
#
# 退出码：0 = Ctrl+C 已送出；4 = AttachConsole 失败（目标没有可附加的控制台）；5 = 异常。
param([Parameter(Mandatory = $true)][int]$TargetPid)

$ErrorActionPreference = 'Stop'

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
  $ok = [DshCtrlC]::Send([uint32]$TargetPid)
  if ($ok) { exit 0 }
  exit 4
} catch {
  Write-Error $_
  exit 5
}
