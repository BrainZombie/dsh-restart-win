# probe-desktop-watchdog.ps1
# 从引擎 AST 抽出 Get-MainCrashRecord，用临时 userData 验证崩溃记录的归属判据：
#   - shell pid 匹配 → 返回 Error 行
#   - 其他 pid → 忽略
#   - 没有 shell pid 行 → 忽略（不能把无法归属的文件算到本次主进程头上）
#   - 早于启动时刻 → 忽略
# 不碰生产 userData、不写状态目录。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$engine = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/dsh-restart.ps1'
if (-not (Test-Path -LiteralPath $engine)) { throw "找不到 $engine" }

$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($engine, [ref]$tokens, [ref]$parseErrors)
Write-Host ("[1] ParseFile scripts/dsh-restart.ps1  errors={0}" -f $parseErrors.Count)
if ($parseErrors.Count -ne 0) { exit 1 }

function Get-FunctionText([string]$Name) {
  $hits = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
  if ($hits.Count -ne 1) { throw "期望恰好 1 个 $Name 定义，实际 $($hits.Count)" }
  return $hits[0].Extent.Text
}

. ([scriptblock]::Create((Get-FunctionText 'Get-MainCrashRecord')))
. ([scriptblock]::Create((Get-FunctionText 'Get-UserDataDirFromCommandLine')))
. ([scriptblock]::Create((Get-FunctionText 'Get-DesktopUserDataDir')))
$script:DesktopUserData = ''
$script:DesktopUserDataByPid = @{}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('watchdog-probe-' + [guid]::NewGuid().ToString('N'))
$logs = Join-Path $work 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$script:failures = 0

function Assert-True([string]$Label, [bool]$Cond, [string]$Detail) {
  if ($Cond) { Write-Host ("      ok   {0}" -f $Label) }
  else { Write-Host ("      FAIL {0} - {1}" -f $Label, $Detail); $script:failures++ }
}

function New-Crash([string]$Name, [string]$Body, [datetime]$When) {
  $file = Join-Path $logs $Name
  [System.IO.File]::WriteAllText($file, $Body, (New-Object System.Text.UTF8Encoding($false)))
  (Get-Item -LiteralPath $file).LastWriteTime = $When
  return $file
}

try {
  $now = Get-Date
  $good = New-Crash 'crash-2026-01-01T00-00-00-000Z-main.log' "shell pid: 4242`n`nError: boom`n" $now
  $r = Get-MainCrashRecord $work $now.AddMinutes(-1) 4242
  Assert-True '匹配 pid 返回 Error' ($null -ne $r -and $r.error -eq 'Error: boom' -and $r.shellPid -eq 4242) ($r | ConvertTo-Json -Compress)

  $r = Get-MainCrashRecord $work $now.AddMinutes(-1) 9999
  Assert-True '其他 pid 忽略' ($null -eq $r) ($r | ConvertTo-Json -Compress)

  $r = Get-MainCrashRecord $work $now.AddMinutes(5) 4242
  Assert-True '早于启动时刻忽略' ($null -eq $r) ($r | ConvertTo-Json -Compress)

  # 先移走可归属的文件，单独验证“无 pid / 过期”这两种情况，避免落回到上一条匹配。
  Remove-Item -LiteralPath $good -Force
  $noPid = New-Crash 'crash-2026-01-01T00-00-01-000Z-main.log' "app: x`n`nError: no-pid`n" $now
  $r = Get-MainCrashRecord $work $now.AddMinutes(-1) 4242
  Assert-True '没有 shell pid 行的最新文件被忽略' ($null -eq $r) ($r | ConvertTo-Json -Compress)

  Remove-Item -LiteralPath $noPid -Force
  $old = New-Crash 'crash-2026-01-01T00-00-02-000Z-main.log' "shell pid: 4242`n`nError: old`n" $now
  (Get-Item -LiteralPath $old).LastWriteTime = $now.AddMinutes(-30)
  $r = Get-MainCrashRecord $work $now.AddMinutes(-1) 4242
  Assert-True '早于 Since 的文件忽略' ($null -eq $r) ($r | ConvertTo-Json -Compress)

  $ud1 = Get-UserDataDirFromCommandLine '... --user-data-dir="C:\tmp\a b" ...'
  Assert-True '命令行引号路径' ($ud1 -eq 'C:\tmp\a b') $ud1
  $ud2 = Get-UserDataDirFromCommandLine '... --user-data-dir=C:\tmp\ud ...'
  Assert-True '命令行裸路径' ($ud2 -eq 'C:\tmp\ud') $ud2
  $ud3 = Get-UserDataDirFromCommandLine 'no switch here'
  Assert-True '没有开关返回空' ($ud3 -eq '') $ud3

  $fakeAppData = Join-Path $work 'appdata'
  $appDir = Join-Path $fakeAppData '@deepseek-ai\dsh-desktop'
  New-Item -ItemType Directory -Force -Path $appDir | Out-Null
  $appRoot = Join-Path $work 'approot'
  $pkgDir = Join-Path $appRoot 'resources\app'
  New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null
  $pkgPath = Join-Path $pkgDir 'package.json'
  Set-Content -LiteralPath $pkgPath -Value '{"name":"@deepseek-ai/dsh-desktop"}' -Encoding UTF8
  function Get-DesktopPaths([string]$p) { return [pscustomobject]@{ appRoot = $appRoot } }
  $oldAppData = $env:APPDATA
  $env:APPDATA = $fakeAppData
  try {
    $script:DesktopUserData = ''
    $ud = Get-DesktopUserDataDir 'C:\fake\DeepSeek Harness.exe'
    Assert-True 'package.json 的 app name 解析到 userData' ($ud -eq $appDir) $ud

    Remove-Item -LiteralPath $pkgPath -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $appDir 'desktop') | Out-Null
    Set-Content -LiteralPath (Join-Path $appDir 'desktop\settings.json') -Value '{}' -Encoding UTF8
    $script:DesktopUserData = ''
    $ud = Get-DesktopUserDataDir 'C:\fake\DeepSeek Harness.exe'
    Assert-True '没有 crash 日志、只有 settings.json 也能发现' ($ud -eq $appDir) $ud
  } finally {
    $env:APPDATA = $oldAppData
    $script:DesktopUserData = ''
  }
} finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures -ne 0) { Write-Host ("RESULT: FAIL（{0} 项）" -f $script:failures); exit 1 }
Write-Host 'RESULT: ALL PASS'
