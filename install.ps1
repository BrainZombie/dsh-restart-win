<#
.SYNOPSIS
    把本仓库（@brainzombie/dsh-restart-win）装进一个 DSH profile，并在 PATH 上放一个 dsh-restart-win shim。

.DESCRIPTION
    做四步，都是幂等的：
      1. 校验仓库完整性（package.json 的名字/bin、scripts\dsh-restart.ps1 必须在）；
      2. 把插件加进 profile：`dsh plugin --profile <p> add <repo>`（内部是 pnpm；装过就跳过，
         加 -Force 可强制重装；-SkipPluginAdd 表示你自己已经 pnpm link 过，只装 shim）；
      3. **激活**：把本包追加进 profile 的 `dsh.profile.bundles`；
      4. 在 %LOCALAPPDATA%\dsh-restart\bin 写 dsh-restart-win.cmd，并把该目录加进用户 PATH
         （已在 PATH 上就跳过；-NoPathUpdate 只写 shim 不改 PATH）。

    第 3 步为什么不能只靠第 2 步（这是发布阻断级的事实，不是保险）：
      `@deepseek-ai/dsh-app-boot/lib/index.js` 组装 profile 的层树时，只按
      `dsh.profile.bundles` 这一份**显式列表**的顺序去套各 bundle 的 patch，再叠 profile
      自己的 `cordis.patch.yml` 与 launcher 的 `--patch`。只被 add 进 dependencies 的包
      **不参与组装**，于是「装完、重启，也看不到任何工具」。
      反过来也有代价：把不是 bundle 的包写进 bundles 会让整个 profile 起不来
      （dsh-plugin-manager 的规则），所以本脚本写之前先验本包确实声明了 `dsh.bundle.patch`，
      写完立刻回读断言「该名字恰好 1 次 / 其他 bundle 顺序未变 / 顶层键与 dependencies 条目数未变」，
      任一不满足就还原备份并非零退出 —— 绝不留半改的 package.json。
      写回前会留 `package.json.bak-dsh-restart-win-<yyyyMMdd-HHmmss>` 备份。

    装完**不会**替你重启 DSH 宿主：新插件的工具面要等宿主重新启动后才会出现，重启由你本人执行。
    任何一步失败都直接报错退出（退出码 1），不静默、不降级。

.PARAMETER Profile
    DSH profile 名（默认 web）。

.PARAMETER PluginPath
    本仓库根目录（默认是本脚本所在目录）。

.PARAMETER ShimDir
    shim 的落盘目录（默认 %LOCALAPPDATA%\dsh-restart\bin，与旧 dsh-restart.cmd 同目录）。

.PARAMETER SkipPluginAdd
    跳过 `dsh plugin add`，只装 shim（适用于你已手动 pnpm link 的情形）。

.PARAMETER Force
    即使 profile 里已声明该依赖，也重新执行一次 `dsh plugin add`。

.PARAMETER SkipPathUpdate
    只写 shim，不修改用户 PATH（适合 PATH 由你自己管理的情形）。

.EXAMPLE
    pwsh -NoProfile -File .\install.ps1 -Profile web

.EXAMPLE
    pwsh -NoProfile -File .\install.ps1 -Profile web -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidatePattern('^[a-z0-9][a-z0-9._-]*$')]
    [string]$Profile = 'web',

    [string]$PluginPath = '',

    [string]$ShimDir = '',

    [switch]$SkipPluginAdd,

    [switch]$Force,

    [switch]$SkipPathUpdate
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$PACKAGE_NAME = '@brainzombie/dsh-restart-win'
$SHIM_NAME = 'dsh-restart-win.cmd'

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host ('== ' + $Text) -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host ('   ok   ' + $Text) -ForegroundColor Green
}

function Write-Skip {
    param([string]$Text)
    Write-Host ('   skip ' + $Text) -ForegroundColor DarkGray
}

function Stop-Fail {
    param([string]$Message)
    Write-Host ''
    Write-Host ('   FAIL ' + $Message) -ForegroundColor Red
    [Console]::Error.WriteLine('[install] 失败：' + $Message)
    exit 1
}

# ---------------------------------------------------------------- 0. 入参与仓库完整性
if (-not $PluginPath) {
    if (-not $PSScriptRoot) { Stop-Fail '拿不到脚本所在目录；请显式传 -PluginPath <repo>' }
    $PluginPath = $PSScriptRoot
}
if (-not (Test-Path -LiteralPath $PluginPath -PathType Container)) {
    Stop-Fail ('-PluginPath 不是目录：' + $PluginPath)
}
$PluginPath = (Resolve-Path -LiteralPath $PluginPath).ProviderPath

if (-not $ShimDir) {
    if (-not $env:LOCALAPPDATA) { Stop-Fail '环境里没有 %LOCALAPPDATA%；请显式传 -ShimDir' }
    $ShimDir = Join-Path $env:LOCALAPPDATA 'dsh-restart\bin'
}

$pkgJsonPath = Join-Path $PluginPath 'package.json'
$enginePath = Join-Path $PluginPath 'scripts\dsh-restart.ps1'
if (-not (Test-Path -LiteralPath $pkgJsonPath -PathType Leaf)) { Stop-Fail ('仓库不完整：缺少 ' + $pkgJsonPath) }
if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) { Stop-Fail ('仓库不完整：缺少 ' + $enginePath) }

