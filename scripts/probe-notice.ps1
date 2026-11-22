# probe-notice.ps1
# 只读验证 dsh-repair.ps1 的续跑通知写入：
#   1) 用 PowerShell 语言解析器解析整个脚本，要求 0 错误；
#   2) 从 AST 抽出真实的 Write-PendingNoticeSafe / Get-SpecPackageName 函数体，
#      在临时目录里用假参数跑两次（第二次覆盖已存在的 pending-notice.json），
#      检查合法 JSON、键序、when 以 Z 结尾、attempts=0、extra 三字段、无 BOM、无 .tmp 残留；
#   3) 静态确认调用点仍在停机之前。
# 不执行安装、不启动/停止宿主、不写 <DshHome>。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$target = Join-Path $PSScriptRoot 'dsh-repair.ps1'
if (-not (Test-Path -LiteralPath $target)) { throw "找不到 $target" }

# ---------------------------------------------------------------- 1) 解析
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$parseErrors)
Write-Host ("[1] ParseFile: {0}" -f $target)
Write-Host ("    PowerShellVersion={0}  errors={1}  {2}" -f $PSVersionTable.PSVersion, $parseErrors.Count, $(if ($parseErrors.Count -eq 0) { 'PASS' } else { 'FAIL' }))
if ($parseErrors.Count -ne 0) {
  foreach ($e in $parseErrors) { Write-Host ("    {0} @ line {1}: {2}" -f $e.ErrorId, $e.Extent.StartLineNumber, $e.Message) }
  exit 1
}

# ---------------------------------------------------------------- 2) 抽函数体
function Get-FunctionText([string]$Name) {
  $hits = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
  if ($hits.Count -ne 1) { throw "期望恰好 1 个 $Name 定义，实际 $($hits.Count)" }
  return $hits[0].Extent.Text
}
$fnNotice = Get-FunctionText 'Write-PendingNoticeSafe'
$fnSpec   = Get-FunctionText 'Get-SpecPackageName'

Write-Host ("[2] 已从 AST 抽出 Write-PendingNoticeSafe（{0} 字符）与 Get-SpecPackageName（{1} 字符）" -f $fnNotice.Length, $fnSpec.Length)

# 原子写这一层做静态确认：临时文件后缀 + WriteAllText + Move-Item
$staticTmp  = ($fnNotice -match '\.tmp')
$staticMove = ($fnNotice -match 'Move-Item')
$staticUtf8 = ($fnNotice -match 'UTF8Encoding')
Write-Host ("    静态检查：.tmp={0}  Move-Item={1}  UTF8NoBom={2}  {3}" -f $staticTmp, $staticMove, $staticUtf8, $(if ($staticTmp -and $staticMove -and $staticUtf8) { 'PASS' } else { 'FAIL' }))
if (-not ($staticTmp -and $staticMove -and $staticUtf8)) { exit 1 }

