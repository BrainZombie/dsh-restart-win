<#
.SYNOPSIS
    dsh-restart 引擎健康自检：UTF-8 BOM + 纯 LF 换行 + pwsh 7 / Windows PowerShell 5.1 双引擎语法解析。

.DESCRIPTION
    本脚本只读取目标文件的字节，并让两个 PowerShell 引擎分别调用
    [System.Management.Automation.Language.Parser]::ParseFile 做语法解析；
    不执行目标脚本，不写注册表，不改计划任务，不碰 hosts，不触发任何重启。

    默认检查三个文件（不传 -Path 时）：
      · 同目录的 dsh-restart.ps1（引擎）
      · 同目录的 audit-profile.ps1（bundle 解析审计，只读）
      · 本脚本自身（check-encoding.ps1）

    对每个文件检查三项：
      1. 前 3 字节必须是 EF BB BF（UTF-8 BOM）。缺失时 PS 5.1 会按 GBK 解析，
         中文注释与字符串会被解成乱码并连带产生语法错误。
      2. 换行必须全是 LF；出现 CRLF（或单独 CR）即失败。
      3. pwsh 7 与 powershell.exe 5.1 的 ParseFile 都必须返回 errors=0。

    任一文件的任一项失败，退出码 1；全部通过打印 OK 并退出 0。

.PARAMETER Path
    要检查的 PowerShell 脚本路径，可给多个；给定时只检查这些文件（不再补默认目标）。
    传入本脚本自身的路径即可自检。

.EXAMPLE
    pwsh -NoProfile -File .\check-encoding.ps1

.EXAMPLE
    powershell.exe -NoProfile -File .\check-encoding.ps1 -Path .\check-encoding.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Path
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:FailureCount = 0
$script:CheckedCount = 0

function Write-Pass {
    param([string]$Label, [string]$Detail)
    $line = '  [PASS] ' + $Label
    if ($Detail) { $line = $line + '  ' + $Detail }
    Write-Host $line -ForegroundColor Green
}

function Write-Fail {
    param([string]$Label, [string]$Detail)
    $line = '  [FAIL] ' + $Label
    if ($Detail) { $line = $line + '  ' + $Detail }
    Write-Host $line -ForegroundColor Red
    $script:FailureCount = $script:FailureCount + 1
}

function Write-Step {
    param([string]$Label)
    Write-Host ''
    Write-Host ('[' + $Label + ']') -ForegroundColor Cyan
}

function Format-ByteHead {
    param([byte[]]$Bytes, [int]$Count)
    if ($null -eq $Bytes) { return '(无数据)' }
    if ($Bytes.Length -eq 0) { return '(空文件)' }
    $n = $Count
    if ($Bytes.Length -lt $n) { $n = $Bytes.Length }
    $parts = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $n; $i++) {
        $parts.Add($Bytes[$i].ToString('X2'))
    }
    return ($parts -join ' ')
}

# ---------------------------------------------------------------- 目标清单
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$targets = New-Object System.Collections.Generic.List[string]
if ($Path -and @($Path).Count -gt 0) {
    foreach ($p in @($Path)) {
        if (-not [string]::IsNullOrWhiteSpace($p)) { $targets.Add($p) }
    }
} else {
    # 默认：引擎 + audit-profile + install.ps1 + 本脚本自己（缺一个就报 FAIL，不做「悄悄少查一个」）
    # install.ps1 在仓库根、不在 scripts\ 下；它曾经在改写中丢过 BOM，5.1 直接解析失败 —— 所以必须查。
    $targets.Add((Join-Path $scriptDir 'dsh-restart.ps1'))
    $targets.Add((Join-Path $scriptDir 'audit-profile.ps1'))
    $targets.Add((Join-Path (Split-Path $scriptDir -Parent) 'install.ps1'))
    if ($PSCommandPath) { $targets.Add($PSCommandPath) }
    else { $targets.Add((Join-Path $scriptDir 'check-encoding.ps1')) }
}

