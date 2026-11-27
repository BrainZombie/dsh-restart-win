# probe-hostport.ps1
# 真机（真 socket）验证 Resolve-HostPort 选面：
#   1) 从引擎 AST 里抽出真实的 Get-HostFaceRank / Get-HttpStatusCodeDetail / Invoke-HttpProbe /
#      Resolve-HostPort，原样执行 —— 不是复制一份逻辑来测；
#   2) 用 test/fixtures/face-server.mjs 起两个真实 HTTP 面：
#        A = 兜底路由（404 + application/json，几毫秒就答）
#        B = 宿主认证面（401 + text/plain；前 N 次请求故意拖过读超时）
#   3) 断言四种形状：
#        healthy   401 面正常 → 选 B（好路径不多花第二遍）
#        busy      401 面第一次读超时 → 第二遍补探后仍选 B（这就是 2026-11-27 的 -Status bug）
#        plain404  两个都是 404 → 选非 JSON 的那个（JSON 兜底面永远排在最后）
#        dead401   401 面两次都不回 → 退回 JSON 兜底面并如实报 404（不假装就绪）
#   4) 顺带验证 Save-AuxPortHint 是合并写入（CDP 200 面 + JSON 404 面两条发现都要留下）。
# 不碰生产宿主、不写 <DshHome>、不写真实状态目录。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$engine = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/dsh-restart.ps1'
$fixture = Join-Path $PSScriptRoot 'fixtures/face-server.mjs'
foreach ($f in @($engine, $fixture)) { if (-not (Test-Path -LiteralPath $f)) { throw "找不到 $f" } }

$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($engine, [ref]$tokens, [ref]$parseErrors)
Write-Host ("[1] ParseFile scripts/dsh-restart.ps1  errors={0}" -f $parseErrors.Count)
if ($parseErrors.Count -ne 0) { foreach ($e in $parseErrors) { Write-Host ("    {0} @ {1}" -f $e.ErrorId, $e.Extent.StartLineNumber) }; exit 1 }

function Get-FunctionText([string]$Name) {
  $hits = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
  if ($hits.Count -ne 1) { throw "期望恰好 1 个 $Name 定义，实际 $($hits.Count)" }
  return $hits[0].Extent.Text
}

$names = @('Get-HostFaceRank', 'Get-HttpStatusCodeDetail', 'Invoke-HttpProbe', 'Resolve-HostPort',
           'Get-JsonField', 'Get-AuxPortHint', 'Save-AuxPortHint')
$texts = @{}
foreach ($n in $names) { $texts[$n] = Get-FunctionText $n }
$totalChars = ($texts.Values | ForEach-Object { $_.Length } | Measure-Object -Sum).Sum
Write-Host ("[2] 已抽出 {0} 个真实函数（{1} 字符）" -f $names.Count, $totalChars)

$BindHost = '127.0.0.1'
$script:Phases = 0
function Add-Phase([string]$Name_) { $script:Phases++ }

foreach ($n in $names) { . ([scriptblock]::Create($texts[$n])) }

