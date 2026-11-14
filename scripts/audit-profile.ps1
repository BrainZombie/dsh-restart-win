<#
  audit-profile.ps1 —— 只读：复刻 DSH 的 bundle 解析，列出哪些 bundle 解析不到。
  零写入：只读 package.json 与 node_modules 目录，不执行 dsh、不改配置、不起进程。

  随插件仓库一起发布（scripts\audit-profile.ps1）。默认值只依赖环境变量
  （DSH_HOME / USERPROFILE / APPDATA），没有写死的本机路径，单文件拷走也能跑。

  解析规则来自 @deepseek-ai/dsh-app-boot/lib/index.js resolveBundleDir():
    锚点顺序 = [dsh 安装目录, <profileDir>\package.json]
    每个锚点都按 packageDirFromAnchor 从该目录向上逐级找 node_modules\<pkg>，直到根。
  实测意义：bundle 列在 dsh.profile.bundles 但 node_modules 里没有 → 任何冷启动
  都会以 "cannot resolve profile bundle" 失败，而运行中的旧实例照样服务。
  这正是「线上正常 ≠ 组合 OK」（R1/R2）。

  相对旧版（bin\audit-profile.ps1）的有意修正，不是漂移：
    旧版两处 Get-Content -Raw 未指定编码。pnpm 写出的 package.json 是无 BOM 的 UTF-8，
    而 Windows PowerShell 5.1 默认按 ANSI（简中机上是 GBK）解码；插件描述里有中文时，
    多字节序列会把收尾引号一起吃进去 → ConvertFrom-Json 抛错 → 该 bundle 被误判成
    「包存在，但 package.json 未声明 dsh.bundle.patch」。实测本机 77 个 bundle 里 18 个中招
    （pwsh 7 = 77/77 通过，5.1 = 59/77 + 18 条假失败）。这里改为显式 -Encoding UTF8。
#>
[CmdletBinding()]
param(
  [string]$Profile = 'web',
  [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' })
)
$ErrorActionPreference = 'Stop'

$profileDir   = Join-Path $DshHome "profiles\$Profile"
$manifestPath = Join-Path $profileDir 'package.json'

if (-not (Test-Path -LiteralPath $manifestPath)) { Write-Error "找不到 profile: $manifestPath"; exit 1 }
# 必须显式 -Encoding UTF8：pnpm/npm 写出的 package.json 是无 BOM 的 UTF-8，
# 而 Windows PowerShell 5.1 的默认读取编码是 ANSI（简中机上是 GBK）。插件描述里有中文时，
# GBK 解码会把多字节序列连同收尾引号一起吃掉 → ConvertFrom-Json 抛错 → 包被误判成
# 「未声明 dsh.bundle.patch」。实测本机 77 个 bundle 里 18 个中招（pwsh 7 全通过、5.1 全误报）。
$pkg     = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$bundles = @($pkg.dsh.profile.bundles)

function Find-PackageDir([string]$AnchorDir, [string]$PackageName) {
  $cur = $AnchorDir
  for ($i = 0; $i -lt 12 -and $cur; $i++) {
    $cand = Join-Path $cur (Join-Path 'node_modules' $PackageName)
    if (Test-Path -LiteralPath $cand) { return $cand }
    $parent = Split-Path $cur -Parent
    if (-not $parent -or $parent -eq $cur) { break }
    $cur = $parent
  }
  return $null
}

function Resolve-BundleDir([string]$PackageName, [string]$InstallAnchor, [string]$ProfDir) {
  foreach ($anchor in @($InstallAnchor, $ProfDir)) {
    if (-not $anchor) { continue }
    $dir = Find-PackageDir $anchor $PackageName
    if ($dir) { return $dir }
  }
  return $null
}

$installAnchorDir = Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh'
if (-not (Test-Path -LiteralPath $installAnchorDir)) {
  $g = Get-Command dsh -ErrorAction SilentlyContinue
  if ($g) { $installAnchorDir = Split-Path $g.Source -Parent }
}

Write-Host "profile     : $profileDir"
Write-Host "dsh 安装锚点: $installAnchorDir"
Write-Host "bundle 总数 : $($bundles.Count)"
Write-Host ""

$resolvedList = New-Object System.Collections.ArrayList
$brokenList   = New-Object System.Collections.ArrayList

foreach ($b in $bundles) {
  $dir = Resolve-BundleDir $b $installAnchorDir $profileDir
  if ($dir) {
    $declared = $null
    try { $declared = (Get-Content -LiteralPath (Join-Path $dir 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json).dsh.bundle.patch } catch { }
    if (-not $declared) {
      [void]$brokenList.Add([pscustomobject]@{ bundle = $b; why = '包存在，但 package.json 未声明 dsh.bundle.patch'; dir = $dir })
    } else {
      [void]$resolvedList.Add($b)
    }
  } else {
    [void]$brokenList.Add([pscustomobject]@{ bundle = $b; why = '解析不到：两个锚点的 node_modules 里都没有这个包'; dir = '' })
  }
}

Write-Host ("解析成功: {0} / {1}" -f $resolvedList.Count, $bundles.Count) -ForegroundColor Green
if ($brokenList.Count -gt 0) {
  Write-Host ""
  Write-Host ("!! 解析失败 {0} 条 —— 这些会让任何一次冷启动失败（装配期硬冲突）" -f $brokenList.Count) -ForegroundColor Red
  foreach ($x in $brokenList) { Write-Host ("   {0,-34} {1}" -f $x.bundle, $x.why) -ForegroundColor Yellow }
  Write-Host ""
  Write-Host "修复方式（二选一，改的是 $manifestPath）:"
  Write-Host "  A) 真装回来 : dsh plugin --profile $Profile install $($brokenList[0].bundle)"
  Write-Host "  B) 彻底移除 : 从 dsh.profile.bundles 删掉这些条目（若依赖也已删除，这是收尾）"
} else {
  Write-Host "全部 bundle 均可解析 —— 组合可用" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== dependencies 与 bundles 的差集 ==="
$depNames     = @($pkg.dependencies.PSObject.Properties.Name)
$onlyInBundle = @($bundles | Where-Object { $_ -notin $depNames })
$onlyInDeps   = @($depNames | Where-Object { $_ -notin $bundles })
Write-Host ("  只在 bundles : {0}" -f $(if ($onlyInBundle) { $onlyInBundle -join ', ' } else { '(无)' }))
Write-Host ("  只在 deps    : {0}" -f $(if ($onlyInDeps) { $onlyInDeps -join ', ' } else { '(无)' }))

Write-Host ""
Write-Host "=== 用户层 patch（cordis.patch.yml）引用的行 id ==="
$patch = Join-Path $profileDir 'cordis.patch.yml'
if (Test-Path -LiteralPath $patch) {
  Get-Content -LiteralPath $patch |
    Select-String -Pattern '^\s*-\s*id:\s*(\S+)' |
    ForEach-Object { "  " + $_.Matches[0].Groups[1].Value }
}

if ($brokenList.Count -gt 0) { exit 3 } else { exit 0 }