$pkg = $null
try { $pkg = Get-Content -LiteralPath $pkgJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Stop-Fail ('package.json 解析失败：' + $_.Exception.Message) }
if ([string]$pkg.name -ne $PACKAGE_NAME) {
    Stop-Fail ('package.json 的 name 是「' + [string]$pkg.name + '」，期望「' + $PACKAGE_NAME + '」—— 装错仓库了？')
}

# CLI 入口取自 package.json 的 bin（字符串或 map 都认），不猜文件名
$binRel = ''
$binField = $pkg.PSObject.Properties['bin']
if ($null -ne $binField -and $null -ne $binField.Value) {
    if ($binField.Value -is [string]) {
        $binRel = [string]$binField.Value
    } else {
        $binProps = @($binField.Value.PSObject.Properties)
        $named = $binProps | Where-Object { $_.Name -eq 'dsh-restart-win' } | Select-Object -First 1
        if ($named) { $binRel = [string]$named.Value }
        elseif ($binProps.Count -gt 0) { $binRel = [string]$binProps[0].Value }
    }
}
if (-not $binRel) { Stop-Fail 'package.json 没声明 bin；无法生成 shim（CLI 入口未知）' }
$cliPath = Join-Path $PluginPath ($binRel -replace '/', '\')
if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) { Stop-Fail ('CLI 入口不存在：' + $cliPath) }

Write-Host ''
Write-Host '=== dsh-restart-win install ===' -ForegroundColor Cyan
Write-Host ('   仓库     : ' + $PluginPath)
Write-Host ('   profile  : ' + $Profile)
Write-Host ('   CLI      : ' + $cliPath)
Write-Host ('   shim 目录: ' + $ShimDir)
Write-Host ''
Write-Host '  注意：先确认没有 `dsh plugin …` / pnpm 正在运行，再执行本脚本。' -ForegroundColor Yellow
Write-Host '        CLI 对 profile 的 package.json 加了文件锁（withFileLock），而本脚本第 1 步调用它、' -ForegroundColor Yellow
Write-Host '        第 1b 步直接改同一个文件，两边同时写会互相覆盖。' -ForegroundColor Yellow

# ---------------------------------------------------------------- 1. 加进 profile
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$profPkgPath = Join-Path $dshHome ('profiles\' + $Profile + '\package.json')

Write-Step ('1/4 把 ' + $PACKAGE_NAME + ' 加进 profile「' + $Profile + '」')
if ($SkipPluginAdd) {
    Write-Skip '-SkipPluginAdd：按你的要求跳过 dsh plugin add（假定你已 pnpm link / 手动安装）'
} else {
    $dshCmd = Get-Command dsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $dshCmd) {
        Stop-Fail 'PATH 上找不到 dsh；先确认 DSH 已全局安装（或把它的目录加入 PATH），再重跑本脚本'
    }
    $already = $false
    if (Test-Path -LiteralPath $profPkgPath -PathType Leaf) {
        try {
            $profPkg = Get-Content -LiteralPath $profPkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $depBlock = $profPkg.PSObject.Properties['dependencies']
            if ($null -ne $depBlock -and $null -ne $depBlock.Value) {
                $dep = $depBlock.Value.PSObject.Properties[$PACKAGE_NAME]
                if ($null -ne $dep) { $already = $true }
            }
        } catch {
            # profile 的 package.json 读不动不是「已安装」，继续走 add（由 dsh/pnpm 自己报错）
            Write-Skip ('读取 ' + $profPkgPath + ' 失败（' + $_.Exception.Message + '），继续执行 add')
        }
    }
    if ($already -and -not $Force) {
        Write-Skip ('profile 里已声明 ' + $PACKAGE_NAME + '（加 -Force 可强制重装）')
    } elseif ($PSCmdlet.ShouldProcess(($PACKAGE_NAME + ' → profile ' + $Profile), 'dsh plugin add')) {
        # argv 数组调用，不拼 shell 字符串；profile 已由 ValidatePattern 白名单化
        & $dshCmd.Source plugin --profile $Profile add $PluginPath
        $rc = $LASTEXITCODE
        if ($rc -ne 0) { Stop-Fail ('dsh plugin add 退出码 ' + $rc + '（上面是 pnpm 的输出）') }
        Write-Ok ('已加入 profile「' + $Profile + '」')
    }
}