if ($targets.Count -eq 0) {
    Write-Host ''
    Write-Host '  [FAIL] 没有要检查的目标文件' -ForegroundColor Red
    Write-Host ''
    Write-Host 'FAILED' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- 双引擎探测（每文件一次）
$probeTemplate = @'
$ErrorActionPreference = 'Stop'
$target = '__TARGET__'
$outFile = '__OUT__'
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('ENGINE=' + $PSVersionTable.PSVersion.ToString() + '|' + [string]$PSVersionTable.PSEdition)
try {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$parseErrors)
    if ($null -eq $parseErrors) {
        $lines.Add('ERRORS=0')
    } else {
        $lines.Add('ERRORS=' + $parseErrors.Count)
        $shown = 0
        foreach ($parseError in $parseErrors) {
            if ($shown -lt 5) {
                $lines.Add('DETAIL=line ' + $parseError.Extent.StartLineNumber + ': ' + $parseError.Message)
                $shown = $shown + 1
            }
        }
        if ($parseErrors.Count -gt $shown) {
            $lines.Add('MORE=' + ($parseErrors.Count - $shown))
        }
    }
} catch {
    $lines.Add('ERRORS=-1')
    $lines.Add('DETAIL=probe failed: ' + $_.Exception.Message)
}
[System.IO.File]::WriteAllLines($outFile, $lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
'@

function Invoke-EngineProbe {
    param(
        [string]$Exe,
        [string]$Label,
        [ValidateSet('pwsh7', 'ps51')]
        [string]$Kind,
        [string]$ProbeDir,
        [string]$ProbeTemplate,
        [string]$TargetLiteral
    )

    $outFile = Join-Path $ProbeDir ('probe-' + [guid]::NewGuid().ToString('N') + '.txt')
    $probe = $ProbeTemplate.Replace('__TARGET__', $TargetLiteral)
    $probe = $probe.Replace('__OUT__', $outFile.Replace("'", "''"))
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($probe))

    $nativeExit = -1
    $nativeError = ''
    try {
        $null = & $Exe -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1
        $nativeExit = $LASTEXITCODE
    } catch {
        $nativeError = $_.Exception.Message
    }

    $engine = ''
    $errors = -2
    $more = 0
    $details = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $outFile -PathType Leaf) {
        foreach ($line in [System.IO.File]::ReadAllLines($outFile)) {
            if ($line.StartsWith('ENGINE=')) {
                $engine = $line.Substring(7)
            } elseif ($line.StartsWith('ERRORS=')) {
                $errors = [int]$line.Substring(7)
            } elseif ($line.StartsWith('MORE=')) {
                $more = [int]$line.Substring(5)
            } elseif ($line.StartsWith('DETAIL=')) {
                $details.Add($line.Substring(7))
            }
        }
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    }

    if ($nativeError) {
        Write-Fail $Label ('启动失败: ' + $nativeError)
        return
    }
    if (-not $engine) {
        Write-Fail $Label ('探测未返回结果（exit=' + $nativeExit + '）')
        return
    }

    $parts = $engine.Split('|')
    $version = $parts[0]
    $major = 0
    [void][int]::TryParse(($version.Split('.'))[0], [ref]$major)
    $kindOk = $false
    if ($Kind -eq 'pwsh7' -and $major -ge 6) { $kindOk = $true }
    if ($Kind -eq 'ps51' -and $major -eq 5) { $kindOk = $true }
    if (-not $kindOk) {
        Write-Fail $Label ('引擎身份不符：期望 ' + $Kind + '，实际 ' + $engine)
        return
    }

    if ($errors -eq 0 -and $nativeExit -eq 0) {
        Write-Pass $Label ($engine + '  errors=0')
    } else {
        $msg = $engine + '  errors=' + $errors
        if ($details.Count -gt 0) { $msg = $msg + '  ' + ($details -join ' | ') }
        if ($more -gt 0) { $msg = $msg + '  …另有 ' + $more + ' 条' }
        Write-Fail $Label $msg
    }
}