# ---------------------------------------------------------------- 3) 临时目录里跑
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('notice-probe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$noticePath = Join-Path $work 'pending-notice.json'
$resultPath = Join-Path $work 'dsh-repair-probe.json'
$logPath    = Join-Path $work 'dsh-repair-probe.log'

function Write-Log { param([string]$Message) Write-Host ("      [log] {0}" -f $Message) }

$harness = ($fnSpec, $fnNotice, 'Write-PendingNoticeSafe') -join "`n`n"
$sb = [scriptblock]::Create($harness)

function Invoke-NoticeWrite {
  param([string]$SessionId, [string]$Reason, $pkgName, [string]$Spec)
  & $sb
}

$expectedKeys = @('sessionId', 'reason', 'when', 'attempts', 'extra')
$script:failures = 0

function Assert-Notice {
  param([string]$Label, [string]$ExpectPackage, [bool]$PackageIsNull, [string]$ExpectReason)

  $dirFiles = @(Get-ChildItem -LiteralPath $work -Force | Select-Object -ExpandProperty Name)
  $tmpLeft  = @($dirFiles | Where-Object { $_ -like '*.tmp' })
  $bytes    = [System.IO.File]::ReadAllBytes($noticePath)
  $hasBom   = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $raw      = [System.IO.File]::ReadAllText($noticePath, [System.Text.Encoding]::UTF8)

  $jsonOk = $true
  $obj = $null
  try { $obj = $raw | ConvertFrom-Json } catch { $jsonOk = $false; Write-Host ("    JSON 非法: {0}" -f $_.Exception.Message) }

  $keys = if ($jsonOk) { @($obj.PSObject.Properties.Name) } else { @() }
  $keyOrderOk = (($keys -join ',') -eq ($expectedKeys -join ','))

  $pos = @{}
  foreach ($k in $expectedKeys) { $pos[$k] = $raw.IndexOf('"' + $k + '"') }
  $rawOrderOk = $true
  for ($i = 0; $i -lt $expectedKeys.Count; $i++) {
    if ($pos[$expectedKeys[$i]] -lt 0) { $rawOrderOk = $false; break }
    if ($i -gt 0 -and $pos[$expectedKeys[$i]] -le $pos[$expectedKeys[$i - 1]]) { $rawOrderOk = $false; break }
  }

  # PS7 的 ConvertFrom-Json 会把 ISO 字符串转成 DateTime，from_raw 检查原始文本
  $whenRaw  = if ($jsonOk) { [regex]::Match($raw, '"when":"([^"]+)"').Groups[1].Value } else { '' }
  $whenOk   = $jsonOk -and ($whenRaw -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')
  $attOk    = $jsonOk -and ($obj.attempts -eq 0) -and (($obj.attempts -is [int]) -or ($obj.attempts -is [long]))
  $extraOk  = $jsonOk -and ($null -ne $obj.extra) -and ((@($obj.extra.PSObject.Properties.Name) -join ',') -eq 'package,resultPath,logPath')
  $pkgOk    = if ($PackageIsNull) { $jsonOk -and ($null -eq $obj.extra.package) } else { $jsonOk -and ($obj.extra.package -eq $ExpectPackage) }
  $pathsOk  = $jsonOk -and ($obj.extra.resultPath -eq $resultPath) -and ($obj.extra.logPath -eq $logPath)
  $sidOk    = $jsonOk -and ($obj.sessionId -eq 'probe-session-0001')
  $reasonOk = $jsonOk -and ($obj.reason -eq $ExpectReason)

  $checks = [ordered]@{
    'valid-json'      = $jsonOk
    'key-order(ps)'   = $keyOrderOk
    'key-order(raw)'  = $rawOrderOk
    'when-ISO-Z'      = $whenOk
    'attempts=0'      = $attOk
    'extra-keys'      = $extraOk
    'extra.package'   = $pkgOk
    'extra.paths'     = $pathsOk
    'sessionId'       = $sidOk
    'reason'          = $reasonOk
    'utf8-no-bom'     = -not $hasBom
    'no-tmp-left'     = ($tmpLeft.Count -eq 0)
  }
  $ok = -not ($checks.Values -contains $false)
  if (-not $ok) { $script:failures++ }

  Write-Host ("[3] {0}  {1}" -f $Label, $(if ($ok) { 'PASS' } else { 'FAIL' }))
  foreach ($k in $checks.Keys) { Write-Host ("      {0,-16} {1}" -f $k, $(if ($checks[$k]) { 'ok' } else { 'FAIL' })) }
  Write-Host ("      payload = {0}" -f $raw)
}

Write-Host ("[3] 临时目录 {0}" -f $work)

# 第一次：正常包名，文件不存在
Invoke-NoticeWrite -SessionId 'probe-session-0001' -Reason 'installed dsh-fake@1.0.0' -pkgName 'dsh-fake' -Spec 'dsh-fake@1.0.0'
Assert-Notice -Label 'run1 首次写入（文件原本不存在）' -ExpectPackage 'dsh-fake' -PackageIsNull $false -ExpectReason 'installed dsh-fake@1.0.0'

# 第二次：pkgName 为空 → 走 Get-SpecPackageName 从 Spec 去前缀；同时覆盖已存在的文件（Move-Item -Force 路径）
Invoke-NoticeWrite -SessionId 'probe-session-0001' -Reason 'installed @scope/fake@2.0.0' -pkgName $null -Spec '@scope/fake@2.0.0'
Assert-Notice -Label 'run2 覆盖写入 + pkgName 回落（Spec 去前缀）' -ExpectPackage '@scope/fake' -PackageIsNull $false -ExpectReason 'installed @scope/fake@2.0.0'

# 第三次：既无 pkgName 也无 Spec → package 必须是 null（契约允许 string|null）
Invoke-NoticeWrite -SessionId 'probe-session-0001' -Reason 'plugin-install' -pkgName $null -Spec $null
Assert-Notice -Label 'run3 无包名（package=null）' -ExpectPackage '' -PackageIsNull $true -ExpectReason 'plugin-install'

# 静态确认：调用点仍在「停止宿主」之前
$callLine = @(Select-String -LiteralPath $target -Pattern '^\s*Write-PendingNoticeSafe\s*$' | Select-Object -ExpandProperty LineNumber)
$stopLine = @(Select-String -LiteralPath $target -Pattern '停止宿主' | Select-Object -ExpandProperty LineNumber)
$orderOk = ($callLine.Count -ge 1 -and $stopLine.Count -ge 1 -and $callLine[0] -lt $stopLine[0])
Write-Host ("[4] 调用顺序：Write-PendingNoticeSafe @line {0} < 停止宿主 @line {1}  {2}" -f ($callLine -join '/'), ($stopLine -join '/'), $(if ($orderOk) { 'PASS' } else { 'FAIL' }))
if (-not $orderOk) { $script:failures++ }

if ($script:failures -ne 0) { Write-Host ("RESULT: FAIL（{0} 项）" -f $script:failures); exit 1 }
Write-Host 'RESULT: ALL PASS'
