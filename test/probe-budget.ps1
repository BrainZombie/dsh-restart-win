# probe-budget.ps1
# 从引擎 AST 抽出 Get-ActionBudgetPlan，逐模式验证：
#   1) 分项文本里的秒数之和 == Sec；
#   2) Sec 与预算公式一致（preflight / restart / start / stop / dry-run / skip）。
# 不写状态目录、不碰宿主。
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
. ([scriptblock]::Create((Get-FunctionText 'Get-ActionBudgetPlan')))

# 引擎变量在测试作用域里模拟
$script:GuiProbeTimeoutSec = 25
$Status = $false; $CheckShadowed = $false; $RepairSharedScope = $false; $Record = $false
$Preflight = $false; $VerifyOnly = $false; $HostKind = 'desktop'
$VerifyReadySec = 150; $SkipGuiProbe = $false
$DryRun = $false; $Stop = $false; $Start = $false; $Fast = $false
$PortFreeSec = 30; $ReadySec = 240; $GraceSec = 3
$script:failures = 0

function Assert-True([string]$Label, [bool]$Cond, [string]$Detail) {
  if ($Cond) { Write-Host ("      ok   {0}" -f $Label) }
  else { Write-Host ("      FAIL {0} - {1}" -f $Label, $Detail); $script:failures++ }
}

function Get-PartsSum($Parts) {
  $sum = 0
  foreach ($p in @($Parts)) {
    $m = [regex]::Match([string]$p, '(\d+)s')
    if ($m.Success) { $sum += [int]$m.Groups[1].Value }
  }
  return $sum
}

function Assert-Plan([string]$Label, [int]$ExpectedSec) {
  $plan = Get-ActionBudgetPlan
  $sum = Get-PartsSum $plan.Parts
  Write-Host ("  [{0}] sec={1} expected={2} parts={3}" -f $Label, $plan.Sec, $ExpectedSec, (@($plan.Parts) -join ' + '))
  Assert-True ("{0}: Sec 与公式一致" -f $Label) ([int]$plan.Sec -eq $ExpectedSec) ("sec=" + $plan.Sec + " expected=" + $ExpectedSec)
  Assert-True ("{0}: 分项之和 == Sec" -f $Label) ([int]$sum -eq [int]$plan.Sec) ("sum=" + $sum + " sec=" + $plan.Sec)
}

# preflight: 2*150 + 60 + 25
$Preflight = $true
Assert-Plan 'preflight' 385
# preflight 跳过冒烟: 2*150 + 60
$SkipGuiProbe = $true
Assert-Plan 'preflight-skip-gui' 360
$SkipGuiProbe = $false
$Preflight = $false

# restart: (2*150 + 60) + 25 + 30 + 240 + 3 + 60
Assert-Plan 'restart' 718
# restart 跳过冒烟
$SkipGuiProbe = $true
Assert-Plan 'restart-skip-gui' 693
$SkipGuiProbe = $false

# start（冷启动）：不验证、不冒烟；30 + 240 + 3 + 60
$Start = $true
Assert-Plan 'start' 333
$Start = $false

# stop：max(30, 30) + 30
$Stop = $true
Assert-Plan 'stop' 60
$Stop = $false

# dry-run：max(30, 240)
$DryRun = $true
Assert-Plan 'dry-run' 240
$DryRun = $false

# 只读动作：0，且无分项
$Status = $true
$plan = Get-ActionBudgetPlan
Assert-True 'status: Sec=0' ([int]$plan.Sec -eq 0) ([string]$plan.Sec)
Assert-True 'status: 无分项' (@($plan.Parts).Count -eq 0) (@($plan.Parts).Count)

if ($script:failures -ne 0) { Write-Host ("RESULT: FAIL（{0} 项）" -f $script:failures); exit 1 }
Write-Host 'RESULT: ALL PASS'