# ---------------------------------------------------------------- 1b. 激活：追加进 dsh.profile.bundles
Write-Step ('2/4 把 ' + $PACKAGE_NAME + ' 追加进 dsh.profile.bundles（激活；即 1b 步）')
# 只 add 依赖不构成激活：dsh-app-boot 组层树时只按 dsh.profile.bundles 里的显式列表套 patch，
# 只进 dependencies 的包不参与组装 → 装完重启也没有工具。
# 反过来，把不是 bundle 的包写进 bundles 会让整个 profile 起不来，所以先验 dsh.bundle.patch。
$ourPatch = ''
$dshField = $pkg.PSObject.Properties['dsh']
if ($null -ne $dshField -and $null -ne $dshField.Value) {
    $bundleField = $dshField.Value.PSObject.Properties['bundle']
    if ($null -ne $bundleField -and $null -ne $bundleField.Value) {
        $patchField = $bundleField.Value.PSObject.Properties['patch']
        if ($null -ne $patchField) { $ourPatch = [string]$patchField.Value }
    }
}
if (-not $ourPatch) {
    Stop-Fail ('本包不是合法 dsh bundle：' + $pkgJsonPath + ' 没有声明 dsh.bundle.patch。把它写进 dsh.profile.bundles 会让宿主启动失败，所以不写。')
}

if (-not (Test-Path -LiteralPath $profPkgPath -PathType Leaf)) {
    Stop-Fail ('profile 还没初始化：找不到 ' + $profPkgPath + '。先跑一次 `dsh --profile ' + $Profile + '` 生成它，或去掉 -SkipPluginAdd 让第 1 步完成初始化，再重跑本脚本。')
}
$profNow = $null
try { $profNow = Get-Content -LiteralPath $profPkgPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Stop-Fail ('读不出 profile 的 package.json：' + $profPkgPath + ' :: ' + $_.Exception.Message) }
if ($null -eq $profNow) { Stop-Fail ('profile 的 package.json 解析结果是 null：' + $profPkgPath) }

$topKeysNow = @($profNow.PSObject.Properties.Name)
$dshNode = $profNow.PSObject.Properties['dsh']
if ($null -eq $dshNode -or $null -eq $dshNode.Value) {
    Stop-Fail ('profile 的 package.json 没有 dsh 段（实际顶层键：' + ($topKeysNow -join ', ') + '）→ 不是预期的 profile 形状，不猜着改。')
}
$profNode = $dshNode.Value.PSObject.Properties['profile']
if ($null -eq $profNode -or $null -eq $profNode.Value) {
    Stop-Fail ('profile 的 package.json 里 dsh 段没有 profile（实际键：' + (@($dshNode.Value.PSObject.Properties.Name) -join ', ') + '）→ 不猜着改。')
}
$bundlesProp = $profNode.Value.PSObject.Properties['bundles']
$bundlesIsNew = $false
if ($null -eq $bundlesProp) {
    # 键不存在 = 还没激活过任何 bundle。这不是「形状不对」，按空列表处理并新建。
    $bundlesNow = @()
    $bundlesIsNew = $true
    Write-Host '   note  dsh.profile.bundles 不存在 → 按空列表处理并新建'
} elseif ($null -eq $bundlesProp.Value) {
    Stop-Fail ('dsh.profile.bundles 不是数组（实际：null）。位置：' + $profPkgPath)
} elseif ($bundlesProp.Value -isnot [System.Array]) {
    $shape = ''
    try { $shape = ($bundlesProp.Value | ConvertTo-Json -Compress -Depth 5) } catch { $shape = '<无法序列化>' }
    Stop-Fail ('dsh.profile.bundles 不是数组（实际类型 ' + $bundlesProp.Value.GetType().FullName + '，值：' + $shape + '）。位置：' + $profPkgPath)
} else {
    $bundlesNow = @($bundlesProp.Value | ForEach-Object { [string]$_ })
}

$alreadyBundled = @($bundlesNow | Where-Object { $_ -eq $PACKAGE_NAME }).Count