# ---------------------------------------------------------------- 单个文件的三项检查
function Test-TargetFile {
    param(
        [string]$TargetPath,
        [string]$ProbeTemplate,
        [string]$PwshPath,
        [string]$Ps51Path
    )

    $target = $null
    try {
        $resolved = Resolve-Path -LiteralPath $TargetPath -ErrorAction Stop
        if ($null -ne $resolved) { $target = [string]$resolved.Path }
    } catch {
        $target = $null
    }

    Write-Host ''
    Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
    if (-not $target -or -not (Test-Path -LiteralPath $target -PathType Leaf)) {
        Write-Host ('目标: ' + $TargetPath)
        Write-Fail '目标脚本不存在或不是文件' $TargetPath
        return
    }
    $script:CheckedCount = $script:CheckedCount + 1
    Write-Host ('目标: ' + $target)

    $bytes = $null
    try {
        $bytes = [System.IO.File]::ReadAllBytes($target)
    } catch {
        Write-Fail '无法读取文件' $_.Exception.Message
        return
    }
    Write-Host ('大小: ' + $bytes.Length + ' 字节')

    # ---- 1/3 BOM
    Write-Step '1/3 UTF-8 BOM'
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if ($hasBom) {
        Write-Pass 'BOM' 'EF BB BF'
    } else {
        Write-Fail 'BOM' ('前 3 字节 = ' + (Format-ByteHead $bytes 3) + '；缺少 UTF-8 BOM，PS 5.1 会按 GBK 解析')
    }

    # ---- 2/3 换行
    Write-Step '2/3 换行符（必须纯 LF）'
    $lfCount = 0
    $crCount = 0
    $crlfCount = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $b = $bytes[$i]
        if ($b -eq 0x0A) {
            $lfCount = $lfCount + 1
            if ($i -gt 0 -and $bytes[$i - 1] -eq 0x0D) {
                $crlfCount = $crlfCount + 1
            }
        } elseif ($b -eq 0x0D) {
            $crCount = $crCount + 1
        }
    }
    $loneCr = $crCount - $crlfCount
    $eolDetail = 'LF=' + $lfCount + ', CRLF=' + $crlfCount + ', 单独 CR=' + $loneCr
    if ($crlfCount -eq 0 -and $loneCr -eq 0) {
        Write-Pass '换行' ($eolDetail + '（纯 LF）')
    } else {
        Write-Fail '换行' ($eolDetail + '；存在非 LF 换行，必须改为纯 LF')
    }

    # ---- 3/3 双引擎解析
    Write-Step '3/3 双引擎语法解析（ParseFile errors 必须为 0）'
    $targetLiteral = $target.Replace("'", "''")
    $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-check-encoding-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $probeDir -Force -ErrorAction Stop | Out-Null
        if ($PwshPath) {
            Invoke-EngineProbe -Exe $PwshPath -Label 'pwsh 7' -Kind 'pwsh7' -ProbeDir $probeDir -ProbeTemplate $ProbeTemplate -TargetLiteral $targetLiteral
        } else {
            Write-Fail 'pwsh 7' '找不到 pwsh.exe（PATH 与 %ProgramFiles%\PowerShell\7 都没有）'
        }
        if ($Ps51Path) {
            Invoke-EngineProbe -Exe $Ps51Path -Label 'Windows PowerShell 5.1' -Kind 'ps51' -ProbeDir $probeDir -ProbeTemplate $ProbeTemplate -TargetLiteral $targetLiteral
        } else {
            Write-Fail 'Windows PowerShell 5.1' ('找不到 ' + (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
        }
    } catch {
        Write-Fail '探测环境' $_.Exception.Message
    } finally {
        Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- 找两个引擎
$pwshPath = ''
$pwshCmd = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -ne $pwshCmd) { $pwshPath = [string]$pwshCmd.Source }
if (-not $pwshPath) {
    $fallback = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $fallback -PathType Leaf) { $pwshPath = $fallback }
}
$ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { $ps51Path = '' }

Write-Host ''
Write-Host '=== check-encoding : PowerShell 脚本健康自检 ===' -ForegroundColor Cyan

foreach ($t in $targets) {
    Test-TargetFile -TargetPath $t -ProbeTemplate $probeTemplate -PwshPath $pwshPath -Ps51Path $ps51Path
}

# ---------------------------------------------------------------- 结论
Write-Host ''
Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
Write-Host ('已检查 ' + $script:CheckedCount + ' 个文件；未通过项 ' + $script:FailureCount)
if ($script:FailureCount -eq 0) {
    Write-Host 'OK' -ForegroundColor Green
    exit 0
}
Write-Host ('FAILED（' + $script:FailureCount + ' 项检查未通过）') -ForegroundColor Red
exit 1