$node = (Get-Command node -ErrorAction Stop).Source
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('hostport-probe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$script:failures = 0

function Get-FreePort {
  $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $l.Start()
  $p = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port
  $l.Stop()
  return $p
}

function Invoke-Faces {
  param([string]$Mode, [int]$DelayMs, [int]$DelayCount, [scriptblock]$Assert)
  $a = Get-FreePort; $b = Get-FreePort
  while ($b -eq $a) { $b = Get-FreePort }
  $out = Join-Path $work ("faces-{0}.out" -f [guid]::NewGuid().ToString('N').Substring(0, 6))
  $err = Join-Path $work ("faces-{0}.err" -f [guid]::NewGuid().ToString('N').Substring(0, 6))
  $proc = Start-Process -FilePath $node -ArgumentList @($fixture, $a, $b, $Mode, $DelayMs, $DelayCount) `
            -WorkingDirectory $work -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $out -RedirectStandardError $err
  try {
    $ready = $false
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
      if ((Test-Path -LiteralPath $out) -and ((Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) -match 'READY')) { $ready = $true; break }
      Start-Sleep -Milliseconds 120
    }
    if (-not $ready) { throw ("fixture 没起来：" + ((Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue))) }
    $t0 = Get-Date
    $pick = Resolve-HostPort -Ports @($a, $b) -ConnectTimeoutMs 1500
    $sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    & $Assert $a $b $pick $sec
  } finally {
    try { & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $proc.Id /T /F *> $null } catch { }
    Start-Sleep -Milliseconds 200
  }
}

function Assert-True([string]$Label, [bool]$Cond, [string]$Detail) {
  if ($Cond) { Write-Host ("      ok   {0}" -f $Label) }
  else { Write-Host ("      FAIL {0} — {1}" -f $Label, $Detail); $script:failures++ }
}

Write-Host '[3] 真实 socket 四种形状'

# ---- 1. healthy
Invoke-Faces -Mode '401' -DelayMs 0 -DelayCount 0 -Assert {
  param($a, $b, $pick, $sec)
  $second = @($pick.order | Where-Object { $_.PSObject.Properties['pass'] -and [int]$_.pass -eq 2 })
  Write-Host ("  [healthy] A={0}(json404) B={1}(401) -> pick={2}/{3} ctx={4} in {5}s" -f $a, $b, $pick.port, $pick.status, $pick.contentType, $sec)
  Assert-True '选了认证面 B' ([int]$pick.port -eq $b) ("pick=" + $pick.port + " expected=" + $b)
  Assert-True '状态码 401' ([int]$pick.status -eq 401) ("status=" + $pick.status)
  Assert-True 'content-type 已读出' ([string]$pick.contentType -like 'text/plain*') ("ct=" + $pick.contentType)
  Assert-True '好路径不做第二遍' ($second.Count -eq 0) ("pass=2 entries=" + $second.Count)
}

# ---- 2. busy: 401 face times out once
Invoke-Faces -Mode '401' -DelayMs 6000 -DelayCount 1 -Assert {
  param($a, $b, $pick, $sec)
  $second = @($pick.order | Where-Object { $_.PSObject.Properties['pass'] -and [int]$_.pass -eq 2 })
  $firstZero = @($pick.order | Where-Object { [int]$_.port -eq $b -and [int]$_.status -eq 0 })
  Write-Host ("  [busy]    A={0} B={1}(401, 首次拖 6s) -> pick={2}/{3} pass2={4} in {5}s" -f $a, $b, $pick.port, $pick.status, $second.Count, $sec)
  Assert-True '第一遍确实读超时过（0）' ($firstZero.Count -ge 1) ("zero entries=" + $firstZero.Count)
  Assert-True '第二遍补探后选了 B' ([int]$pick.port -eq $b) ("pick=" + $pick.port + " expected=" + $b)
  Assert-True '状态码 401' ([int]$pick.status -eq 401) ("status=" + $pick.status)
  Assert-True '在预算内（<20s）' ($sec -lt 20) ("sec=" + $sec)
}

# ---- 3. both 404: JSON fallback must lose
Invoke-Faces -Mode '404' -DelayMs 0 -DelayCount 0 -Assert {
  param($a, $b, $pick, $sec)
  Write-Host ("  [plain404] A={0}(json) B={1}(text) -> pick={2}/{3} ct={4}" -f $a, $b, $pick.port, $pick.status, $pick.contentType)
  Assert-True '非 JSON 的 404 胜出' ([int]$pick.port -eq $b) ("pick=" + $pick.port + " expected=" + $b)
  Assert-True '状态码 404（如实报，不假装就绪）' ([int]$pick.status -eq 404) ("status=" + $pick.status)
}

# ---- 4. dead 401: fall back to the JSON face and say 404
Invoke-Faces -Mode '401' -DelayMs 6000 -DelayCount 2 -Assert {
  param($a, $b, $pick, $sec)
  Write-Host ("  [dead401] A={0}(json) B={1}(never answers) -> pick={2}/{3} in {4}s" -f $a, $b, $pick.port, $pick.status, $sec)
  Assert-True '退回 JSON 兜底面 A' ([int]$pick.port -eq $a) ("pick=" + $pick.port + " expected=" + $a)
  Assert-True '状态码 404' ([int]$pick.status -eq 404) ("status=" + $pick.status)
}

# ---- 5. Save-AuxPortHint merges
Write-Host '[4] aux 建议表：合并而非覆盖'
$StateDir = $work
function Get-StatePath([string]$Name) { return (Join-Path $StateDir $Name) }
function New-Utf8NoBom([string]$Path, [string]$Text) {
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
Save-AuxPortHint 4242 @(1111)
Save-AuxPortHint 4242 @(2222)
$hint = @(Get-AuxPortHint 4242)
Write-Host ("      learned = {0}" -f ($hint -join ','))
Assert-True '两次发现都留着' (($hint -contains 1111) -and ($hint -contains 2222)) ("hint=" + ($hint -join ','))
$raw = Get-Content -LiteralPath (Join-Path $work 'aux-ports.json') -Raw
Assert-True '按 pid 归属' ($raw -match '"mainPid":4242') $raw

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:failures -ne 0) { Write-Host ("RESULT: FAIL（{0} 项）" -f $script:failures); exit 1 }
Write-Host 'RESULT: ALL PASS'