# 装配侧（node_modules）必须真的落地：宿主对「列了但没装」是**静默跳过**的
# （dsh-app-boot 把解析失败的 bundle 放进 skippedBundles，只打一行 skipping… 就继续启动），
# 所以「bundles 里有名字 + 包没落地」看起来像成功、实际一次都不会加载。-SkipPluginAdd 时
# 尤其要查这一侧：用户可能只是 pnpm link 了，而链接是坏的。
$installedDir = Join-Path (Join-Path (Join-Path $dshHome 'profiles') $Profile) ('node_modules\' + ($PACKAGE_NAME -replace '/', '\'))
$installedPkg = Join-Path $installedDir 'package.json'

function Get-InstalledName {
    if (-not (Test-Path -LiteralPath $installedPkg -PathType Leaf)) { return '' }
    try { return [string]((Get-Content -LiteralPath $installedPkg -Raw -Encoding UTF8 | ConvertFrom-Json).name) } catch { return '' }
}

$installedName = Get-InstalledName
if (-not $installedName) {
    if ($WhatIfPreference) {
        # 演练里第 1 步不会真跑，装配侧此刻当然可能还不存在 —— 不能因此让整个演练失败，
        # 但必须说清「实际安装会断言它」，别让演练看起来像已经验过装配侧。
        Write-Host ('   note  演练：装配侧此刻不存在（' + $installedPkg + '）；实际安装时会断言它存在且 name 匹配')
    } else {
        Stop-Fail ('包没落地：' + $installedPkg + ' 不存在或读不出 name。宿主对「列了但没装」是静默跳过，写进 bundles 只会假装成功 —— 先完成第 1 步（或检查你的 pnpm link）。')
    }
} elseif ($installedName -ne $PACKAGE_NAME) {
    Stop-Fail ('装配侧的包名对不上：' + $installedPkg + ' 里 name=' + $installedName + '，期望 ' + $PACKAGE_NAME + '。不写 bundles。')
}

# ---- JSON 定点编辑小工具（只认结构、不重排任何一个别的字节） ------------------
# 为什么不直接 ConvertTo-Json 写回：5.1 的输出是 4 空格缩进 + 冒号后两空格 + 嵌套右对齐 +
# `>` 转义成 \u003e（7 是 2 空格），同一份 manifest 会被整份重排；用户的 profile 往往在
# git 配置同步仓库里，那等于一次全文件提交。所以主路径是在**原始文本**上做定点插入。

function Read-JsonStringToken($Text, [int]$QuoteIndex, [int]$Limit) {
    # 从起始引号读一个 JSON 字符串 token；返回 @{ End = 闭合引号下标; Value = 内容(不完整反转义) }
    $j = $QuoteIndex + 1
    $escaped = $false
    $sb = New-Object System.Text.StringBuilder
    while ($j -lt $Limit) {
        $c = $Text[$j]
        if ($escaped) { [void]$sb.Append($c); $escaped = $false; $j++; continue }
        if ($c -eq '\') { $escaped = $true; $j++; continue }
        if ($c -eq '"') { return [pscustomobject]@{ End = $j; Value = $sb.ToString() } }
        [void]$sb.Append($c)
        $j++
    }
    return $null
}

function Get-JsonMatchingBracket($Text, [int]$OpenIndex, [int]$Limit) {
    # 从 { 或 [ 找配对闭合下标；字符串内容与转义一律跳过
    $openCh = $Text[$OpenIndex]
    $closeCh = if ($openCh -eq '{') { '}' } else { ']' }
    $depth = 0
    $j = $OpenIndex
    $inStr = $false
    $escaped = $false
    while ($j -lt $Limit) {
        $c = $Text[$j]
        if ($inStr) {
            if ($escaped) { $escaped = $false }
            elseif ($c -eq '\') { $escaped = $true }
            elseif ($c -eq '"') { $inStr = $false }
            $j++
            continue
        }
        if ($c -eq '"') { $inStr = $true; $j++; continue }
        if ($c -eq $openCh) { $depth++ }
        elseif ($c -eq $closeCh) { $depth--; if ($depth -eq 0) { return $j } }
        $j++
    }
    return -1
}

function Find-JsonMember($Text, [int]$ObjOpen, [int]$ObjClose, [string]$KeyName) {
    # 在对象 {ObjOpen..ObjClose} 的**直接成员**里找 KeyName → @{ ValueStart; ValueEnd; Kind }
    $j = $ObjOpen + 1
    while ($j -lt $ObjClose) {
        $c = $Text[$j]
        if ([char]::IsWhiteSpace($c) -or $c -eq ',') { $j++; continue }
        if ($c -ne '"') { return $null }
        $keyTok = Read-JsonStringToken $Text $j $ObjClose
        if ($null -eq $keyTok) { return $null }
        $k = [int]$keyTok.End + 1
        while ($k -lt $ObjClose -and [char]::IsWhiteSpace($Text[$k])) { $k++ }
        if ($k -ge $ObjClose -or $Text[$k] -ne ':') { return $null }
        $k++
        while ($k -lt $ObjClose -and [char]::IsWhiteSpace($Text[$k])) { $k++ }
        if ($k -ge $ObjClose) { return $null }
        $vStart = $k
        $kind = 'scalar'
        $vEnd = -1
        if ($Text[$k] -eq '{' -or $Text[$k] -eq '[') {
            $kind = if ($Text[$k] -eq '{') { 'object' } else { 'array' }
            $vEnd = Get-JsonMatchingBracket $Text $k $ObjClose
            if ($vEnd -lt 0) { return $null }
        } else {
            $m = $k
            $inStr = $false
            $escaped = $false
            $stop = -1
            while ($m -lt $ObjClose) {
                $c2 = $Text[$m]
                if ($inStr) {
                    if ($escaped) { $escaped = $false }
                    elseif ($c2 -eq '\') { $escaped = $true }
                    elseif ($c2 -eq '"') { $inStr = $false }
                } else {
                    if ($c2 -eq '"') { $inStr = $true }
                    elseif ($c2 -eq ',' -or $c2 -eq '}' -or $c2 -eq ']') { $stop = $m; break }
                }
                $m++
            }
            if ($stop -lt 0) { $stop = $ObjClose }
            $vEnd = $stop - 1
            while ($vEnd -gt $vStart -and [char]::IsWhiteSpace($Text[$vEnd])) { $vEnd-- }
        }
        if ($keyTok.Value -eq $KeyName) {
            return [pscustomobject]@{ ValueStart = $vStart; ValueEnd = $vEnd; Kind = $kind }
        }
        $j = $vEnd + 1
    }
    return $null
}

function Find-BundlesArrayAnchor([string]$Text) {
    # 严格按 dsh → profile → bundles 逐层定位（不用「第一个 bundles」：别处可能有同名键，
    # 依赖名里也可能含 bundles）。任一层不是对象/数组就返回 $null，交给回落路径。
    $i = 0
    $n = $Text.Length
    while ($i -lt $n -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
    if ($i -ge $n -or $Text[$i] -ne '{') { return $null }
    $rootClose = Get-JsonMatchingBracket $Text $i $n
    if ($rootClose -lt 0) { return $null }
    $dsh = Find-JsonMember $Text $i $rootClose 'dsh'
    if ($null -eq $dsh -or $dsh.Kind -ne 'object') { return $null }
    $prof = Find-JsonMember $Text ([int]$dsh.ValueStart) ([int]$dsh.ValueEnd) 'profile'
    if ($null -eq $prof -or $prof.Kind -ne 'object') { return $null }
    $bundles = Find-JsonMember $Text ([int]$prof.ValueStart) ([int]$prof.ValueEnd) 'bundles'
    if ($null -eq $bundles -or $bundles.Kind -ne 'array') { return $null }
    return [pscustomobject]@{ Open = [int]$bundles.ValueStart; Close = [int]$bundles.ValueEnd }
}

function Get-DominantEol([string]$Text) {
    # EOL 跟文件走：CRLF 多于纯 LF 就当 CRLF 文件；没有任何换行（单行 JSON）默认 LF。
    # 往 CRLF 文件里插 LF 会得到混合换行，比全 CRLF 更难 review。
    $crlf = ([regex]::Matches($Text, "`r`n")).Count
    $lf = ([regex]::Matches($Text, "`n")).Count - $crlf
    if ($crlf -gt $lf) { return "`r`n" }
    return "`n"
}

function Get-BundleInsertion([string]$Text, $Anchor, [string]$PackageName, [string]$Eol) {
    # 在原始文本里把 "<pkg>" 插到 bundles 数组末尾；返回 @{ Text; Insert }
    $open = [int]$Anchor.Open
    $close = [int]$Anchor.Close
    $inner = $Text.Substring($open + 1, $close - $open - 1)
    $elem = '"' + $PackageName + '"'
    $lastNonWs = -1
    for ($t = $inner.Length - 1; $t -ge 0; $t--) {
        if (-not [char]::IsWhiteSpace($inner[$t])) { $lastNonWs = $t; break }
    }
    if ($lastNonWs -lt 0) {
        # 空数组：没有兄弟元素借缩进 → 用 "bundles" 键的行首缩进 + 2 空格。
        # 若数组里已有换行，插 `EOL + 元素缩进 + 元素`（插在 `[` 之后）：`]` 前面原本就有换行，
        # 于是得到 `[` → 换行 → 元素 → 换行 → `]` 的正常形状，而不是 `["pkg"` 贴在一起。
        if ($inner.Contains("`n")) {
            $lineStart = $Text.Substring(0, $open).LastIndexOf("`n")
            $keyIndent = ''
            if ($lineStart -ge 0) { $keyIndent = [regex]::Match($Text.Substring($lineStart + 1), '^[ \t]*').Value }
            $elemIndent = $keyIndent + '  '
            $insert = $Eol + $elemIndent + $elem
            $at = $open + 1
        } else {
            $insert = $elem
            $at = $open + 1
        }
        return [pscustomobject]@{ Text = $Text.Substring(0, $at) + $insert + $Text.Substring($at); Insert = $insert }
    }
    if ($inner.Contains("`n")) {
        # 多行：缩进借上一个元素的行首空白
        $lines = $inner -split "`n"
        $elemIndent = ''
        for ($k = $lines.Count - 1; $k -ge 0; $k--) {
            $ln = $lines[$k]
            if ($ln.Trim() -ne '' -and $ln.Trim() -ne ',') {
                $elemIndent = [regex]::Match($ln, '^[ \t]*').Value
                break
            }
        }
        $insert = ',' + $Eol + $elemIndent + $elem
    } else {
        # 单行数组保持单行插入（不许为了统一把单行改成多行，否则字节增量断言就不成立了）
        $insert = ', ' + $elem
    }
    $at = $open + 1 + $lastNonWs + 1
    return [pscustomobject]@{ Text = $Text.Substring(0, $at) + $insert + $Text.Substring($at); Insert = $insert }
}

function Get-CanonicalManifest($PkgObj) {
    # 「除 dsh.profile.bundles 外深度相等」用的规范化文本：两边都清空该数组再统一序列化
    $clone = ($PkgObj | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json)
    $clone.dsh.profile.bundles = @()
    return [string]($clone | ConvertTo-Json -Depth 20 -Compress)
}

if ($alreadyBundled -gt 0) {
    Write-Skip ('dsh.profile.bundles 已含 ' + $PACKAGE_NAME + '（共 ' + @($bundlesNow).Count + ' 项，无需改动；装配侧 ' + $installedPkg + ' 存在且 name 匹配）')
} elseif ($PSCmdlet.ShouldProcess(($profPkgPath + ' → dsh.profile.bundles += ' + $PACKAGE_NAME), '备份并写回 profile package.json')) {
    $backupPath = $profPkgPath + '.bak-dsh-restart-win-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $profPkgPath -Destination $backupPath -Force -ErrorAction Stop
    Write-Ok ('已备份原文件 → ' + (Split-Path $backupPath -Leaf))

    # 原始字节：定点插入要按字节算增量，BOM 有无也要原样保留
    $origBytes = [System.IO.File]::ReadAllBytes($profPkgPath)
    $bomLen = 0
    if ($origBytes.Length -ge 3 -and $origBytes[0] -eq 0xEF -and $origBytes[1] -eq 0xBB -and $origBytes[2] -eq 0xBF) { $bomLen = 3 }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $origText = [System.Text.Encoding]::UTF8.GetString($origBytes, $bomLen, $origBytes.Length - $bomLen)
    # 换行风格按「CRLF 数 + 裸 LF 数」判定。断言必须比**风格**，不能比「CR 计数不变」：
    # 往 CRLF 文件里加一行本来就会多一个 CRLF（CR 计数 +1），拿「CR 不变」去卡必然误判。
    $crlfBefore = ([regex]::Matches($origText, "`r`n")).Count
    $lfTotalBefore = ([regex]::Matches($origText, "`n")).Count
    $lfOnlyBefore = $lfTotalBefore - $crlfBefore
    $eol = Get-DominantEol $origText
    $eolStyleBefore = if ($crlfBefore -gt 0 -and $lfOnlyBefore -eq 0) { 'crlf' }
                      elseif ($crlfBefore -eq 0) { 'lf' }
                      else { 'mixed' }
    if ($eolStyleBefore -eq 'mixed') {
        Write-Host ('   WARN  原文件换行是混合的（CRLF ' + $crlfBefore + ' / 裸 LF ' + $lfOnlyBefore + '）→ 按主导风格插入，既有行不动。') -ForegroundColor Yellow
    }
    $canonBefore = Get-CanonicalManifest $profNow
    $expectBundles = @(@($bundlesNow) + $PACKAGE_NAME)

    $problem = ''
    $mode = ''
    $anchorWhy = ''
    # 插入串自己的换行构成（断言要用：写入后 CRLF/裸 LF 的增量必须正好等于它）
    $insCrlf = 0
    $insLfOnly = 0

    $anchor = $null
    try { $anchor = Find-BundlesArrayAnchor $origText }
    catch { $anchorWhy = '定位异常：' + $_.Exception.Message.Split([char]10)[0] }
    if ($null -eq $anchor -and -not $anchorWhy) { $anchorWhy = '在 dsh.profile 里定位不到 bundles 数组字面量（结构不认识）' }

    if ($null -ne $anchor) {
        # ---- 主路径：定点插入，其余字节一律不动
        $mode = 'surgical'
        $insertBytes = 0
        try {
            $built = Get-BundleInsertion $origText $anchor $PACKAGE_NAME $eol
            $insertText = [string]$built.Insert
            $newBytes = $utf8NoBom.GetBytes([string]$built.Text)
            $final = $newBytes
            if ($bomLen -gt 0) {
                $final = New-Object 'System.Byte[]' ($newBytes.Length + $bomLen)
                $final[0] = 0xEF; $final[1] = 0xBB; $final[2] = 0xBF
                [Array]::Copy($newBytes, 0, $final, $bomLen, $newBytes.Length)
            }
            [System.IO.File]::WriteAllBytes($profPkgPath, $final)
            $insertBytes = $utf8NoBom.GetBytes($insertText).Length
            $insCrlf = ([regex]::Matches($insertText, "`r`n")).Count
            $insLfOnly = ([regex]::Matches($insertText, "`n")).Count - $insCrlf
            $delta = $final.Length - $origBytes.Length
            if ($delta -ne $insertBytes) {
                $problem = ('写入字节增量 ' + $delta + ' ≠ 插入串长度 ' + $insertBytes + '（说明有别的内容被重排了）')
            }
        } catch {
            $problem = '定点插入失败：' + $_.Exception.Message.Split([char]10)[0]
        }
    } else {
        # ---- 回落路径：重序列化。必须显式告警，绝不静默重排。
        $mode = 'fallback'
        Write-Host ''
        Write-Host ('   WARN  定点插入定位失败（' + $anchorWhy + '）→ 回落到重序列化：manifest 会被整份重排（缩进/冒号空格/转义都可能变）。原文件备份在 ' + $backupPath) -ForegroundColor Yellow
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            Write-Host '   WARN  当前是 Windows PowerShell 5.1：ConvertTo-Json 的排版与 pwsh 7 不同（4 空格缩进、冒号后两空格、> 转义成 \u003e），这次重排的差异会比 7 下更大。' -ForegroundColor Yellow
        }
        try {
            $profNow.dsh.profile.bundles = $expectBundles
            $body = ($profNow | ConvertTo-Json -Depth 10)
            $body = ($body -replace "`r`n", "`n")
            if ($eol -eq "`r`n") { $body = ($body -replace "`n", "`r`n") }
            $newBytes = $utf8NoBom.GetBytes($body + $eol)
            $final = $newBytes
            if ($bomLen -gt 0) {
                $final = New-Object 'System.Byte[]' ($newBytes.Length + $bomLen)
                $final[0] = 0xEF; $final[1] = 0xBB; $final[2] = 0xBF
                [Array]::Copy($newBytes, 0, $final, $bomLen, $newBytes.Length)
            }
            [System.IO.File]::WriteAllBytes($profPkgPath, $final)
        } catch {
            $problem = '重序列化写回失败：' + $_.Exception.Message.Split([char]10)[0]
        }
    }

    # ---- 写后断言（两条路径共用）：解析后深比较 + bundles +1/末位 + 换行风格 + 装配侧
    if (-not $problem) {
        try {
            $rawAfter = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($profPkgPath))
            $crlfAfter = ([regex]::Matches($rawAfter, "`r`n")).Count
            $lfOnlyAfter = ([regex]::Matches($rawAfter, "`n")).Count - $crlfAfter
            $styleAfter = if ($crlfAfter -gt 0 -and $lfOnlyAfter -eq 0) { 'crlf' }
                          elseif ($crlfAfter -eq 0) { 'lf' }
                          else { 'mixed' }
            $after = $rawAfter | ConvertFrom-Json
            $afterBundles = @($after.dsh.profile.bundles | ForEach-Object { [string]$_ })
            $nameCount = @($afterBundles | Where-Object { $_ -eq $PACKAGE_NAME }).Count
            $canonAfter = Get-CanonicalManifest $after
            $installedNameAfter = Get-InstalledName
            if ($nameCount -ne 1) {
                $problem = ('dsh.profile.bundles 里 ' + $PACKAGE_NAME + ' 出现 ' + $nameCount + ' 次（期望 1 次）')
            } elseif (($afterBundles -join '|') -ne ($expectBundles -join '|')) {
                $problem = ('bundles 内容/顺序不符：实际 [' + ($afterBundles -join ', ') + ']，期望 [' + ($expectBundles -join ', ') + ']')
            } elseif ($canonAfter -ne $canonBefore) {
                $problem = '除 dsh.profile.bundles 外还有内容被改动（深度比较不等）'
            } elseif ($mode -eq 'surgical' -and ($crlfAfter -ne ($crlfBefore + $insCrlf) -or $lfOnlyAfter -ne ($lfOnlyBefore + $insLfOnly))) {
                $problem = ('换行风格必须与写入前一致：CRLF ' + $crlfBefore + ' → ' + $crlfAfter + '（期望 +' + $insCrlf + '）、裸 LF ' + $lfOnlyBefore + ' → ' + $lfOnlyAfter + '（期望 +' + $insLfOnly + '）')
            } elseif ($mode -eq 'fallback' -and $styleAfter -ne $eolStyleBefore) {
                $problem = ('换行风格必须与写入前一致：CRLF ' + $crlfBefore + ' → ' + $crlfAfter + '、裸 LF ' + $lfOnlyBefore + ' → ' + $lfOnlyAfter)
            } elseif (-not $installedNameAfter) {
                $problem = ('装配侧包不见了：' + $installedPkg)
            } elseif ($installedNameAfter -ne $PACKAGE_NAME) {
                $problem = ('装配侧包名对不上：' + $installedPkg + ' 里 name=' + $installedNameAfter)
            }
        } catch {
            $problem = '回读/断言异常：' + $_.Exception.Message.Split([char]10)[0]
        }
    }

    if ($problem) {
        # 不留半改的文件：还原备份再报错
        Copy-Item -LiteralPath $backupPath -Destination $profPkgPath -Force -ErrorAction Stop
        Stop-Fail ('写回自检失败（已从备份还原）：' + $problem)
    }
    if ($mode -eq 'surgical') {
        Write-Ok ('已写入 ' + $profPkgPath + '（定点插入 +' + $insertBytes + ' 字节，其余字节未动；bundles ' + @($bundlesNow).Count + ' → ' + $expectBundles.Count + ' 项；EOL=' + $(if ($eol -eq "`r`n") { 'CRLF' } else { 'LF' }) + '）')
    } else {
        Write-Ok ('已写入 ' + $profPkgPath + '（回落重序列化，文件已重排；bundles ' + @($bundlesNow).Count + ' → ' + $expectBundles.Count + ' 项）')
    }
}

# ---------------------------------------------------------------- 2. PATH shim
Write-Step ('3/4 写 shim ' + $SHIM_NAME)
$shimPath = Join-Path $ShimDir $SHIM_NAME
# .cmd 给 cmd.exe 读：纯 ASCII 内容 + CRLF（cmd 的解析器对 LF-only 的标签不友好）
$shimLines = @(
    '@ECHO OFF'
    'REM dsh-restart-win shim - generated by install.ps1. ASCII ONLY ON PURPOSE.'
    'REM cmd.exe reads this file with the OEM codepage; non-ASCII comments become garbage commands.'
    'REM Prefers node from PATH and forwards every argument to the plugin CLI.'
    'SETLOCAL'
    ('SET "_CLI=' + $cliPath + '"')
    'IF NOT EXIST "%_CLI%" GOTO NOCLI'
    'WHERE node >NUL 2>NUL'
    'IF ERRORLEVEL 1 GOTO NONODE'
    'node "%_CLI%" %*'
    'SET "_RC=%ERRORLEVEL%"'
    'ENDLOCAL & EXIT /B %_RC%'
    ':NOCLI'
    'ECHO [dsh-restart-win] CLI not found: %_CLI%'
    'ECHO Re-run install.ps1 from the plugin repo.'
    'ENDLOCAL & EXIT /B 1'
    ':NONODE'
    'ECHO [dsh-restart-win] node.exe not found on PATH.'
    'ENDLOCAL & EXIT /B 1'
)
$shimText = ($shimLines -join "`r`n") + "`r`n"
$shimBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($shimText)

$needWrite = $true
if (Test-Path -LiteralPath $shimPath -PathType Leaf) {
    $existing = [System.IO.File]::ReadAllBytes($shimPath)
    if ($existing.Length -eq $shimBytes.Length) {
        $same = $true
        for ($i = 0; $i -lt $existing.Length; $i++) {
            if ($existing[$i] -ne $shimBytes[$i]) { $same = $false; break }
        }
        if ($same) { $needWrite = $false }
    }
}
if (-not $needWrite) {
    Write-Skip ('已是最新：' + $shimPath)
} elseif ($PSCmdlet.ShouldProcess($shimPath, '写 shim')) {
    if (-not (Test-Path -LiteralPath $ShimDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $ShimDir | Out-Null
    }
    [System.IO.File]::WriteAllBytes($shimPath, $shimBytes)
    Write-Ok ('已写入 ' + $shimPath)
}

# ---------------------------------------------------------------- 3. PATH
Write-Step '4/4 让 shim 目录出现在 PATH 上'
if ($SkipPathUpdate) {
    Write-Skip '-SkipPathUpdate：不改 PATH，请自行确保 %ShimDir% 在 PATH 上'
} else {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $userPath) { $userPath = '' }
    $segments = @($userPath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $present = $false
    foreach ($s in $segments) {
        if ($s.TrimEnd('\') -ieq $ShimDir.TrimEnd('\')) { $present = $true }
    }
    if ($present) {
        Write-Skip ('用户 PATH 已包含 ' + $ShimDir)
    } elseif ($PSCmdlet.ShouldProcess(('用户 PATH += ' + $ShimDir), 'SetEnvironmentVariable')) {
        $newPath = if ($userPath.Trim()) { $userPath.TrimEnd(';') + ';' + $ShimDir } else { $ShimDir }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Ok ('已加入用户 PATH：' + $ShimDir)
    }
    # 当前进程内也补上，方便本脚本随后的自检（不影响已有终端）
    $procSegments = @($env:PATH -split ';' | ForEach-Object { $_.Trim() })
    if (-not ($procSegments | Where-Object { $_.TrimEnd('\') -ieq $ShimDir.TrimEnd('\') })) {
        $env:PATH = $ShimDir + ';' + $env:PATH
    }
    Write-Host '   注意：PATH 变更对已经打开的终端不生效，只有新开的终端才看得到。'
}

# ---------------------------------------------------------------- 结论
# -WhatIf 是演练：什么都没装、什么都没写。结尾必须说清楚，否则「装好了，还差一步重启」
# 会让人以为已经装完（这也是本脚本最容易误导人的一行）。
$bundlesHint = '  确认已激活：' + $profPkgPath + ' 的 dsh.profile.bundles 里含 ' + $PACKAGE_NAME
if ($WhatIfPreference) {
    $rerun = if ($PSCommandPath) { 'pwsh -NoProfile -File "' + $PSCommandPath + '" -Profile ' + $Profile }
             else { 'pwsh -NoProfile -File install.ps1 -Profile ' + $Profile }
    Write-Host ''
    Write-Host '=== 演练完成：以上是计划动作，未做任何改动 ===' -ForegroundColor Yellow
    Write-Host '  真正的安装请去掉 -WhatIf 重跑：'
    Write-Host ('    ' + $rerun)
    Write-Host ''
    Write-Host '  装完之后仍然需要你本人重启 DSH 宿主 —— 新插件的工具（win_restart*）要等宿主重新启动后才会注册。'
    Write-Host '  重启后请确认两件事：'
    Write-Host ('    dsh --profile ' + $Profile + ' --dump-config   # 应能看到 dsh-restart-win 这一行')
    Write-Host $bundlesHint
    Write-Host ''
    exit 0
}

Write-Host ''
Write-Host '=== 装好了，还差一步：重启 DSH 宿主 ===' -ForegroundColor Yellow
Write-Host '  新插件的工具（win_restart*）要等宿主重新启动后才会注册；本脚本不会替你重启。'
Write-Host '  请你本人执行重启：在 DSH 会话里触发重启，或关掉宿主再重新启动。'
Write-Host ''
Write-Host '  重启后自检：'
Write-Host ('    dsh --profile ' + $Profile + ' --dump-config   # 应能看到 dsh-restart-win 条目')
Write-Host $bundlesHint
Write-Host '      （只 add 依赖不构成激活 —— 少了这条，重启后工具仍然不会出现）'
Write-Host '    dsh-restart-win -Status -Json              # 应输出单个 JSON 对象'
Write-Host '    dsh-restart-win -Preflight                 # 深度验证（耗时长，隔离实例真启一次）'
Write-Host ''
exit 0
