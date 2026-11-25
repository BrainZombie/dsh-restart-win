#Requires -Version 7.0
<#
.SYNOPSIS
  dsh-restart-win 的机器配置：一次探测、写进状态目录，之后引擎自己读。

.DESCRIPTION
  为什么需要它：引擎过去只能靠「运行中宿主 / 启动档案 / 常见安装位置」猜安装位置，一旦 App 装在
  非默认目录、又正好停着，就会 fail-closed 报「找不到 DSH Desktop 可执行文件」（实测过一次：
  <盘>\<目录> 安装，停止后 -Start 拉不起来，只能手动起）。

  本脚本把「这台机器的事实」一次性探测并落盘到 %LOCALAPPDATA%\dsh-restart\machine.json：
    appRoot / desktopApp / runtimeDir / pnpm / nodeExe / profile / hostKind
  取值顺序都是「先问系统、再问引擎、最后才用默认位置」，不写死任何安装路径。

  之后引擎的 Resolve-DesktopAppPath 会先读这份配置；配置过期（文件不在了 / 版本变了）会自动
  重新探测，不阻塞启动。

.EXAMPLE
  .\dsh-config.ps1 -Show          # 只看当前配置与探测结果（不写盘）
.EXAMPLE
  .\dsh-config.ps1                # 探测并写入 machine.json
.EXAMPLE
  .\dsh-config.ps1 -DesktopApp '<path>\DeepSeek Harness.exe'   # 手工指定后写盘
