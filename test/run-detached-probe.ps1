# 在**无控制台**环境（WMI 拉起，父进程 WmiPrvSE）里跑一个诊断脚本。
#
# 为什么需要它：dsh-restart 的 -Detach 路径就是这么起来的，`FreeConsole`/`AttachConsole`
# 在这类进程里的行为和交互式 pwsh 完全不同 —— 直接在当前终端跑会得到错误结论
# （见 console-probe.ps1 的三种模式差异）。
#
# 用法：pwsh -NoProfile -File run-detached-probe.ps1 -Script console-probe.ps1 -ScriptArgs '-Mode','freeonly'
param(
  [Parameter(Mandatory = $true)][string]$Script,
  [string[]]$ScriptArgs = @(),
  [int]$WaitSec = 8
)

$ErrorActionPreference = 'Stop'
$probe = if ([System.IO.Path]::IsPathRooted($Script)) { $Script } else { Join-Path $PSScriptRoot $Script }
if (-not (Test-Path -LiteralPath $probe)) { throw "probe script not found: $probe" }

$pwsh = (Get-Command pwsh).Source
$log = Join-Path $env:TEMP ("detached-probe-" + [System.IO.Path]::GetFileNameWithoutExtension($probe) + ".log")
Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue

$quotedArgs = ($ScriptArgs | ForEach-Object { '"{0}"' -f $_ }) -join ' '
$cmd = '"{0}" -NoProfile -File "{1}" -OutLog "{2}" {3}' -f $pwsh, $probe, $log, $quotedArgs
$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd.Trim() }
Write-Output ("wmi create rc={0} pid={1}" -f $r.ReturnValue, $r.ProcessId)

Start-Sleep -Seconds $WaitSec
if (Test-Path $log) { Get-Content $log -Raw } else { Write-Output '(no log written — the probe died before its first write)' }
