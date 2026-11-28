# probe-clean-env.ps1
# 0.6.10 的回归探针：GUI 拉起的「干净环境」必须**删除** ELECTRON_RUN_AS_NODE，而不是置空。
#
# 为什么：Electron 判的是变量**存在**（base::Environment::HasVar），不是值真假。
# 留一个空值 `ELECTRON_RUN_AS_NODE=` 时，Electron 一样进 Node 模式：没有脚本参数就变成
# 「读 stdin 的 REPL」，stdin 是 NUL/管道 → 进程 <50ms 内 exit=0、stdout/stderr 全空、
# 不写 userData、不留 crash 记录。就绪等待只会看到「主进程已退出」，而同一秒手工拉起正常。
# 2026-11-28：0.6.9 的包装函数用 [Environment]::SetEnvironmentVariable(name, $null, 'Process')
# 做「删除」，PowerShell 把 $null 强制成 '' 传进去 —— 变量被置空而不是删除，于是每次真实拉起
# 都变 Node 模式、每次重启都 ready-failed:exited。本探针把三种处置语义和真实函数一起钉住。
#
# 只读脚本源码 + 进程内环境，不写状态目录、不碰宿主。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$engine = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/dsh-restart.ps1'
if (-not (Test-Path -LiteralPath $engine)) { throw "找不到 $engine" }
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($engine, [ref]$tokens, [ref]$parseErrors)
Write-Host ("[1] ParseFile scripts/dsh-restart.ps1  errors={0}" -f $parseErrors.Count)
if ($parseErrors.Count -ne 0) { exit 1 }

$script:failures = 0
function Assert-True([string]$Label, [bool]$Cond, [string]$Detail = '') {
  if ($Cond) {
    Write-Host ("  [ ok ] " + $Label)
  } else {
    Write-Host ("  [FAIL] " + $Label + $(if ($Detail) { "  → $Detail" } else { '' }))
    $script:failures++
  }
}
function Has-NodeVar {
  return [Environment]::GetEnvironmentVariables('Process').Contains('ELECTRON_RUN_AS_NODE')
}

# ---- ① 三种处置语义（本机 .NET + PowerShell 实测，写进断言防止语义漂移）
Write-Host '[2] 处置语义'
$env:ELECTRON_RUN_AS_NODE = '1'
[Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $null, 'Process')
Assert-True 'SetEnvironmentVariable(..., $null) 只置空、变量仍在（这正是 0.6.9 的坑）' (Has-NodeVar) 'PowerShell 把 $null 强制成空串'
$env:ELECTRON_RUN_AS_NODE = '1'
Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
Assert-True 'Remove-Item Env:ELECTRON_RUN_AS_NODE 真正删除' (-not (Has-NodeVar))

# ---- ② 真实函数：从引擎 AST 取出 Invoke-WithCleanGuiEnvironment，进程内点源后直接调用
Write-Host '[3] Invoke-WithCleanGuiEnvironment（取自引擎，非复制品）'
$fnAst = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-WithCleanGuiEnvironment' }, $true)
Assert-True '引擎里恰好有 1 个 Invoke-WithCleanGuiEnvironment' ($fnAst.Count -eq 1) ([string]$fnAst.Count)
if ($fnAst.Count -eq 1) {
  . ([scriptblock]::Create($fnAst[0].Extent.Text))

  # ②-A 调用方带着 =1：函数体内必须看不见这个变量
  $env:ELECTRON_RUN_AS_NODE = '1'
  $seenInside = Invoke-WithCleanGuiEnvironment { Has-NodeVar }
  Assert-True '带 =1 时，函数体内看不到 ELECTRON_RUN_AS_NODE' (-not [bool]$seenInside)
  Assert-True '调用后恢复调用方的值（=1）' ($env:ELECTRON_RUN_AS_NODE -eq '1') ("[" + $env:ELECTRON_RUN_AS_NODE + "]")

  # ②-B 调用方没有这个变量：函数体内外都必须没有（恢复不能凭空造一个空值）
  Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  $seenInside2 = Invoke-WithCleanGuiEnvironment { Has-NodeVar }
  Assert-True '本来没有时，函数体内看不到' (-not [bool]$seenInside2)
  Assert-True '本来没有时，调用后也不会凭空出现' (-not (Has-NodeVar))

  # ②-C 子进程视角：真正的 Electron 就是子进程，它拿到的环境块不许有这个键
  $env:ELECTRON_RUN_AS_NODE = '1'
  $childOut = Invoke-WithCleanGuiEnvironment { & cmd /c "set ELECTRON_RUN_AS_NODE" 2>&1 | Out-String }
  # 注意：cmd 在变量不存在时打印「环境变量 X 没有定义」，里面也含这个名字 —— 只认赋值形态。
  Assert-True '子进程 (cmd /c set) 看不到 ELECTRON_RUN_AS_NODE' (-not ($childOut -match '(?m)^ELECTRON_RUN_AS_NODE=')) ([string]$childOut.Trim())
  Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
}

if ($script:failures -ne 0) { Write-Host ("RESULT: FAIL（{0} 项）" -f $script:failures); exit 1 }
Write-Host 'RESULT: ALL PASS'