#>
[CmdletBinding()]
param(
  [switch]$Show,
  [switch]$Reset,
  [string]$DesktopApp = '',
  [string]$Profile = '',
  [string]$DshHome = '',
  [string]$StateDir = '',
  [string]$Report = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

try {
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch { }

$stateDir = if ($StateDir) { $StateDir } elseif ($env:DSH_RESTART_HOME) { $env:DSH_RESTART_HOME } else { Join-Path $env:LOCALAPPDATA 'dsh-restart' }
if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
$configPath = Join-Path $stateDir 'machine.json'

function Resolve-Engine {
  $envEngine = [string]$env:DSH_RESTART_ENGINE
  if ($envEngine -and (Test-Path -LiteralPath $envEngine)) { return $envEngine }
  $near = Join-Path $PSScriptRoot 'dsh-restart.ps1'
  if (Test-Path -LiteralPath $near) { return $near }
  throw '找不到引擎脚本 dsh-restart.ps1：用 DSH_RESTART_ENGINE 指定'
}

function Get-EngineStatus {
  param([string]$Engine)
  $pwshExe = (Get-Process -Id $PID).Path
  $tmp = Join-Path $env:TEMP ('dsh-config-status-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    $args_ = @('-NoProfile', '-NonInteractive', '-File', ('"' + $Engine + '"'), '-Json', '-Status',
      '-ResultFile', ('"' + $tmp + '"')) -join ' '
    if ($Profile) { $args_ += (' -Profile "' + $Profile + '"') }
    if ($DshHome) { $args_ += (' -DshHome "' + $DshHome + '"') }
    $proc = Start-Process -FilePath $pwshExe -ArgumentList $args_ -PassThru -WindowStyle Hidden -Wait
    if (-not (Test-Path -LiteralPath $tmp)) { return $null }
    $raw = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
    if (-not $raw) { return $null }
    $j = $raw | ConvertFrom-Json
    if ($j.PSObject.Properties['status'] -and $j.status) { return $j.status }
    return $j
  }
  catch { return $null }
  finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
}

function Get-Field {
  param($Object, [string]$Name, $Default = $null)
  if ($null -eq $Object) { return $Default }
  $prop = $Object.PSObject.Properties[$Name]
  if ($prop -and $null -ne $prop.Value) { return $prop.Value }
  return $Default
}

$engine = Resolve-Engine
$status = Get-EngineStatus -Engine $engine

$appRoot = [string](Get-Field $status 'appRoot' '')
if (-not $appRoot) {
  $inst = @(Get-Field $status 'instances' @())
  if ($inst.Count -gt 0) { $appRoot = [string](Get-Field $inst[0] 'appRoot' '') }
}
if (-not $appRoot) {
  $appExe = [string](Get-Field $status 'desktopApp' '')
  if ($DesktopApp) { $appExe = $DesktopApp }
  if ($appExe) { $appRoot = Split-Path -Path $appExe -Parent }
}

$resolvedApp = [string](Get-Field $status 'desktopApp' '')
if ($DesktopApp) { $resolvedApp = $DesktopApp }
if (-not $resolvedApp -and $appRoot) {
  $cand = Join-Path $appRoot 'DeepSeek Harness.exe'
  if (Test-Path -LiteralPath $cand) { $resolvedApp = $cand }
}

$resolvedProfile = if ($Profile) { $Profile } else { [string](Get-Field $status 'profile' 'desktop') }
$resolvedHome = if ($DshHome) { $DshHome } elseif (Get-Field $status 'dshHome' '') { [string](Get-Field $status 'dshHome' '') } else { Join-Path $env:USERPROFILE '.dsh' }
# 运行时目录：与引擎同一个判据 —— 先看运行中实例实测的 runtimeDir（它知道自己是 asar 还是解包），
# 再按两种布局依次试。
$runtimeDir = [string](Get-Field $status 'runtimeDir' '')
if (-not $runtimeDir -and $appRoot) {
  $asar = Join-Path $appRoot 'resources\app.asar'
  $unpacked = Join-Path $appRoot 'resources\app\dsh'
  if (Test-Path -LiteralPath $asar -PathType Leaf) { $runtimeDir = Join-Path $asar 'dsh' }
  elseif (Test-Path -LiteralPath $unpacked -PathType Container) { $runtimeDir = $unpacked }
}
if (-not $runtimeDir) { $runtimeDir = '' }
$pnpm = [string](Get-Field $status 'pnpm' '')
if (-not $pnpm -and $appRoot) {
  $cand = Join-Path $appRoot 'resources\runtime\primary-runtime\dependencies\pnpm\bin\pnpm.mjs'
  if (Test-Path -LiteralPath $cand) { $pnpm = $cand }
}
$nodeExe = [string](Get-Field $status 'nodeExe' '')
if (-not $nodeExe) {
  $cand = ''
  if ($appRoot) { $cand = Join-Path $appRoot 'resources\runtime\bin\node.exe' }
  if ($cand -and (Test-Path -LiteralPath $cand)) { $nodeExe = $cand }
  else { $nodeExe = [string](Get-Command node -ErrorAction SilentlyContinue).Source }
}

$config = [ordered]@{
  version     = 1
  writtenAt   = (Get-Date).ToString('o')
  hostKind    = [string](Get-Field $status 'hostKind' '')
  profile     = $resolvedProfile
  dshHome     = $resolvedHome
  appRoot     = $appRoot
  desktopApp  = $resolvedApp
  desktopAppSource = [string](Get-Field $status 'desktopAppSource' '')
  runtimeDir  = $runtimeDir
  pnpm        = $pnpm
  nodeExe     = $nodeExe
}

if ($Show) {
  Write-Host ("配置将写入：{0}" -f $configPath)
  $config | ConvertTo-Json -Depth 4 | Write-Host
  if ($Report) { (($config | ConvertTo-Json -Depth 4) + "`n") | Set-Content -LiteralPath $Report -Encoding utf8 }
  return
}

if ($Reset) {
  if (Test-Path -LiteralPath $configPath) { Remove-Item -LiteralPath $configPath -Force }
  Write-Host ("已删除 {0}（下一次 -Status / 重启会重新探测）" -f $configPath)
  return
}

if (-not $config.desktopApp -or -not (Test-Path -LiteralPath $config.desktopApp)) {
  Write-Host ('探测不到 DSH Desktop 可执行文件（appRoot=' + $appRoot + '）。用 -DesktopApp <path> 指定。')
  exit 1
}

[System.IO.File]::WriteAllText($configPath, (($config | ConvertTo-Json -Depth 4) + "`n"), [System.Text.UTF8Encoding]::new($false))
Write-Host ("已写入 {0}" -f $configPath)
Write-Host ("  desktopApp = {0}" -f $config.desktopApp)
Write-Host ("  appRoot    = {0}" -f $config.appRoot)
Write-Host ("  runtimeDir = {0}" -f $config.runtimeDir)
Write-Host ("  pnpm       = {0}" -f $config.pnpm)
Write-Host ("  nodeExe    = {0}" -f $config.nodeExe)
if ($Report) { (($config | ConvertTo-Json -Depth 4) + "`n") | Set-Content -LiteralPath $Report -Encoding utf8 }
