param(
    [string]$Packager = (Join-Path $PSScriptRoot '..\bin\Win32\Release\e-packager.exe'),
    [string]$OutputRoot = (Join-Path $PSScriptRoot "..\.autolinker\work\v128-roundtrip-$([guid]::NewGuid().ToString('N'))")
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$managedWorkRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '.autolinker\work'))
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$requiredPrefix = $managedWorkRoot.TrimEnd('\') + '\'
if (-not $OutputRoot.StartsWith($requiredPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputRoot must stay below $managedWorkRoot"
}

$Packager = (Resolve-Path -LiteralPath $Packager).Path
$consoleTemplate = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'eproj\e-console-exe-new-proj.e')).Path
$windowTemplate = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'eproj\e-window-exe-new-proj.e')).Path
$windowFullTemplate = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'eproj\e-window-exe-full.e')).Path
$utf8Bom = [Text.UTF8Encoding]::new($true)

function Invoke-Packager {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & $Packager @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "e-packager failed: $($Arguments -join ' ')"
    }
}

function Write-EText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text
    )
    $normalized = ($Text -replace "`r?`n", "`r`n").TrimEnd("`r", "`n") + "`r`n"
    [IO.File]::WriteAllText($Path, $normalized, $utf8Bom)
}

function Assert-RuntimeLayout {
    param([Parameter(Mandatory)][string]$Workspace)
    $toolRuntime = Join-Path $Workspace 'tool\RSCProject.dll'
    if (-not (Test-Path -LiteralPath $toolRuntime -PathType Leaf) -or
        (Get-Item -LiteralPath $toolRuntime).Length -le 0) {
        throw "tool runtime missing: $toolRuntime"
    }
    if (Test-Path -LiteralPath (Join-Path $Workspace 'RSCProject.dll')) {
        throw 'RSCProject.dll must not be copied to the workspace root'
    }
}

function Assert-SingleEmbeddedRuntime {
    param([Parameter(Mandatory)][string]$Workspace)
    Assert-RuntimeLayout $Workspace
    $expectedRuntime = [IO.Path]::GetFullPath((Join-Path $Workspace 'tool\RSCProject.dll'))
    $allRuntimes = @(Get-ChildItem -LiteralPath $Workspace -Filter 'RSCProject.dll' -File -Recurse)
    if ($allRuntimes.Count -ne 1 -or
        [IO.Path]::GetFullPath($allRuntimes[0].FullName) -ne $expectedRuntime) {
        throw "embedded RSCProject layout must contain only the top-level tool runtime: count=$($allRuntimes.Count)"
    }
}

function Read-Meta {
    param([Parameter(Mandatory)][string]$Workspace)
    $path = Join-Path $Workspace 'project\_meta.json'
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Normalize-Line {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    $normalized = $Line.Trim()
    $normalized = $normalized.Replace('＞', '>').Replace('＜', '<').Replace('＝', '=')
    $normalized = $normalized.Replace('＋', '+').Replace('－', '-').Replace('×', '*').Replace('％', '%')
    $normalized = $normalized.Replace('≠', '!=').Replace('<>', '!=').Replace('≤', '<=').Replace('≥', '>=')
    return $normalized
}

function Replace-NativeAsciiText {
    param(
        [Parameter(Mandatory)][string]$Base64,
        [Parameter(Mandatory)][string]$OldText,
        [Parameter(Mandatory)][string]$NewText
    )
    if ($OldText.Length -ne $NewText.Length) {
        throw 'native text sentinel must preserve byte length'
    }
    $bytes = [Convert]::FromBase64String($Base64)
    $oldBytes = [Text.Encoding]::ASCII.GetBytes($OldText)
    $newBytes = [Text.Encoding]::ASCII.GetBytes($NewText)
    $matchedOffset = -1
    for ($offset = 0; $offset -le $bytes.Length - $oldBytes.Length; $offset++) {
        $matches = $true
        for ($index = 0; $index -lt $oldBytes.Length; $index++) {
            if ($bytes[$offset + $index] -ne $oldBytes[$index]) {
                $matches = $false
                break
            }
        }
        if (-not $matches) {
            continue
        }
        if ($matchedOffset -ge 0) {
            throw "native text sentinel is ambiguous: $OldText"
        }
        $matchedOffset = $offset
    }
    if ($matchedOffset -lt 0) {
        throw "native text sentinel was not found: $OldText"
    }
    [Array]::Copy($newBytes, 0, $bytes, $matchedOffset, $newBytes.Length)
    return [Convert]::ToBase64String($bytes)
}

function Shift-FirstNativeReference {
    param([Parameter(Mandatory)][string]$Base64)
    $bytes = [Convert]::FromBase64String($Base64)
    if ($bytes.Length -lt 4) {
        throw 'native reference sentinel requires at least one offset'
    }
    $shifted = [BitConverter]::GetBytes([BitConverter]::ToInt32($bytes, 0) + 1)
    [Array]::Copy($shifted, 0, $bytes, 0, $shifted.Length)
    return [Convert]::ToBase64String($bytes)
}

function Test-NativeInt32Value {
    param(
        [Parameter(Mandatory)][string]$Base64,
        [Parameter(Mandatory)][int]$Value
    )
    $bytes = [Convert]::FromBase64String($Base64)
    for ($offset = 0; $offset + 4 -le $bytes.Length; $offset++) {
        if ([BitConverter]::ToInt32($bytes, $offset) -eq $Value) {
            return $true
        }
    }
    return $false
}

function Get-NativeByteSequenceCount {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][byte[]]$Sequence
    )
    if ($Sequence.Length -eq 0 -or $Bytes.Length -lt $Sequence.Length) {
        return 0
    }
    $count = 0
    for ($offset = 0; $offset -le $Bytes.Length - $Sequence.Length; $offset++) {
        $matches = $true
        for ($index = 0; $index -lt $Sequence.Length; $index++) {
            if ($Bytes[$offset + $index] -ne $Sequence[$index]) {
                $matches = $false
                break
            }
        }
        if ($matches) {
            $count++
        }
    }
    return $count
}

if (Test-Path -LiteralPath $OutputRoot) {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

$consoleWorkspace = Join-Path $OutputRoot 'console-workspace'
$windowWorkspace = Join-Path $OutputRoot 'window-workspace'
Invoke-Packager @('unpack', $consoleTemplate, $consoleWorkspace, '--main-only')
Invoke-Packager @('unpack', $windowTemplate, $windowWorkspace, '--main-only')
Assert-RuntimeLayout $consoleWorkspace
Assert-RuntimeLayout $windowWorkspace

$consoleMeta = Read-Meta $consoleWorkspace
$windowMeta = Read-Meta $windowWorkspace
if ($consoleMeta.projectSubsystem -ne 'console') {
    throw "console subsystem mismatch: $($consoleMeta.projectSubsystem)"
}
if ($windowMeta.projectSubsystem -ne 'windows') {
    throw "window subsystem mismatch: $($windowMeta.projectSubsystem)"
}

$unchangedConsole = Join-Path $OutputRoot 'console-unchanged.e'
$unchangedWindow = Join-Path $OutputRoot 'window-unchanged.e'
Invoke-Packager @('pack', $consoleWorkspace, $unchangedConsole)
Invoke-Packager @('pack', $windowWorkspace, $unchangedWindow)
if ((Get-FileHash -LiteralPath $consoleTemplate -Algorithm SHA256).Hash -ne
    (Get-FileHash -LiteralPath $unchangedConsole -Algorithm SHA256).Hash) {
    throw 'unchanged console template is not byte stable'
}
if ((Get-FileHash -LiteralPath $windowTemplate -Algorithm SHA256).Hash -ne
    (Get-FileHash -LiteralPath $unchangedWindow -Algorithm SHA256).Hash) {
    throw 'unchanged window template is not byte stable'
}

$genericModuleWorkspace = Join-Path $OutputRoot 'generic-ecom-module-workspace'
$genericHostWorkspace = Join-Path $OutputRoot 'generic-ecom-host-workspace'
Copy-Item -LiteralPath $consoleWorkspace -Destination $genericModuleWorkspace -Recurse
Copy-Item -LiteralPath $consoleWorkspace -Destination $genericHostWorkspace -Recurse

$genericModuleInfoPath = Join-Path $genericModuleWorkspace 'info.json'
$genericModuleInfo = Get-Content -LiteralPath $genericModuleInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
$genericModuleInfo.sourceFileKind = 'ec'
$genericModuleInfo.sourceFileName = 'GenericDependency.ec'
Write-EText $genericModuleInfoPath (($genericModuleInfo | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
$genericModuleMetaPath = Join-Path $genericModuleWorkspace 'project\_meta.json'
$genericModuleMeta = Get-Content -LiteralPath $genericModuleMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
$genericModuleMeta.sourceFileKind = 'ec'
Write-EText $genericModuleMetaPath (($genericModuleMeta | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
Write-EText (Join-Path $genericModuleWorkspace 'src\.常量.txt') @'
.版本 2

.常量 GenericPublicConstant, 42, 公开
'@

$genericModuleBridge = Join-Path $OutputRoot 'GenericDependency.ec.e'
$genericModulePath = Join-Path $OutputRoot 'GenericDependency.ec'
Invoke-Packager @('pack', $genericModuleWorkspace, $genericModuleBridge)
Copy-Item -LiteralPath $genericModuleBridge -Destination $genericModulePath
$genericHostNativePath = Join-Path $genericHostWorkspace 'project\.native_source.bin'
if (-not (Test-Path -LiteralPath $genericHostNativePath -PathType Leaf)) {
    throw 'generic update host is missing its initial native source evidence'
}
$genericHostNativeDigestBefore = [string](Read-Meta $genericHostWorkspace).nativeBundleDigest
Invoke-Packager @('update', $genericHostWorkspace, '--add-ecom', $genericModulePath)
$genericHostSource = Get-ChildItem -LiteralPath (Join-Path $genericHostWorkspace 'src') -Filter '*.txt' -File |
    Where-Object { -not $_.Name.StartsWith('.') } |
    Select-Object -First 1
if ($null -eq $genericHostSource) {
    throw 'generic update host source page is missing'
}
$genericHostSourceText = [IO.File]::ReadAllText($genericHostSource.FullName) + @'

.子程序 ReadGenericPublicConstant, 整数型
返回 (#GenericPublicConstant)
'@
Write-EText $genericHostSource.FullName $genericHostSourceText

if (-not (Test-Path -LiteralPath $genericHostNativePath -PathType Leaf)) {
    throw 'update --add-ecom discarded native source evidence required for safe semantic rebuild'
}
$genericHostNativeDigestAfter = [string](Read-Meta $genericHostWorkspace).nativeBundleDigest
if ($genericHostNativeDigestAfter -ne $genericHostNativeDigestBefore) {
    throw 'update --add-ecom rebound stale native bytes to the modified workspace digest'
}

$genericHostModulePath = Join-Path $genericHostWorkspace 'project\.module.json'
$genericHostModule = Get-Content -LiteralPath $genericHostModulePath -Raw -Encoding UTF8 | ConvertFrom-Json
$genericDependency = @($genericHostModule.dependencies | Where-Object { $_.kind -eq 'ecom' }) | Select-Object -Last 1
if ($null -eq $genericDependency) {
    throw 'update --add-ecom did not persist the dependency'
}
$expectedGenericModulePath = [IO.Path]::GetFullPath($genericModulePath)
if ([IO.Path]::GetFullPath([string]$genericDependency.resolvedPath) -ne $expectedGenericModulePath) {
    throw "update --add-ecom lost the resolved input path: $($genericDependency.resolvedPath)"
}
if ([string]::IsNullOrWhiteSpace([string]$genericDependency.localWorkspace) -or
    -not (Test-Path -LiteralPath (Join-Path $genericHostWorkspace $genericDependency.localWorkspace) -PathType Container)) {
    throw "update --add-ecom did not export a local module workspace: $($genericDependency.localWorkspace)"
}
Assert-SingleEmbeddedRuntime $genericHostWorkspace

$genericHostOutput = Join-Path $OutputRoot 'generic-ecom-host.e'
$genericHostUnpacked = Join-Path $OutputRoot 'generic-ecom-host-unpacked'
Invoke-Packager @('pack', $genericHostWorkspace, $genericHostOutput)
Invoke-Packager @('unpack', $genericHostOutput, $genericHostUnpacked, '--main-only')
$genericRoundtripModule = Get-Content -LiteralPath (Join-Path $genericHostUnpacked 'project\.module.json') -Raw -Encoding UTF8 |
    ConvertFrom-Json
if (@($genericRoundtripModule.dependencies | Where-Object { $_.kind -eq 'ecom' }).Count -ne 1) {
    throw 'update --add-ecom output reused stale native bytes and lost the added dependency'
}
$genericHostRoundtripSource = Get-ChildItem -LiteralPath (Join-Path $genericHostUnpacked 'src') -Filter '*.txt' -File |
    Where-Object { -not $_.Name.StartsWith('.') } |
    Select-Object -First 1
$genericHostRoundtripText = [IO.File]::ReadAllText($genericHostRoundtripSource.FullName)
if (-not $genericHostRoundtripText.Contains('#GenericPublicConstant') -or
    $genericHostRoundtripText.Contains('#_Const_0x')) {
    throw 'updated ECom public constant name degraded because a stale resource section was reused'
}

$programFile = Get-ChildItem -LiteralPath (Join-Path $consoleWorkspace 'src') -Filter '*.txt' -File |
    Where-Object { -not $_.Name.StartsWith('.') } |
    Select-Object -First 1
if ($null -eq $programFile) {
    throw 'console source page not found'
}

$programText = @'
.版本 2

.程序集 程序集1

.子程序 _启动子程序, 整数型, , 集中验证文本重建
.局部变量 结果, 整数型
.局部变量 动态数组, 整数型, , "0"
结果 ＝ 接收数据 (到字节集 ({1, 2, 3}), 2)  ' 字节集参数与赋值注释
.如果真 (结果 <> 0 且 结果 ％ 2 = 0)
    返回 (结果)  ' 分支返回注释
.如果真结束
返回 (0)  ' 尾部返回必须保留

.子程序 接收数据, 整数型, 公开
.参数 数据, 字节集
.参数 数值, 整数型
返回 (数值)
'@

$constantText = @'
.版本 2

.常量 RT_TRUE, 真, 公开, 布尔真常量
.常量 RT_FALSE, 假, , 布尔假常量
'@

$structText = @'
.版本 2

.数据类型 RT_RECORD, 公开, 第一行结构备注
第二行结构备注
.成员 数值, 整数型, , , 第一行成员备注
第二行成员备注
'@

$dllText = @'
.版本 2

.DLL命令 RT_GetTickCount, 整数型, "kernel32.dll", "GetTickCount", 公开, 第一行DLL备注
第二行DLL备注
.参数 保留值, 整数型, , 第一行参数备注
第二行参数备注
'@

Write-EText $programFile.FullName $programText
Write-EText (Join-Path $consoleWorkspace 'src\.常量.txt') $constantText
Write-EText (Join-Path $consoleWorkspace 'src\.数据类型.txt') $structText
Write-EText (Join-Path $consoleWorkspace 'src\.DLL声明.txt') $dllText
Invoke-Packager @('validate', $consoleWorkspace)

$candidate = Join-Path $OutputRoot 'roundtrip-core.e'
$unpacked1 = Join-Path $OutputRoot 'roundtrip-core-unpacked-1'
$candidate2 = Join-Path $OutputRoot 'roundtrip-core-2.e'
$unpacked2 = Join-Path $OutputRoot 'roundtrip-core-unpacked-2'
Invoke-Packager @('pack', $consoleWorkspace, $candidate)
Invoke-Packager @('unpack', $candidate, $unpacked1, '--main-only')
Invoke-Packager @('compare-bundle', $candidate, $unpacked1)
Invoke-Packager @('pack', $unpacked1, $candidate2)
Invoke-Packager @('unpack', $candidate2, $unpacked2, '--main-only')

# Exercise the public verifier as well as manual projection comparison.
Invoke-Packager @('verify-roundtrip', $candidate, (Join-Path $OutputRoot 'verified-往返'), (Join-Path $OutputRoot 'verified-output.e'))
$mismatchOutput = & $Packager compare-bundle $consoleTemplate $unpacked1 2>&1 | Out-String
if ($LASTEXITCODE -eq 0 -or -not $mismatchOutput.Contains('match=false')) {
    throw "semantic mismatch must return a failing exit code: $mismatchOutput"
}

$roundtripProgram = Get-ChildItem -LiteralPath (Join-Path $unpacked2 'src') -Filter '*.txt' -File |
    Where-Object { -not $_.Name.StartsWith('.') } |
    Select-Object -First 1
$actualLines = @([IO.File]::ReadAllLines($roundtripProgram.FullName) | ForEach-Object { Normalize-Line $_ })
$requiredLines = @(
    '结果 = 接收数据 (到字节集 ({1, 2, 3}), 2)  '' 字节集参数与赋值注释',
    '.如果真 (结果 != 0 且 结果 % 2 = 0)',
    '返回 (结果)  '' 分支返回注释',
    '返回 (0)  '' 尾部返回必须保留'
) | ForEach-Object { Normalize-Line $_ }
foreach ($requiredLine in $requiredLines) {
    if ($requiredLine -cnotin $actualLines) {
        throw "roundtrip source line missing: $requiredLine"
    }
}

$fixedText = @(
    [IO.File]::ReadAllText((Join-Path $unpacked2 'src\.常量.txt')),
    [IO.File]::ReadAllText((Join-Path $unpacked2 'src\.数据类型.txt')),
    [IO.File]::ReadAllText((Join-Path $unpacked2 'src\.DLL声明.txt'))
) -join "`n"
foreach ($requiredText in @('RT_TRUE', 'RT_FALSE', '第二行结构备注', '第二行成员备注', '第二行DLL备注', '第二行参数备注')) {
    if (-not $fixedText.Contains($requiredText)) {
        throw "roundtrip fixed-table text missing: $requiredText"
    }
}

$firstProjectionHash = (Get-FileHash -LiteralPath $roundtripProgram.FullName -Algorithm SHA256).Hash
$secondProgram = Get-ChildItem -LiteralPath (Join-Path $unpacked1 'src') -Filter '*.txt' -File |
    Where-Object { -not $_.Name.StartsWith('.') } |
    Select-Object -First 1
$secondProjectionHash = (Get-FileHash -LiteralPath $secondProgram.FullName -Algorithm SHA256).Hash
if ($firstProjectionHash -ne $secondProjectionHash) {
    throw 'second text projection is not stable'
}

$originalProgram = [IO.File]::ReadAllText($programFile.FullName)
try {
    Write-EText $programFile.FullName ($originalProgram + "`r`n.局部变量 错误数组, 整数型, 数组")
    $arrayOutput = & $Packager validate $consoleWorkspace 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or -not $arrayOutput.Contains('bad_array_variable_declaration')) {
        throw "invalid array declaration was not rejected: $arrayOutput"
    }

    Write-EText $programFile.FullName ($originalProgram + "`r`n这不是有效命令 (")
    $nonArrayOutput = & $Packager validate $consoleWorkspace 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "non-array text was incorrectly rejected by validate: $nonArrayOutput"
    }
}
finally {
    Write-EText $programFile.FullName $originalProgram
}

# A header change must change the native owner category while preserving method identity.
$kindWorkspace = Join-Path $OutputRoot 'kind-workspace'
Invoke-Packager @('unpack', $consoleTemplate, $kindWorkspace, '--main-only')
New-Item -ItemType Directory -Path (Join-Path $kindWorkspace 'src\ProbeGroup') | Out-Null
$kindSource = Join-Path $kindWorkspace 'src\ProbeGroup\CategoryProbe.txt'
$kindText = @'
.版本 2

.程序集 CategoryProbe,

.子程序 ProbeValue, 整数型, 公开
返回 (7)

.子程序 ProbeSplitValue, 文本型, 公开
.局部变量 pieces, 文本型, , "0"

pieces ＝ 分割文本 (“a|b”, “|”, )
返回 (pieces[1])

.子程序 ProbeCrossPage, 整数型, 公开
返回 (TailValue ())

.子程序 ProbeConstantValue, 整数型, 公开
返回 (#ProbeNativeConstant)
'@
Write-EText $kindSource $kindText
Write-EText (Join-Path $kindWorkspace 'src\TailProbe.txt') ".版本 2`r`n`r`n.程序集 TailProbe`r`n`r`n.子程序 TailValue, 整数型`r`n返回 (8)`r`n"
Write-EText (Join-Path $kindWorkspace 'src\.常量.txt') ".版本 2`r`n`r`n.常量 ProbeNativeConstant, 9, 公开`r`n"
$kindCandidate = Join-Path $OutputRoot 'kind-class.e'
$kindProjection = Join-Path $OutputRoot 'kind-class-unpacked'
Invoke-Packager @('pack', $kindWorkspace, $kindCandidate)
Invoke-Packager @('unpack', $kindCandidate, $kindProjection, '--main-only')
function Get-ProbeSnapshot([string]$root) {
    $snapshots = Get-Content -LiteralPath (Join-Path $root 'project\.native_source_map.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($snapshots | Where-Object { 'ProbeValue' -in $_.methods.name })[0]
}
function Assert-ProbeOrder([string]$root) {
    $snapshots = @(Get-Content -LiteralPath (Join-Path $root 'project\.native_source_map.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
    $probeIndex = [array]::FindIndex($snapshots, [Predicate[object]]{ param($item) 'ProbeValue' -in $item.methods.name })
    $tailIndex = [array]::FindIndex($snapshots, [Predicate[object]]{ param($item) 'TailValue' -in $item.methods.name })
    if ($probeIndex -lt 0 -or $tailIndex -lt 0 -or $probeIndex -ge $tailIndex) { throw 'converted class changed local source order' }
}
$classSnapshot = Get-ProbeSnapshot $kindProjection
Assert-ProbeOrder $kindProjection
if (($classSnapshot.classId -band 0xFF000000) -ne 0x49000000) { throw 'class category missing' }
if ($classSnapshot.methods[0].attr -ne 0x38) { throw 'new public class method attr is not canonical' }
$kindNativeMapPath = Join-Path $kindProjection 'project\.native_source_map.json'
$kindNativeMap = @(Get-Content -LiteralPath $kindNativeMapPath -Raw -Encoding UTF8 | ConvertFrom-Json)
$kindNativeProbe = @($kindNativeMap | Where-Object { 'ProbeValue' -in $_.methods.name })[0]
$kindNativeProbe.methods[0].attr = 0x08
$kindSplitMethod = @($kindNativeProbe.methods | Where-Object { $_.name -eq 'ProbeSplitValue' })[0]
$kindCrossMethod = @($kindNativeProbe.methods | Where-Object { $_.name -eq 'ProbeCrossPage' })[0]
$kindConstantMethod = @($kindNativeProbe.methods | Where-Object { $_.name -eq 'ProbeConstantValue' })[0]
if ($null -eq $kindSplitMethod -or $null -eq $kindCrossMethod -or $null -eq $kindConstantMethod) {
    throw 'category conversion semantic probes are missing'
}
$splitExpressionBaseline = $kindSplitMethod.expressionData
$splitVariableReferenceBaseline = $kindSplitMethod.variableReference
$crossMethodReferenceBaseline = $kindCrossMethod.methodReference
$constantExpressionBaseline = $kindConstantMethod.expressionData
$constantReferenceBaseline = $kindConstantMethod.constantReference
$constantReferenceBytes = [Convert]::FromBase64String($kindConstantMethod.constantReference)
$constantExpressionBytes = [Convert]::FromBase64String($kindConstantMethod.expressionData)
if ($constantReferenceBytes.Length -ne 4) { throw 'raw project constant probe must have one native reference' }
$constantReferenceOffset = [BitConverter]::ToInt32($constantReferenceBytes, 0)
if ($constantReferenceOffset -lt 0 -or
    $constantReferenceOffset + 5 -gt $constantExpressionBytes.Length -or
    $constantExpressionBytes[$constantReferenceOffset] -ne 0x1B) {
    throw 'raw project constant probe native reference is invalid'
}
$rawProjectConstantId = [BitConverter]::ToInt32($constantExpressionBytes, $constantReferenceOffset + 1)
if (($rawProjectConstantId -band 0xFF000000) -ne 0x18000000) {
    throw ('raw project constant probe id has wrong type: 0x{0:X8}' -f $rawProjectConstantId)
}
$rawProjectConstantAlias = '_Const_0x{0:X}' -f ($rawProjectConstantId -band 0x00FFFFFF)
$injectedSplitExpression = Replace-NativeAsciiText $kindSplitMethod.expressionData 'a|b' 'x|y'
$injectedSplitVariableReference = Shift-FirstNativeReference $kindSplitMethod.variableReference
$injectedCrossMethodReference = Shift-FirstNativeReference $kindCrossMethod.methodReference

# A class declaration shape change invalidates the class block and its member
# identities even when every method body is textually unchanged. Rebuild the
# class variables and method code instead of combining them with stale payloads.
$shapeSeedWorkspace = Join-Path $OutputRoot 'class-shape-seed-workspace'
Copy-Item -LiteralPath $kindProjection -Destination $shapeSeedWorkspace -Recurse
$shapeSeedSource = Join-Path $shapeSeedWorkspace 'src\ProbeGroup\CategoryProbe.txt'
$shapeSeedText = $kindText.Replace(
    '.程序集 CategoryProbe,',
    ".程序集 CategoryProbe,`r`n`r`n.程序集变量 StableValue, 整数型, , , baseline") + @'

.子程序 ProbeMemberValue, 整数型, 公开
返回 (StableValue)
'@
Write-EText $shapeSeedSource $shapeSeedText
$shapeSeedCandidate = Join-Path $OutputRoot 'class-shape-seed.e'
$shapeSeedProjection = Join-Path $OutputRoot 'class-shape-seed-unpacked'
Invoke-Packager @('pack', $shapeSeedWorkspace, $shapeSeedCandidate)
Invoke-Packager @('unpack', $shapeSeedCandidate, $shapeSeedProjection, '--main-only')
$shapeSeedSnapshot = Get-ProbeSnapshot $shapeSeedProjection
if (@($shapeSeedSnapshot.classVarIds).Count -ne 1) {
    throw 'class shape seed did not create one class variable'
}
$shapeSeedClassId = $shapeSeedSnapshot.classId
$shapeSeedClassVarId = $shapeSeedSnapshot.classVarIds[0]
$shapeSeedClassVarType = $shapeSeedSnapshot.classVarTypes[0]
$shapeSeedMemberMethod = @($shapeSeedSnapshot.methods | Where-Object { $_.name -eq 'ProbeMemberValue' })[0]
if ($null -eq $shapeSeedMemberMethod -or
    -not (Test-NativeInt32Value $shapeSeedMemberMethod.expressionData $shapeSeedClassVarId)) {
    throw 'class shape seed member method does not contain its native class-variable id'
}
$shapeWorkspace = Join-Path $OutputRoot 'class-shape-change-workspace'
Copy-Item -LiteralPath $shapeSeedProjection -Destination $shapeWorkspace -Recurse
$shapeSource = Join-Path $shapeWorkspace 'src\ProbeGroup\CategoryProbe.txt'
$shapeChangedText = ([IO.File]::ReadAllText($shapeSource)).Replace(
    '.程序集变量 StableValue, 整数型, , , baseline',
    '.程序集变量 StableValue, 整数型, , , changed')
Write-EText $shapeSource $shapeChangedText
$shapeMapPath = Join-Path $shapeWorkspace 'project\.native_source_map.json'
$shapeMap = @(Get-Content -LiteralPath $shapeMapPath -Raw -Encoding UTF8 | ConvertFrom-Json)
$shapeProbe = @($shapeMap | Where-Object { 'ProbeValue' -in $_.methods.name })[0]
$shapeSplit = @($shapeProbe.methods | Where-Object { $_.name -eq 'ProbeSplitValue' })[0]
$shapeStaleMemoryAddress = 0x23456789
$shapeProbe.classMemoryAddress = $shapeStaleMemoryAddress
$shapeSplit.expressionData = $injectedSplitExpression
Write-EText $shapeMapPath (($shapeMap | ConvertTo-Json -Depth 20) + "`r`n")
$shapeCandidate = Join-Path $OutputRoot 'class-shape-change.e'
$shapeProjection = Join-Path $OutputRoot 'class-shape-change-unpacked'
Invoke-Packager @('pack', $shapeWorkspace, $shapeCandidate)
Invoke-Packager @('unpack', $shapeCandidate, $shapeProjection, '--main-only')
$shapeOutput = Get-ProbeSnapshot $shapeProjection
if ($shapeOutput.classId -ne $shapeSeedClassId) {
    throw 'class shape change discarded the compatible owner identity'
}
if ($shapeOutput.classMemoryAddress -eq $shapeStaleMemoryAddress) {
    throw 'class shape change reused the stale class address'
}
if (@($shapeOutput.classVarIds).Count -ne 1 -or
    $shapeOutput.classVarIds[0] -eq $shapeSeedClassVarId -or
    ($shapeOutput.classVarIds[0] -band 0xFF000000) -ne 0x15000000) {
    throw 'class shape change reused stale class-variable identity'
}
if ($shapeOutput.classVarTypes[0] -ne $shapeSeedClassVarType) {
    throw 'class shape change did not rebuild the declared class-variable type'
}
$shapeOutputSplit = @($shapeOutput.methods | Where-Object { $_.name -eq 'ProbeSplitValue' })[0]
if ($shapeOutputSplit.expressionData -ne $injectedSplitExpression) {
    throw 'class shape change rebuilt an unrelated exact method payload'
}
$shapeOutputMemberMethod = @($shapeOutput.methods | Where-Object { $_.name -eq 'ProbeMemberValue' })[0]
if ($shapeOutputMemberMethod.expressionData -eq $shapeSeedMemberMethod.expressionData -or
    (Test-NativeInt32Value $shapeOutputMemberMethod.expressionData $shapeSeedClassVarId)) {
    throw 'class shape change retained a method payload that references the stale class variable'
}
$shapeOutputText = [IO.File]::ReadAllText((Join-Path $shapeProjection 'src\ProbeGroup\CategoryProbe.txt'))
if (-not $shapeOutputText.Contains('.程序集变量 StableValue, 整数型, , , changed')) {
    throw 'class shape change lost the edited class-variable declaration'
}
$shapeVerifiedRoot = Join-Path $OutputRoot 'class-shape-change-verified'
Invoke-Packager @('verify-roundtrip', $shapeCandidate, $shapeVerifiedRoot, (Join-Path $OutputRoot 'class-shape-change-verified.e'))
$shapeVerifiedFirst = Get-ProbeSnapshot (Join-Path $shapeVerifiedRoot 'original_unpacked')
$shapeVerifiedSecond = Get-ProbeSnapshot (Join-Path $shapeVerifiedRoot 'roundtrip_unpacked')
if ($shapeVerifiedFirst.classId -ne $shapeVerifiedSecond.classId -or
    $shapeVerifiedFirst.classVarIds[0] -ne $shapeVerifiedSecond.classVarIds[0] -or
    $shapeVerifiedFirst.methods[0].expressionData -ne $shapeVerifiedSecond.methods[0].expressionData) {
    throw 'class shape rebuild is not stable across the second roundtrip'
}

# Adding/removing/reordering methods changes the class method table and invalidates
# the old class block address. Existing exact method payloads remain reusable when
# they do not reference a removed or signature-changed method identity.
$inventoryWorkspace = Join-Path $OutputRoot 'class-method-inventory-workspace'
Copy-Item -LiteralPath $kindProjection -Destination $inventoryWorkspace -Recurse
$inventorySource = Join-Path $inventoryWorkspace 'src\ProbeGroup\CategoryProbe.txt'
$inventoryText = [IO.File]::ReadAllText($inventorySource) + @'

.子程序 ProbeAdded, 整数型, 公开
返回 (11)
'@
Write-EText $inventorySource $inventoryText
$inventoryMapPath = Join-Path $inventoryWorkspace 'project\.native_source_map.json'
$inventoryMap = @(Get-Content -LiteralPath $inventoryMapPath -Raw -Encoding UTF8 | ConvertFrom-Json)
$inventoryProbe = @($inventoryMap | Where-Object { 'ProbeValue' -in $_.methods.name })[0]
$inventorySplit = @($inventoryProbe.methods | Where-Object { $_.name -eq 'ProbeSplitValue' })[0]
$inventoryStaleMemoryAddress = 0x3456789A
$inventoryProbe.classMemoryAddress = $inventoryStaleMemoryAddress
$inventorySplit.expressionData = $injectedSplitExpression
Write-EText $inventoryMapPath (($inventoryMap | ConvertTo-Json -Depth 20) + "`r`n")
$inventoryCandidate = Join-Path $OutputRoot 'class-method-inventory.e'
$inventoryProjection = Join-Path $OutputRoot 'class-method-inventory-unpacked'
Invoke-Packager @('pack', $inventoryWorkspace, $inventoryCandidate)
Invoke-Packager @('unpack', $inventoryCandidate, $inventoryProjection, '--main-only')
$inventoryOutput = Get-ProbeSnapshot $inventoryProjection
if ($inventoryOutput.classMemoryAddress -eq $inventoryStaleMemoryAddress) {
    throw 'class method inventory change reused the stale class address'
}
if (@($inventoryOutput.methods).Count -ne (@($inventoryProbe.methods).Count + 1) -or
    $null -eq @($inventoryOutput.methods | Where-Object { $_.name -eq 'ProbeAdded' })[0]) {
    throw 'class method inventory change did not rebuild the method table'
}
$inventoryOutputSplit = @($inventoryOutput.methods | Where-Object { $_.name -eq 'ProbeSplitValue' })[0]
if ($inventoryOutputSplit.expressionData -ne $injectedSplitExpression) {
    throw 'class method inventory change rebuilt an unrelated exact method payload'
}

# A data-type shape change keeps the owner and declaration-identical member
# identities. Exact method payloads that reference those stable members remain
# reusable, while the changed structure address is discarded.
$structSeedWorkspace = Join-Path $OutputRoot 'struct-shape-seed-workspace'
Invoke-Packager @('unpack', $consoleTemplate, $structSeedWorkspace, '--main-only')
$structSeedSource = Join-Path $structSeedWorkspace 'src\StructProbe.txt'
Write-EText $structSeedSource @'
.版本 2

.程序集 StructProbe

.子程序 ProbeStructValue, 整数型, 公开
.局部变量 item, ProbeRecord

返回 (item.Stable)
'@
Write-EText (Join-Path $structSeedWorkspace 'src\.数据类型.txt') @'
.版本 2

.数据类型 ProbeRecord, 公开
.成员 Stable, 整数型, , , retained member
'@
$structSeedCandidate = Join-Path $OutputRoot 'struct-shape-seed.e'
$structSeedProjection = Join-Path $OutputRoot 'struct-shape-seed-unpacked'
Invoke-Packager @('pack', $structSeedWorkspace, $structSeedCandidate)
Invoke-Packager @('unpack', $structSeedCandidate, $structSeedProjection, '--main-only')
$structSeedSymbolMap = Get-Content -LiteralPath (Join-Path $structSeedProjection 'project\.native_symbol_map.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$structSeedSnapshot = @($structSeedSymbolMap.structs | Where-Object { $_.name -eq 'ProbeRecord' })[0]
if ($null -eq $structSeedSnapshot -or @($structSeedSnapshot.memberIds).Count -ne 1) {
    throw 'struct shape seed did not create one native member'
}
$structSeedSourceMap = @(Get-Content -LiteralPath (Join-Path $structSeedProjection 'project\.native_source_map.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
$structSeedClass = @($structSeedSourceMap | Where-Object { 'ProbeStructValue' -in $_.methods.name })[0]
$structSeedMethod = @($structSeedClass.methods | Where-Object { $_.name -eq 'ProbeStructValue' })[0]
$structSeedId = [int]$structSeedSnapshot.id
$structStableMemberId = [int]$structSeedSnapshot.memberIds[0]
if ($null -eq $structSeedMethod -or
    -not (Test-NativeInt32Value $structSeedMethod.expressionData $structStableMemberId)) {
    throw 'struct shape seed method does not reference its native member id'
}

$structShapeWorkspace = Join-Path $OutputRoot 'struct-shape-change-workspace'
Copy-Item -LiteralPath $structSeedProjection -Destination $structShapeWorkspace -Recurse
$structShapeTypePath = Join-Path $structShapeWorkspace 'src\.数据类型.txt'
$structShapeText = [IO.File]::ReadAllText($structShapeTypePath).Replace(
    '.数据类型 ProbeRecord, 公开',
    ".数据类型 ProbeRecord, 公开`r`n.成员 Added, 整数型, , , inserted member")
Write-EText $structShapeTypePath $structShapeText
$structShapeMapPath = Join-Path $structShapeWorkspace 'project\.native_symbol_map.json'
$structShapeMap = Get-Content -LiteralPath $structShapeMapPath -Raw -Encoding UTF8 | ConvertFrom-Json
$structShapeSnapshot = @($structShapeMap.structs | Where-Object { $_.name -eq 'ProbeRecord' })[0]
$structShapeStaleMemoryAddress = 0x456789AB
$structShapeSnapshot.memoryAddress = $structShapeStaleMemoryAddress
Write-EText $structShapeMapPath (($structShapeMap | ConvertTo-Json -Depth 20) + "`r`n")
$structShapeCandidate = Join-Path $OutputRoot 'struct-shape-change.e'
$structShapeProjection = Join-Path $OutputRoot 'struct-shape-change-unpacked'
Invoke-Packager @('pack', $structShapeWorkspace, $structShapeCandidate)
Invoke-Packager @('unpack', $structShapeCandidate, $structShapeProjection, '--main-only')
$structShapeOutputMap = Get-Content -LiteralPath (Join-Path $structShapeProjection 'project\.native_symbol_map.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$structShapeOutput = @($structShapeOutputMap.structs | Where-Object { $_.name -eq 'ProbeRecord' })[0]
if ($null -eq $structShapeOutput -or [int]$structShapeOutput.id -ne $structSeedId) {
    throw 'struct shape change discarded the compatible owner identity'
}
if ([int]$structShapeOutput.memoryAddress -eq $structShapeStaleMemoryAddress) {
    throw 'struct shape change reused the stale structure address'
}
if (@($structShapeOutput.memberIds).Count -ne 2 -or
    [int]$structShapeOutput.memberIds[1] -ne $structStableMemberId -or
    [int]$structShapeOutput.memberIds[0] -eq $structStableMemberId) {
    throw 'struct shape change did not preserve only the declaration-identical member identity'
}
$structShapeOutputSourceMap = @(Get-Content -LiteralPath (Join-Path $structShapeProjection 'project\.native_source_map.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
$structShapeOutputClass = @($structShapeOutputSourceMap | Where-Object { 'ProbeStructValue' -in $_.methods.name })[0]
$structShapeOutputMethod = @($structShapeOutputClass.methods | Where-Object { $_.name -eq 'ProbeStructValue' })[0]
if ($structShapeOutputMethod.expressionData -ne $structSeedMethod.expressionData -or
    -not (Test-NativeInt32Value $structShapeOutputMethod.expressionData $structStableMemberId)) {
    throw 'struct shape change rebuilt or detached an exact method payload for a stable member'
}
$structShapeProjectionText = [IO.File]::ReadAllText((Join-Path $structShapeProjection 'src\StructProbe.txt'))
if (-not $structShapeProjectionText.Contains('item.Stable') -or
    $structShapeProjectionText.Contains('_StructMem_')) {
    throw 'struct shape change degraded the retained member name'
}
$structShapeVerifiedRoot = Join-Path $OutputRoot 'struct-shape-change-verified'
Invoke-Packager @('verify-roundtrip', $structShapeCandidate, $structShapeVerifiedRoot, (Join-Path $OutputRoot 'struct-shape-change-verified.e'))
$structShapeVerifiedText = [IO.File]::ReadAllText((Join-Path $structShapeVerifiedRoot 'roundtrip_unpacked\src\StructProbe.txt'))
if (-not $structShapeVerifiedText.Contains('item.Stable') -or
    $structShapeVerifiedText.Contains('_StructMem_')) {
    throw 'struct shape member identity is not stable across the second roundtrip'
}

$kindSplitMethod.expressionData = $injectedSplitExpression
$kindSplitMethod.variableReference = $injectedSplitVariableReference
$kindCrossMethod.methodReference = $injectedCrossMethodReference
Write-EText $kindNativeMapPath (($kindNativeMap | ConvertTo-Json -Depth 20) + "`r`n")
$kindStaticText = $kindText.Replace('.程序集 CategoryProbe,', '.程序集 CategoryProbe').Replace('#ProbeNativeConstant', "#$rawProjectConstantAlias")
Write-EText (Join-Path $kindProjection 'src\ProbeGroup\CategoryProbe.txt') $kindStaticText
$staticCandidate = Join-Path $OutputRoot 'kind-static.e'
$staticProjection = Join-Path $OutputRoot 'kind-static-unpacked'
Invoke-Packager @('pack', $kindProjection, $staticCandidate)
Invoke-Packager @('unpack', $staticCandidate, $staticProjection, '--main-only')
$staticSnapshot = Get-ProbeSnapshot $staticProjection
Assert-ProbeOrder $staticProjection
if (($staticSnapshot.classId -band 0xFF000000) -ne 0x09000000 -or $staticSnapshot.baseClass -ne 0) { throw 'class to assembly conversion failed' }
if ($staticSnapshot.methods[0].id -ne $classSnapshot.methods[0].id) { throw 'method identity changed' }
if ($staticSnapshot.methods[0].attr -ne 0x38) { throw 'class to assembly conversion reused stale method attr' }
if (-not (Test-Path -LiteralPath (Join-Path $staticProjection 'src\ProbeGroup\CategoryProbe.txt'))) { throw 'converted owner lost its folder' }
$staticNativeMapPath = Join-Path $staticProjection 'project\.native_source_map.json'
$staticNativeMap = @(Get-Content -LiteralPath $staticNativeMapPath -Raw -Encoding UTF8 | ConvertFrom-Json)
$staticNativeProbe = @($staticNativeMap | Where-Object { 'ProbeValue' -in $_.methods.name })[0]
$staticSplitMethod = @($staticNativeProbe.methods | Where-Object { $_.name -eq 'ProbeSplitValue' })[0]
$staticCrossMethod = @($staticNativeProbe.methods | Where-Object { $_.name -eq 'ProbeCrossPage' })[0]
$staticConstantMethod = @($staticNativeProbe.methods | Where-Object { $_.name -eq 'ProbeConstantValue' })[0]
if ($staticSplitMethod.expressionData -eq $injectedSplitExpression -or
    $staticSplitMethod.variableReference -eq $injectedSplitVariableReference -or
    $staticCrossMethod.methodReference -eq $injectedCrossMethodReference) {
    throw 'class to assembly conversion reused stale native method lines'
}
if ($staticSplitMethod.expressionData -ne $splitExpressionBaseline -or
    $staticSplitMethod.variableReference -ne $splitVariableReferenceBaseline -or
    $staticCrossMethod.methodReference -ne $crossMethodReferenceBaseline) {
    throw 'class to assembly semantic method rebuild is not deterministic'
}
if ($staticConstantMethod.expressionData -ne $constantExpressionBaseline -or
    $staticConstantMethod.constantReference -ne $constantReferenceBaseline) {
    throw 'native project constant alias did not retain its proven method reference'
}
$staticProbeText = [IO.File]::ReadAllText((Join-Path $staticProjection 'src\ProbeGroup\CategoryProbe.txt'))
if (-not $staticProbeText.Contains('分割文本 (“a|b”, “|”, )') -or
    -not $staticProbeText.Contains('返回 (pieces[1])') -or
    -not $staticProbeText.Contains('返回 (TailValue ())') -or
    -not $staticProbeText.Contains('返回 (#ProbeNativeConstant)')) {
    throw 'class to assembly semantic probes changed source text'
}
$unknownProjectConstantAlias = '_Const_0x{0:X}' -f (($rawProjectConstantId -band 0x00FFFFFF) -bxor 1)
Write-EText (Join-Path $staticProjection 'src\ProbeGroup\CategoryProbe.txt') $staticProbeText.Replace('#ProbeNativeConstant', "#$unknownProjectConstantAlias")
$rawProjectConstantMismatch = & $Packager pack $staticProjection (Join-Path $OutputRoot 'raw-project-constant-mismatch.e') 2>&1 | Out-String
if ($LASTEXITCODE -eq 0 -or -not $rawProjectConstantMismatch.Contains('constant_not_found')) {
    throw "raw project constant alias accepted an id absent from the method snapshot: $rawProjectConstantMismatch"
}
$staticNativeProbe.methods[0].attr = 0x08
Write-EText $staticNativeMapPath (($staticNativeMap | ConvertTo-Json -Depth 20) + "`r`n")
Write-EText (Join-Path $staticProjection 'src\ProbeGroup\CategoryProbe.txt') $kindText
$backCandidate = Join-Path $OutputRoot 'kind-class-again.e'
$backProjection = Join-Path $OutputRoot 'kind-class-again-unpacked'
Invoke-Packager @('pack', $staticProjection, $backCandidate)
Invoke-Packager @('unpack', $backCandidate, $backProjection, '--main-only')
$backSnapshot = Get-ProbeSnapshot $backProjection
if (($backSnapshot.classId -band 0xFF000000) -ne 0x49000000 -or $backSnapshot.baseClass -ne -1) { throw 'assembly to class conversion failed' }
if ($backSnapshot.methods[0].attr -ne 0x38) { throw 'assembly to class conversion reused stale method attr' }
$kindVerifiedRoot = Join-Path $OutputRoot 'kind-verified'
Invoke-Packager @('verify-roundtrip', $staticCandidate, $kindVerifiedRoot, (Join-Path $OutputRoot 'kind-verified.e'))
$verifiedStaticSnapshot = Get-ProbeSnapshot (Join-Path $kindVerifiedRoot 'original_unpacked')
$verifiedRoundtripSnapshot = Get-ProbeSnapshot (Join-Path $kindVerifiedRoot 'roundtrip_unpacked')
foreach ($methodName in @('ProbeSplitValue', 'ProbeCrossPage', 'ProbeConstantValue')) {
    $firstMethod = @($verifiedStaticSnapshot.methods | Where-Object { $_.name -eq $methodName })[0]
    $secondMethod = @($verifiedRoundtripSnapshot.methods | Where-Object { $_.name -eq $methodName })[0]
    if ($firstMethod.expressionData -ne $secondMethod.expressionData -or
        $firstMethod.methodReference -ne $secondMethod.methodReference -or
        $firstMethod.variableReference -ne $secondMethod.variableReference -or
        $firstMethod.constantReference -ne $secondMethod.constantReference) {
        throw "category conversion semantic probe is not stable: $methodName"
    }
}

# Raw support-library member aliases retain their native library/command identity.
# The receiver type must still belong to the same support library.
$rawSupportWorkspace = Join-Path $OutputRoot 'raw-support-workspace'
Invoke-Packager @('unpack', $consoleTemplate, $rawSupportWorkspace, '--main-only')
$rawSupportTextPath = Join-Path $rawSupportWorkspace 'project\mock-raw-support.txt'
Write-EText $rawSupportTextPath @'
[命令]
.命令 Placeholder, 分类=成员命令
[数据类型]
.数据类型 MockRawType
'@
$rawSupportModulePath = Join-Path $rawSupportWorkspace 'project\.module.json'
$rawSupportModule = Get-Content -LiteralPath $rawSupportModulePath -Raw -Encoding UTF8 | ConvertFrom-Json
$rawSupportModule.dependencies = @($rawSupportModule.dependencies) + @([pscustomobject]@{
    fileName = 'mockraw'
    guid = '00000000000000000000000000000001'
    kind = 'elib'
    localWorkspace = 'project\mock-raw-support.txt'
    name = 'Mock raw support library'
    path = ''
    reExport = $false
    versionText = '1.0'
})
Write-EText $rawSupportModulePath (($rawSupportModule | ConvertTo-Json -Depth 20) + "`r`n")
$rawSupportSource = Join-Path $rawSupportWorkspace 'src\RawSupportAliasProbe.txt'
$rawSupportPositiveText = @'
.版本 2

.程序集 RawSupportAliasProbe

.子程序 ProbeRawMember
.局部变量 target, MockRawType

target._Lib1Cmd0 ()
'@
Write-EText $rawSupportSource $rawSupportPositiveText
Invoke-Packager @('pack', $rawSupportWorkspace, (Join-Path $OutputRoot 'raw-support-positive.e'))
Write-EText $rawSupportSource $rawSupportPositiveText.Replace('._Lib1Cmd0', '._Lib0Cmd0')
$rawMismatchOutput = & $Packager pack $rawSupportWorkspace (Join-Path $OutputRoot 'raw-support-mismatch.e') 2>&1 | Out-String
if ($LASTEXITCODE -eq 0 -or -not $rawMismatchOutput.Contains('object_method_not_found')) {
    throw "raw support member alias accepted a mismatched owner library: $rawMismatchOutput"
}

$windowXml = Get-ChildItem -LiteralPath (Join-Path $windowWorkspace 'src') -Filter '*.xml' -File | Select-Object -First 1
$windowName = ([xml][IO.File]::ReadAllText($windowXml.FullName)).窗口.名称
$windowProgramPath = Join-Path $windowWorkspace "src\窗口程序集_$windowName.txt"
Write-EText $windowProgramPath ".版本 2`r`n`r`n.程序集 窗口程序集_$windowName`r`n`r`n.子程序 ProbeQualifiedWindowHandle, 整数型`r`n返回 ($windowName.取窗口句柄 ())`r`n`r`n.子程序 ProbeBareWindowHandle, 整数型`r`n返回 (取窗口句柄 ())`r`n"
$windowCallCandidate = Join-Path $OutputRoot 'window-method.e'
Invoke-Packager @('pack', $windowWorkspace, $windowCallCandidate)
$windowVerifiedRoot = Join-Path $OutputRoot 'window-method-verified'
Invoke-Packager @('verify-roundtrip', $windowCallCandidate, $windowVerifiedRoot, (Join-Path $OutputRoot 'window-method-verified.e'))
$windowSnapshots = @(Get-Content -LiteralPath (Join-Path $windowVerifiedRoot 'original_unpacked\project\.native_source_map.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
$bareWindowMethod = @($windowSnapshots.methods | Where-Object { $_.name -eq 'ProbeBareWindowHandle' })[0]
if ($null -eq $bareWindowMethod) { throw 'bare window method snapshot missing' }
$bareExpression = [Convert]::FromBase64String($bareWindowMethod.expressionData)
$boundWindowCall = [byte[]]@(0x21, 0xD7, 0x00, 0x00, 0x00, 0x00, 0x00)
$hasBoundWindowCall = $false
for ($offset = 0; $offset -le $bareExpression.Length - $boundWindowCall.Length; $offset++) {
    $matches = $true
    for ($index = 0; $index -lt $boundWindowCall.Length; $index++) {
        if ($bareExpression[$offset + $index] -ne $boundWindowCall[$index]) {
            $matches = $false
            break
        }
    }
    if ($matches) {
        $hasBoundWindowCall = $true
        break
    }
}
if (-not $hasBoundWindowCall) { throw 'bare window support method was emitted as unbound source text' }

# Rebuilt window methods must retain sparse native form-control identities when
# the form XML is unchanged. Otherwise the expression decodes as _Control_0x...
# even though the named control still exists in the reused native resource section.
$controlWorkspace = Join-Path $OutputRoot 'window-control-workspace'
Invoke-Packager @('unpack', $windowFullTemplate, $controlWorkspace, '--main-only')
# The full fixture intentionally contains unresolved raw JsonReader object calls in
# an unrelated assembly. Keep this regression focused on rebuilding the window
# method and the reused form resource section.
$controlUnrelatedProgramPath = Join-Path $controlWorkspace 'src\程序集1.txt'
$controlUnrelatedProgramText = @"
.版本 2

.程序集 程序集1

.子程序 子程序1
"@
Write-EText $controlUnrelatedProgramPath $controlUnrelatedProgramText
$controlXml = Get-ChildItem -LiteralPath (Join-Path $controlWorkspace 'src') -Filter '*.xml' -File | Select-Object -First 1
$controlWindowName = ([xml][IO.File]::ReadAllText($controlXml.FullName)).窗口.名称
$controlProgramPath = Join-Path $controlWorkspace "src\窗口程序集$controlWindowName.txt"
$controlProgramText = @"
.版本 2
.支持库 JsonReader
.支持库 json

.程序集 窗口程序集$controlWindowName

.子程序 __启动窗口_创建完毕

标签1.标题 ＝ “initial”

.子程序 ProbeControlName

标签1.标题 ＝ “probe”
"@
Write-EText $controlProgramPath $controlProgramText

# Raw form handlers are accepted only when the preserved native form proves the
# exact handler id for this form element and event. The editable JSON projection
# is deliberately not sufficient evidence by itself.
$handlerMapPath = Join-Path $controlWorkspace 'project\.native_symbol_map.json'
$handlerMapText = [IO.File]::ReadAllText($handlerMapPath)
$handlerMap = $handlerMapText | ConvertFrom-Json
$handlerFormSnapshot = @($handlerMap.forms | Where-Object { $_.name -eq $controlWindowName })[0]
$handlerSelfSnapshot = @($handlerFormSnapshot.elements | Where-Object { $_.isFormSelf })[0]
$handlerEventSnapshot = @($handlerSelfSnapshot.events | Where-Object { $_.eventKey -eq 0 })[0]
if ($null -eq $handlerEventSnapshot) { throw 'native form handler evidence missing' }
$nativeHandlerId = [int]$handlerEventSnapshot.handlerId
if (($nativeHandlerId -band 0xFF000000) -ne 0x04000000) {
    throw ('native form handler evidence has wrong type: 0x{0:X8}' -f $nativeHandlerId)
}
$rawHandlerAlias = '_Sub_0x{0:X}' -f ($nativeHandlerId -band 0x00FFFFFF)
$controlXmlText = [IO.File]::ReadAllText($controlXml.FullName)
$handlerMatch = [regex]::Match($controlXmlText, '<窗口\.事件[^>]*处理器="([^"]+)"')
if (-not $handlerMatch.Success) { throw 'named window handler fixture missing' }
$namedHandler = $handlerMatch.Groups[1].Value
$rawHandlerPositive = Join-Path $OutputRoot 'raw-form-handler-positive.e'
$rawHandlerPositiveUnpacked = Join-Path $OutputRoot 'raw-form-handler-positive-unpacked'
$rawHandlerFailureEvidence = [Collections.Generic.List[object]]::new()
function Assert-PackFailure {
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Context
    )
    $failureOutput = & $Packager pack $Workspace $Candidate 2>&1 | Out-String
    $failureExitCode = $LASTEXITCODE
    if ($failureExitCode -eq 0 -or -not $failureOutput.Contains($Marker)) {
        throw "$Context`: $failureOutput"
    }
    $rawHandlerFailureEvidence.Add([pscustomobject]@{
        context = $Context
        expected_marker = $Marker
        exit_code = $failureExitCode
        output = $failureOutput.Trim()
    })
}

function Copy-TestWorkspace {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    New-Item -ItemType Directory -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
}

try {
    Write-EText $controlXml.FullName $controlXmlText.Replace($namedHandler, $rawHandlerAlias)
    Invoke-Packager @('pack', $controlWorkspace, $rawHandlerPositive)
    Invoke-Packager @('unpack', $rawHandlerPositive, $rawHandlerPositiveUnpacked, '--main-only')
    $rawHandlerProjection = [IO.File]::ReadAllText(
        (Join-Path $rawHandlerPositiveUnpacked "src\$controlWindowName.xml"))
    if (-not $rawHandlerProjection.Contains($namedHandler) -or
        $rawHandlerProjection.Contains($rawHandlerAlias)) {
        throw 'proven raw form handler did not restore the native method binding'
    }

    $unknownHandlerId = $nativeHandlerId -bxor 1
    $unknownHandlerAlias = '_Sub_0x{0:X}' -f ($unknownHandlerId -band 0x00FFFFFF)
    $handlerEventSnapshot.handlerId = $unknownHandlerId
    Write-EText $handlerMapPath (($handlerMap | ConvertTo-Json -Depth 20) + "`r`n")
    Write-EText $controlXml.FullName $controlXmlText.Replace($namedHandler, $unknownHandlerAlias)
    Assert-PackFailure `
        $controlWorkspace `
        (Join-Path $OutputRoot 'raw-form-handler-unknown.e') `
        'raw_form_handler_not_proven' `
        'raw form handler accepted an id absent from the native form snapshot'

    [IO.File]::WriteAllText($handlerMapPath, $handlerMapText, $utf8Bom)
    Write-EText $controlXml.FullName $controlXmlText.Replace($namedHandler, '_Sub_0xZZ')
    Assert-PackFailure `
        $controlWorkspace `
        (Join-Path $OutputRoot 'raw-form-handler-invalid.e') `
        'invalid_raw_form_handler' `
        'malformed raw form handler was not rejected explicitly'

    [xml]$crossElementDocument = $controlXmlText
    $crossElementRoot = $crossElementDocument.DocumentElement
    $rootEventNode = @($crossElementRoot.ChildNodes | Where-Object {
        $_.NodeType -eq [Xml.XmlNodeType]::Element -and $_.Name -eq '窗口.事件'
    })[0]
    $otherElementNode = @($crossElementRoot.ChildNodes | Where-Object {
        $_.NodeType -eq [Xml.XmlNodeType]::Element -and $_.Name -notlike '*.*'
    })[0]
    if ($null -eq $rootEventNode -or $null -eq $otherElementNode) {
        throw 'cross-element raw handler fixture missing'
    }
    $null = $crossElementRoot.RemoveChild($rootEventNode)
    $crossElementEvent = $crossElementDocument.CreateElement($otherElementNode.Name + '.事件')
    $crossElementEvent.SetAttribute('索引', '0')
    $crossElementEvent.SetAttribute('名称', 'raw-handler-proof-probe')
    $crossElementEvent.SetAttribute('处理器', $rawHandlerAlias)
    $null = $otherElementNode.AppendChild($crossElementEvent)
    Write-EText $controlXml.FullName $crossElementDocument.OuterXml
    Assert-PackFailure `
        $controlWorkspace `
        (Join-Path $OutputRoot 'raw-form-handler-cross-element.e') `
        'raw_form_handler_not_proven' `
        'raw form handler evidence leaked across elements'

    [xml]$wrongEventDocument = $controlXmlText
    $wrongEventNode = @($wrongEventDocument.DocumentElement.ChildNodes | Where-Object {
        $_.NodeType -eq [Xml.XmlNodeType]::Element -and $_.Name -eq '窗口.事件'
    })[0]
    $wrongEventNode.SetAttribute('索引', '1')
    $wrongEventNode.SetAttribute('处理器', $rawHandlerAlias)
    Write-EText $controlXml.FullName $wrongEventDocument.OuterXml
    Assert-PackFailure `
        $controlWorkspace `
        (Join-Path $OutputRoot 'raw-form-handler-wrong-event.e') `
        'raw_form_handler_not_proven' `
        'raw form handler evidence leaked across event keys'

    [xml]$conflictingEventDocument = $controlXmlText
    $conflictingEventRoot = $conflictingEventDocument.DocumentElement
    $conflictingEventFirst = @($conflictingEventRoot.ChildNodes | Where-Object {
        $_.NodeType -eq [Xml.XmlNodeType]::Element -and $_.Name -eq '窗口.事件'
    })[0]
    $conflictingEventFirst.SetAttribute('处理器', $rawHandlerAlias)
    $conflictingEventSecond = $conflictingEventFirst.CloneNode($true)
    $conflictingEventSecond.SetAttribute('处理器', "窗口程序集${controlWindowName}::ProbeControlName")
    $null = $conflictingEventRoot.InsertAfter($conflictingEventSecond, $conflictingEventFirst)
    Write-EText $controlXml.FullName $conflictingEventDocument.OuterXml
    Assert-PackFailure `
        $controlWorkspace `
        (Join-Path $OutputRoot 'raw-form-handler-conflict.e') `
        'conflicting_form_event_handlers' `
        'different handlers for one form event were silently collapsed'

    $legacyHandlerMap = $handlerMapText | ConvertFrom-Json
    $legacyHandlerMap.PSObject.Properties.Remove('forms')
    Write-EText $handlerMapPath (($legacyHandlerMap | ConvertTo-Json -Depth 20) + "`r`n")
    Write-EText $controlXml.FullName $controlXmlText.Replace($namedHandler, $rawHandlerAlias)
    $legacyMapCandidate = Join-Path $OutputRoot 'raw-form-handler-legacy-map.e'
    $legacyMapUnpacked = Join-Path $OutputRoot 'raw-form-handler-legacy-map-unpacked'
    Invoke-Packager @('pack', $controlWorkspace, $legacyMapCandidate)
    Invoke-Packager @('unpack', $legacyMapCandidate, $legacyMapUnpacked, '--main-only')
    $legacyMapProjection = [IO.File]::ReadAllText(
        (Join-Path $legacyMapUnpacked "src\$controlWindowName.xml"))
    if (-not $legacyMapProjection.Contains($namedHandler) -or
        $legacyMapProjection.Contains($rawHandlerAlias)) {
        throw 'native source bytes did not authorize a proven raw handler with an old symbol map'
    }
}
finally {
    [IO.File]::WriteAllText($handlerMapPath, $handlerMapText, $utf8Bom)
    [IO.File]::WriteAllText($controlXml.FullName, $controlXmlText, $utf8Bom)
}

# Build an independent native fixture whose ordinary control owns an event. It
# proves that a raw id remains bound to the same resolved control data type and
# that duplicate native element identities never authorize a first-match guess.
$controlHandlerSeedWorkspace = Join-Path $OutputRoot 'raw-control-handler-seed-workspace'
Copy-TestWorkspace $controlWorkspace $controlHandlerSeedWorkspace
$controlHandlerSeedXmlPath = Join-Path $controlHandlerSeedWorkspace "src\$controlWindowName.xml"
[xml]$controlHandlerSeedDocument = $controlXmlText
$controlHandlerSeedRoot = $controlHandlerSeedDocument.DocumentElement
$controlHandlerSeedNode = @($controlHandlerSeedRoot.ChildNodes | Where-Object {
    $_.NodeType -eq [Xml.XmlNodeType]::Element -and $_.Name -notlike '*.*'
})[0]
if ($null -eq $controlHandlerSeedNode) { throw 'control handler seed element missing' }
$controlHandlerSeedEvent = $controlHandlerSeedDocument.CreateElement($controlHandlerSeedNode.Name + '.事件')
$controlHandlerSeedEvent.SetAttribute('索引', '0')
$controlHandlerSeedEvent.SetAttribute('名称', 'raw-handler-control-probe')
$controlHandlerSeedEvent.SetAttribute('处理器', $namedHandler)
$null = $controlHandlerSeedNode.AppendChild($controlHandlerSeedEvent)
Write-EText $controlHandlerSeedXmlPath $controlHandlerSeedDocument.OuterXml
$controlHandlerSeedCandidate = Join-Path $OutputRoot 'raw-control-handler-seed.e'
$controlHandlerWorkspace = Join-Path $OutputRoot 'raw-control-handler-workspace'
Invoke-Packager @('pack', $controlHandlerSeedWorkspace, $controlHandlerSeedCandidate)
Invoke-Packager @('unpack', $controlHandlerSeedCandidate, $controlHandlerWorkspace, '--main-only')
$controlHandlerMap = Get-Content -LiteralPath (Join-Path $controlHandlerWorkspace 'project\.native_symbol_map.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$controlHandlerSnapshot = @($controlHandlerMap.forms[0].elements | Where-Object {
    -not $_.isFormSelf -and -not $_.isMenu -and @($_.events).Count -gt 0
})[0]
if ($null -eq $controlHandlerSnapshot) { throw 'native control handler evidence missing' }
$controlHandlerId = [int]$controlHandlerSnapshot.events[0].handlerId
$controlRawHandlerAlias = '_Sub_0x{0:X}' -f ($controlHandlerId -band 0x00FFFFFF)
$controlHandlerXmlPath = Join-Path $controlHandlerWorkspace "src\$controlWindowName.xml"
$controlHandlerXmlText = [IO.File]::ReadAllText($controlHandlerXmlPath)
$controlHandlerNamedMatch = [regex]::Match(
    $controlHandlerXmlText,
    '<([^\s.>]+)[^>]*名称="' + [regex]::Escape([string]$controlHandlerSnapshot.name) + '"[^>]*>[\s\S]*?<\1\.事件[^>]*处理器="([^"]+)"')
if (-not $controlHandlerNamedMatch.Success) { throw 'control handler projection missing' }
$controlHandlerTag = $controlHandlerNamedMatch.Groups[1].Value
$controlHandlerName = $controlHandlerNamedMatch.Groups[2].Value
$rawControlHandlerPositive = Join-Path $OutputRoot 'raw-control-handler-positive.e'
Write-EText $controlHandlerXmlPath $controlHandlerXmlText.Replace($controlHandlerName, $controlRawHandlerAlias)
Invoke-Packager @('pack', $controlHandlerWorkspace, $rawControlHandlerPositive)

$replacementControlTag = if ($controlHandlerTag -eq '按钮') { '标签' } else { '按钮' }
$changedTypeXml = $controlHandlerXmlText
$changedTypeXml = $changedTypeXml.Replace("<$controlHandlerTag ", "<$replacementControlTag ")
$changedTypeXml = $changedTypeXml.Replace("<$controlHandlerTag.", "<$replacementControlTag.")
$changedTypeXml = $changedTypeXml.Replace("</$controlHandlerTag>", "</$replacementControlTag>")
$changedTypeXml = $changedTypeXml.Replace($controlHandlerName, $controlRawHandlerAlias)
Write-EText $controlHandlerXmlPath $changedTypeXml
Assert-PackFailure `
    $controlHandlerWorkspace `
    (Join-Path $OutputRoot 'raw-control-handler-type-changed.e') `
    'raw_form_handler_not_proven' `
    'raw control handler survived a control type change'

$duplicateSeedWorkspace = Join-Path $OutputRoot 'raw-control-handler-duplicate-seed-workspace'
Copy-TestWorkspace $controlWorkspace $duplicateSeedWorkspace
$duplicateSeedXmlPath = Join-Path $duplicateSeedWorkspace "src\$controlWindowName.xml"
[xml]$duplicateSeedDocument = $controlHandlerSeedDocument.OuterXml
$duplicateSeedRoot = $duplicateSeedDocument.DocumentElement
$duplicateSeedNode = @($duplicateSeedRoot.ChildNodes | Where-Object {
    $_.NodeType -eq [Xml.XmlNodeType]::Element -and $_.Name -notlike '*.*'
})[0]
$null = $duplicateSeedRoot.AppendChild($duplicateSeedNode.CloneNode($true))
Write-EText $duplicateSeedXmlPath $duplicateSeedDocument.OuterXml
$duplicateSeedCandidate = Join-Path $OutputRoot 'raw-control-handler-duplicate-seed.e'
$duplicateWorkspace = Join-Path $OutputRoot 'raw-control-handler-duplicate-workspace'
Invoke-Packager @('pack', $duplicateSeedWorkspace, $duplicateSeedCandidate)
Invoke-Packager @('unpack', $duplicateSeedCandidate, $duplicateWorkspace, '--main-only')
$duplicateMap = Get-Content -LiteralPath (Join-Path $duplicateWorkspace 'project\.native_symbol_map.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$duplicateMatches = @($duplicateMap.forms[0].elements | Where-Object {
    -not $_.isFormSelf -and
    -not $_.isMenu -and
    $_.dataType -eq $controlHandlerSnapshot.dataType -and
    $_.name -eq $controlHandlerSnapshot.name
})
if ($duplicateMatches.Count -ne 2) { throw 'duplicate native control fixture is not ambiguous' }
$duplicateXmlPath = Join-Path $duplicateWorkspace "src\$controlWindowName.xml"
$duplicateXmlText = [IO.File]::ReadAllText($duplicateXmlPath).Replace($controlHandlerName, $controlRawHandlerAlias)
Write-EText $duplicateXmlPath $duplicateXmlText
Assert-PackFailure `
    $duplicateWorkspace `
    (Join-Path $OutputRoot 'raw-control-handler-duplicate.e') `
    'raw_form_handler_not_proven' `
    'ambiguous duplicate native controls authorized a raw handler'

# A handler proven on one form must not authorize the same id on another form.
$crossFormSeedWorkspace = Join-Path $OutputRoot 'raw-handler-cross-form-seed-workspace'
Copy-TestWorkspace $controlWorkspace $crossFormSeedWorkspace
$crossFormMetaPath = Join-Path $crossFormSeedWorkspace 'project\_meta.json'
$crossFormMeta = Get-Content -LiteralPath $crossFormMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
$secondFormName = 'RawHandlerSecond'
$secondFormKey = 'form:RawHandlerSecond'
$crossFormMeta.formFiles = @($crossFormMeta.formFiles) + @([pscustomobject]@{
    key = $secondFormKey
    logicalName = $secondFormName
    relativePath = "src/$secondFormName.xml"
})
$crossFormMeta.rootChildKeys = @($crossFormMeta.rootChildKeys) + $secondFormKey
Write-EText $crossFormMetaPath (($crossFormMeta | ConvertTo-Json -Depth 20) + "`r`n")
[xml]$secondFormDocument = $controlXmlText
$secondFormDocument.DocumentElement.SetAttribute('名称', $secondFormName)
@($secondFormDocument.DocumentElement.ChildNodes) | ForEach-Object {
    $null = $secondFormDocument.DocumentElement.RemoveChild($_)
}
$secondFormSeedXmlPath = Join-Path $crossFormSeedWorkspace "src\$secondFormName.xml"
Write-EText $secondFormSeedXmlPath $secondFormDocument.OuterXml
$crossFormSeedCandidate = Join-Path $OutputRoot 'raw-handler-cross-form-seed.e'
$crossFormWorkspace = Join-Path $OutputRoot 'raw-handler-cross-form-workspace'
Invoke-Packager @('pack', $crossFormSeedWorkspace, $crossFormSeedCandidate)
Invoke-Packager @('unpack', $crossFormSeedCandidate, $crossFormWorkspace, '--main-only')
$crossFormMap = Get-Content -LiteralPath (Join-Path $crossFormWorkspace 'project\.native_symbol_map.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$secondFormSnapshot = @($crossFormMap.forms | Where-Object { $_.name -eq $secondFormName })[0]
if ($null -eq $secondFormSnapshot -or @($secondFormSnapshot.elements[0].events).Count -ne 0) {
    throw 'second native form fixture unexpectedly owns handler evidence'
}
$secondFormXmlPath = Join-Path $crossFormWorkspace "src\$secondFormName.xml"
[xml]$crossFormDocument = [IO.File]::ReadAllText($secondFormXmlPath)
$crossFormEvent = $crossFormDocument.CreateElement('窗口.事件')
$crossFormEvent.SetAttribute('索引', '0')
$crossFormEvent.SetAttribute('名称', 'raw-handler-cross-form-probe')
$crossFormEvent.SetAttribute('处理器', $rawHandlerAlias)
$null = $crossFormDocument.DocumentElement.AppendChild($crossFormEvent)
Write-EText $secondFormXmlPath $crossFormDocument.OuterXml
Assert-PackFailure `
    $crossFormWorkspace `
    (Join-Path $OutputRoot 'raw-form-handler-cross-form.e') `
    'raw_form_handler_not_proven' `
    'raw form handler evidence leaked across forms'

# A menu may project duplicate event nodes, but distinct non-zero handlers are
# ambiguous and must fail instead of silently keeping the first one.
$menuSeedWorkspace = Join-Path $OutputRoot 'raw-menu-handler-seed-workspace'
Copy-TestWorkspace $controlWorkspace $menuSeedWorkspace
$menuSeedXmlPath = Join-Path $menuSeedWorkspace "src\$controlWindowName.xml"
[xml]$menuSeedDocument = $controlXmlText
$menuContainer = $menuSeedDocument.CreateElement('窗口.菜单')
$menuNode = $menuSeedDocument.CreateElement('菜单')
$menuNode.SetAttribute('名称', 'RawHandlerMenu')
$menuNode.SetAttribute('标题', 'Raw handler menu')
$menuEventNode = $menuSeedDocument.CreateElement('菜单.事件')
$menuEventNode.SetAttribute('名称', '单击')
$menuEventNode.SetAttribute('处理器', $namedHandler)
$null = $menuNode.AppendChild($menuEventNode)
$null = $menuContainer.AppendChild($menuNode)
$null = $menuSeedDocument.DocumentElement.AppendChild($menuContainer)
Write-EText $menuSeedXmlPath $menuSeedDocument.OuterXml
$menuSeedCandidate = Join-Path $OutputRoot 'raw-menu-handler-seed.e'
$menuWorkspace = Join-Path $OutputRoot 'raw-menu-handler-workspace'
Invoke-Packager @('pack', $menuSeedWorkspace, $menuSeedCandidate)
Invoke-Packager @('unpack', $menuSeedCandidate, $menuWorkspace, '--main-only')
$menuMap = Get-Content -LiteralPath (Join-Path $menuWorkspace 'project\.native_symbol_map.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$menuSnapshot = @($menuMap.forms[0].elements | Where-Object { $_.isMenu -and $_.name -eq 'RawHandlerMenu' })[0]
if ($null -eq $menuSnapshot -or ([int]$menuSnapshot.clickEvent -band 0xFF000000) -ne 0x04000000) {
    throw 'native menu handler evidence missing'
}
$menuRawHandlerAlias = '_Sub_0x{0:X}' -f ([int]$menuSnapshot.clickEvent -band 0x00FFFFFF)
$menuXmlPath = Join-Path $menuWorkspace "src\$controlWindowName.xml"
[xml]$menuConflictDocument = [IO.File]::ReadAllText($menuXmlPath)
$menuConflictNode = $menuConflictDocument.SelectSingleNode('//菜单')
$menuConflictFirstEvent = $menuConflictNode.SelectSingleNode('菜单.事件')
$menuConflictFirstEvent.SetAttribute('处理器', $menuRawHandlerAlias)
$menuConflictSecondEvent = $menuConflictFirstEvent.CloneNode($true)
$menuConflictSecondEvent.SetAttribute('处理器', "窗口程序集${controlWindowName}::ProbeControlName")
$null = $menuConflictNode.AppendChild($menuConflictSecondEvent)
Write-EText $menuXmlPath $menuConflictDocument.OuterXml
Assert-PackFailure `
    $menuWorkspace `
    (Join-Path $OutputRoot 'raw-menu-handler-conflict.e') `
    'conflicting_menu_handlers' `
    'different handlers on one menu were silently collapsed'

$controlXmlHash = (Get-FileHash -LiteralPath $controlXml.FullName -Algorithm SHA256).Hash
$controlCandidate1 = Join-Path $OutputRoot 'window-control-1.e'
$controlUnpacked1 = Join-Path $OutputRoot 'window-control-unpacked-1'
$controlCandidate2 = Join-Path $OutputRoot 'window-control-2.e'
$controlUnpacked2 = Join-Path $OutputRoot 'window-control-unpacked-2'
Invoke-Packager @('pack', $controlWorkspace, $controlCandidate1)
Invoke-Packager @('unpack', $controlCandidate1, $controlUnpacked1, '--main-only')
Invoke-Packager @('pack', $controlUnpacked1, $controlCandidate2)
Invoke-Packager @('unpack', $controlCandidate2, $controlUnpacked2, '--main-only')

$controlXml1 = Join-Path $controlUnpacked1 "src\$controlWindowName.xml"
$controlXml2 = Join-Path $controlUnpacked2 "src\$controlWindowName.xml"
foreach ($roundtripXml in @($controlXml1, $controlXml2)) {
    if ((Get-FileHash -LiteralPath $roundtripXml -Algorithm SHA256).Hash -ne $controlXmlHash) {
        throw 'unchanged form XML changed while rebuilding a window method'
    }
}
$controlSource1 = Join-Path $controlUnpacked1 "src\窗口程序集$controlWindowName.txt"
$controlSource2 = Join-Path $controlUnpacked2 "src\窗口程序集$controlWindowName.txt"
$controlProjection = [IO.File]::ReadAllText($controlSource2)
if (($controlProjection -split '标签1\.标题').Count - 1 -ne 2 -or
    $controlProjection -match '_Control_0x') {
    throw "form control identity was not preserved: $controlProjection"
}
if ((Get-FileHash -LiteralPath $controlSource1 -Algorithm SHA256).Hash -ne
    (Get-FileHash -LiteralPath $controlSource2 -Algorithm SHA256).Hash) {
    throw 'form control source projection is not stable after the second roundtrip'
}

# Cross-form control calls must rebuild against the current form/control identity.
# A design-time control id can differ from the loaded support library's expression
# owner type, so member properties must use the canonical type for that project slot.
$crossControlWorkspace = Join-Path $OutputRoot 'cross-form-control-workspace'
Copy-TestWorkspace $controlWorkspace $crossControlWorkspace
$crossControlModulePath = Join-Path $crossControlWorkspace 'project\.module.json'
$crossControlModule = Get-Content -LiteralPath $crossControlModulePath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not @($crossControlModule.dependencies | Where-Object { $_.kind -eq 'elib' -and $_.fileName -eq 'iext' })) {
	$existingCrossControlDependencies = @($crossControlModule.dependencies)
	if ($existingCrossControlDependencies.Count -eq 0 -or
		$existingCrossControlDependencies[0].kind -ne 'elib' -or
		$existingCrossControlDependencies[0].fileName -ne 'krnln') {
		throw 'cross-form fixture core dependency must remain first'
	}
	$iextDependency = [pscustomobject]@{
        fileName = 'iext'
        guid = '27bb20fdd3e145e4bee3db39ddd6e64c'
        kind = 'elib'
        name = '扩展界面支持库一'
        path = ''
        reExport = $false
        versionText = '2.0'
	}
	$crossControlModule.dependencies = @($existingCrossControlDependencies[0], $iextDependency) +
		@($existingCrossControlDependencies | Select-Object -Skip 1)
}
Write-EText $crossControlModulePath (($crossControlModule | ConvertTo-Json -Depth 20) + "`r`n")
$crossControlLibraries = @($crossControlModule.dependencies | Where-Object { $_.kind -eq 'elib' })
$iextLibraryId = -1
for ($index = 0; $index -lt $crossControlLibraries.Count; $index++) {
    if ($crossControlLibraries[$index].fileName -eq 'iext') {
        $iextLibraryId = $index
        break
    }
}
if ($iextLibraryId -lt 0) { throw 'cross-form fixture iext dependency missing' }
$iextControlTypeId = (($iextLibraryId + 1) -shl 16) -bor 4
if ($iextControlTypeId -ne 0x00020004) {
	throw ('cross-form fixture iext control type mismatch: 0x{0:X8}' -f $iextControlTypeId)
}

$crossControlStartXmlPath = Join-Path $crossControlWorkspace "src\$controlWindowName.xml"
[xml]$crossControlStartXml = [IO.File]::ReadAllText($crossControlStartXmlPath)
$crossControlNode = $crossControlStartXml.CreateElement('超级列表框')
$crossControlNode.SetAttribute('名称', '超级列表框1')
$crossControlNode.SetAttribute('左边', '8')
$crossControlNode.SetAttribute('顶边', '176')
$crossControlNode.SetAttribute('宽度', '248')
$crossControlNode.SetAttribute('高度', '48')
$crossControlNode.SetAttribute('鼠标指针', 'AAAAAA==')
$crossControlNode.SetAttribute('可停留焦点', '真')
$crossControlNode.SetAttribute('扩展属性数据', '')
$null = $crossControlStartXml.DocumentElement.AppendChild($crossControlNode)
Write-EText $crossControlStartXmlPath $crossControlStartXml.OuterXml

$crossControlStartProgramPath = Join-Path $crossControlWorkspace "src\窗口程序集$controlWindowName.txt"
$crossControlStartProgram = @"
.版本 2
.支持库 iext

.程序集 窗口程序集$controlWindowName

.子程序 __启动窗口_创建完毕

超级列表框1.置标题 (0, 0, “probe”)

"@
Write-EText $crossControlStartProgramPath $crossControlStartProgram

$sharedOwnerClassName = 'SharedOwnerProbe'
$sharedOwnerSourcePath = Join-Path $crossControlWorkspace "src\$sharedOwnerClassName.txt"
$sharedOwnerSourceText = @'
.版本 2

.程序集 SharedOwnerProbe, , 公开

.子程序 ProbeSharedName, 整数型, 公开

返回 (101)
'@
Write-EText $sharedOwnerSourcePath $sharedOwnerSourceText

$crossControlFormName = 'CrossFormProbe'
$crossControlClassName = '窗口程序集_CrossFormProbe'
$crossControlFormPath = Join-Path $crossControlWorkspace "src\$crossControlFormName.xml"
$crossControlClassPath = Join-Path $crossControlWorkspace "src\$crossControlClassName.txt"
$crossControlFormText = '<?xml version="1.0" encoding="UTF-8"?><窗口 名称="CrossFormProbe" 左边="10" 顶边="10" 宽度="120" 高度="80" 鼠标指针="AAAAAA==" 可停留焦点="假" 扩展属性数据="" />'
Write-EText $crossControlFormPath $crossControlFormText
$crossControlClassText = @'
.版本 2
.支持库 iext

.程序集 窗口程序集_CrossFormProbe

.子程序 ProbeCrossFormControl, 文本型

返回 (_启动窗口.超级列表框1.取标题 (_启动窗口.超级列表框1.现行选中项, 1))

.子程序 ProbeCrossFormOwner, 整数型

.如果真 (真)
    返回 (_启动窗口.左边 ＋ CrossFormProbe.宽度)
.如果真结束
返回 (0)

.子程序 ProbeSharedName, 整数型, 公开

返回 (202)

.子程序 ProbeLocalSharedCall, 整数型

返回 (ProbeSharedName ())

.子程序 ProbeQualifiedSharedCall
.局部变量 owner, SharedOwnerProbe

owner.ProbeSharedName ()

.子程序 ProbeBooleanTrue, 逻辑型

返回 (真)

.子程序 ProbeBooleanFalse, 逻辑型

返回 (假)

.子程序 ProbeAdditiveAssociativity, 整数型

返回 (10 ＋ 3 － 2)

.子程序 ProbeQuotedConcatenation, 文本型
.参数 itemIndex, 整数型

返回 (“第：” ＋ 到文本 (itemIndex) ＋ “条代理API异常请检查”)


.子程序 ProbeMultiplicativeAssociativity, 双精度小数型

返回 (24 × 3 ÷ 2)
'@
Write-EText $crossControlClassPath $crossControlClassText

$crossControlMetaPath = Join-Path $crossControlWorkspace 'project\_meta.json'
$crossControlMeta = Get-Content -LiteralPath $crossControlMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
$crossControlMeta.formFiles = @($crossControlMeta.formFiles) + @([pscustomobject]@{
    key = "form:$crossControlFormName"
    logicalName = $crossControlFormName
    relativePath = "src/$crossControlFormName.xml"
})
$crossControlMeta.sourceFiles = @($crossControlMeta.sourceFiles) + @([pscustomobject]@{
    key = "class:$crossControlClassName"
    logicalName = $crossControlClassName
    relativePath = "src/$crossControlClassName.txt"
})
$crossControlMeta.windowBindings = @($crossControlMeta.windowBindings) + @([pscustomobject]@{
    className = $crossControlClassName
    formName = $crossControlFormName
})
$crossControlMeta.rootChildKeys = @($crossControlMeta.rootChildKeys) + @(
    "class:$crossControlClassName",
    "form:$crossControlFormName"
)
Write-EText $crossControlMetaPath (($crossControlMeta | ConvertTo-Json -Depth 20) + "`r`n")

$crossControlCandidate1 = Join-Path $OutputRoot 'cross-form-control-1.e'
$crossControlUnpacked1 = Join-Path $OutputRoot 'cross-form-control-unpacked-1'
$crossControlCandidate2 = Join-Path $OutputRoot 'cross-form-control-2.e'
$crossControlUnpacked2 = Join-Path $OutputRoot 'cross-form-control-unpacked-2'
Invoke-Packager @('pack', $crossControlWorkspace, $crossControlCandidate1)
Invoke-Packager @('unpack', $crossControlCandidate1, $crossControlUnpacked1, '--main-only')
Invoke-Packager @('compare-bundle', $crossControlCandidate1, $crossControlUnpacked1)
$crossControlStaleOwnerWorkspace = Join-Path $OutputRoot 'cross-form-control-stale-owner-workspace'
Copy-TestWorkspace $crossControlUnpacked1 $crossControlStaleOwnerWorkspace
$staleOwnerSymbolMap = Get-Content -LiteralPath (Join-Path $crossControlStaleOwnerWorkspace 'project\.native_symbol_map.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$staleOwnerFormIds = @(
	[int](@($staleOwnerSymbolMap.forms | Where-Object { $_.name -eq $controlWindowName })[0].id),
	[int](@($staleOwnerSymbolMap.forms | Where-Object { $_.name -eq $crossControlFormName })[0].id)
)
$staleOwnerNativeMapPath = Join-Path $crossControlStaleOwnerWorkspace 'project\.native_source_map.json'
$staleOwnerNativeMap = @(Get-Content -LiteralPath $staleOwnerNativeMapPath -Raw -Encoding UTF8 | ConvertFrom-Json)
$staleOwnerMethod = @($staleOwnerNativeMap.methods | Where-Object { $_.name -eq 'ProbeCrossFormOwner' })[0]
if ($null -eq $staleOwnerMethod) { throw 'cross-form stale-owner fixture method missing' }
$staleOwnerExpression = [Convert]::FromBase64String($staleOwnerMethod.expressionData)
$staleOwnerRewriteCount = 0
for ($offset = 0; $offset + 8 -lt $staleOwnerExpression.Length; $offset++) {
	if ($staleOwnerExpression[$offset] -ne 0x39) { continue }
	$ownerTypeId = [BitConverter]::ToInt32($staleOwnerExpression, $offset + 5)
	if ($staleOwnerFormIds -contains $ownerTypeId) {
		[BitConverter]::GetBytes([int]0x00010001).CopyTo($staleOwnerExpression, $offset + 5)
		$staleOwnerRewriteCount++
	}
}
if ($staleOwnerRewriteCount -ne 2) {
	throw "cross-form stale-owner fixture rewrite mismatch: $staleOwnerRewriteCount"
}
$staleOwnerTrueRewriteCount = 0
for ($offset = 0; $offset + 2 -lt $staleOwnerExpression.Length; $offset++) {
	if ($staleOwnerExpression[$offset] -eq 0x18 -and
		$staleOwnerExpression[$offset + 1] -eq 0xFF -and
		$staleOwnerExpression[$offset + 2] -eq 0xFF) {
		$staleOwnerExpression[$offset + 1] = 0x01
		$staleOwnerExpression[$offset + 2] = 0x00
		$staleOwnerTrueRewriteCount++
	}
}
if ($staleOwnerTrueRewriteCount -ne 1) {
	throw "cross-form reusable-line boolean fixture rewrite mismatch: $staleOwnerTrueRewriteCount"
}
$staleOwnerMethod.expressionData = [Convert]::ToBase64String($staleOwnerExpression)
Write-EText $staleOwnerNativeMapPath ((ConvertTo-Json -InputObject $staleOwnerNativeMap -Depth 100) + "`r`n")
Invoke-Packager @('pack', $crossControlStaleOwnerWorkspace, $crossControlCandidate2)
Invoke-Packager @('unpack', $crossControlCandidate2, $crossControlUnpacked2, '--main-only')
Invoke-Packager @('compare-bundle', $crossControlCandidate2, $crossControlUnpacked2)

$crossControlExpectedLine = '返回 (_启动窗口.超级列表框1.取标题 (_启动窗口.超级列表框1.现行选中项, 1))'
$crossFormOwnerExpectedLine = '返回 (_启动窗口.左边 ＋ CrossFormProbe.宽度)'
$localSharedCallExpectedLine = '返回 (ProbeSharedName ())'
$qualifiedSharedCallExpectedLine = 'owner.ProbeSharedName ()'
$booleanTrueExpectedLine = '返回 (真)'
$booleanFalseExpectedLine = '返回 (假)'
$additiveAssociativityLine = '返回 (10 ＋ 3 － 2)'
$quotedConcatenationLine = '返回 (“第：” ＋ 到文本 (itemIndex) ＋ “条代理API异常请检查”)'
$multiplicativeAssociativityLine = '返回 (24 × 3 ÷ 2)'
$crossControlSource1 = Join-Path $crossControlUnpacked1 "src\$crossControlClassName.txt"
$crossControlSource2 = Join-Path $crossControlUnpacked2 "src\$crossControlClassName.txt"
foreach ($crossControlSource in @($crossControlSource1, $crossControlSource2)) {
    $projection = [IO.File]::ReadAllText($crossControlSource)
    if (-not $projection.Contains($crossControlExpectedLine) -or
        -not $projection.Contains($crossFormOwnerExpectedLine) -or
        -not $projection.Contains($localSharedCallExpectedLine) -or
        -not $projection.Contains($qualifiedSharedCallExpectedLine) -or
        -not $projection.Contains($booleanTrueExpectedLine) -or
        -not $projection.Contains($booleanFalseExpectedLine) -or
        -not $projection.Contains($additiveAssociativityLine) -or
        -not $projection.Contains($quotedConcatenationLine) -or
        -not $projection.Contains($quotedConcatenationLine + "`r`n`r`n`r`n.子程序 ProbeMultiplicativeAssociativity") -or
        -not $projection.Contains($multiplicativeAssociativityLine) -or
        $projection.Contains('_Control_0x') -or
        $projection.Contains('_Lib')) {
        throw "cross-form control projection lost public identities: $projection"
    }
}
if ((Get-FileHash -LiteralPath $crossControlSource1 -Algorithm SHA256).Hash -ne
    (Get-FileHash -LiteralPath $crossControlSource2 -Algorithm SHA256).Hash) {
    throw 'cross-form control source projection is not stable after the second roundtrip'
}

$crossControlMethodHeader = [byte[]](@(0x21) +
    [BitConverter]::GetBytes([int]48) +
    [BitConverter]::GetBytes([int16]$iextLibraryId))
$crossControlCanonicalMember = [byte[]](@(0x39) +
    [BitConverter]::GetBytes([int]36) +
    [BitConverter]::GetBytes([int]$iextControlTypeId))
$crossControlLegacyMember = [byte[]](@(0x39) +
    [BitConverter]::GetBytes([int]36) +
    [BitConverter]::GetBytes([int]196612))
$canonicalTrueLiteral = [byte[]](0x18, 0xFF, 0xFF)
$positiveTrueLiteral = [byte[]](0x18, 0x01, 0x00)
$canonicalFalseLiteral = [byte[]](0x18, 0x00, 0x00)
$crossControlIds = [Collections.Generic.List[int]]::new()
$sharedBindingIds = [Collections.Generic.List[string]]::new()
$crossControlRoundIndex = 0
foreach ($crossControlUnpacked in @($crossControlUnpacked1, $crossControlUnpacked2)) {
    $nativeMap = @(Get-Content -LiteralPath (Join-Path $crossControlUnpacked 'project\.native_source_map.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
    $method = @($nativeMap.methods | Where-Object { $_.name -eq 'ProbeCrossFormControl' })[0]
    if ($null -eq $method) { throw 'cross-form control native method snapshot missing' }
    $expression = [Convert]::FromBase64String($method.expressionData)
    if ((Get-NativeByteSequenceCount $expression $crossControlMethodHeader) -ne 1 -or
        (Get-NativeByteSequenceCount $expression $crossControlCanonicalMember) -ne 1 -or
        (Get-NativeByteSequenceCount $expression $crossControlLegacyMember) -ne 0) {
        throw ('cross-form support member did not use canonical owner type 0x{0:X8}' -f $iextControlTypeId)
    }
    $symbolMap = Get-Content -LiteralPath (Join-Path $crossControlUnpacked 'project\.native_symbol_map.json') -Raw -Encoding UTF8 | ConvertFrom-Json
	$startFormSnapshot = @($symbolMap.forms | Where-Object { $_.name -eq $controlWindowName })[0]
	$probeFormSnapshot = @($symbolMap.forms | Where-Object { $_.name -eq $crossControlFormName })[0]
	if ($null -eq $startFormSnapshot -or $null -eq $probeFormSnapshot) {
		throw 'cross-form native form identities missing'
	}
	$formOwnerMethod = @($nativeMap.methods | Where-Object { $_.name -eq 'ProbeCrossFormOwner' })[0]
	if ($null -eq $formOwnerMethod) { throw 'cross-form owner native method snapshot missing' }
	$formOwnerExpression = [Convert]::FromBase64String($formOwnerMethod.expressionData)
	$formOwnerIds = @([int]$startFormSnapshot.id, [int]$probeFormSnapshot.id)
	foreach ($formOwnerId in $formOwnerIds) {
		$formOwnerCount = 0
		for ($offset = 0; $offset + 8 -lt $formOwnerExpression.Length; $offset++) {
			if ($formOwnerExpression[$offset] -eq 0x39 -and
				[BitConverter]::ToInt32($formOwnerExpression, $offset + 5) -eq $formOwnerId) {
				$formOwnerCount++
			}
		}
		if ($formOwnerCount -ne 1) {
			throw ('cross-form support member lost concrete form owner 0x{0:X8}' -f $formOwnerId)
		}
	}
	$builtinFormOwnerCount = 0
	for ($offset = 0; $offset + 8 -lt $formOwnerExpression.Length; $offset++) {
		if ($formOwnerExpression[$offset] -eq 0x39 -and
			[BitConverter]::ToInt32($formOwnerExpression, $offset + 5) -eq 0x00010001) {
			$builtinFormOwnerCount++
		}
	}
	if ($builtinFormOwnerCount -ne 0) {
		throw 'cross-form support member encoded the support alias instead of the concrete form owner'
	}
	# Repairing a stale owner requires semantic re-encoding of that line, so true uses
	# the canonical semantic representation. The separate unchanged method below
	# proves that reusable snapshots preserve their original positive-one encoding.
	if ((Get-NativeByteSequenceCount $formOwnerExpression $canonicalTrueLiteral) -ne 1 -or
		(Get-NativeByteSequenceCount $formOwnerExpression $positiveTrueLiteral) -ne 0) {
		throw 'repaired native line did not use the semantic logical true representation'
	}
	$booleanTrueMethod = @($nativeMap.methods | Where-Object { $_.name -eq 'ProbeBooleanTrue' })[0]
	$booleanFalseMethod = @($nativeMap.methods | Where-Object { $_.name -eq 'ProbeBooleanFalse' })[0]
	if ($null -eq $booleanTrueMethod -or $null -eq $booleanFalseMethod) {
		throw 'native boolean regression methods missing'
	}
	$booleanTrueExpression = [Convert]::FromBase64String($booleanTrueMethod.expressionData)
	$booleanFalseExpression = [Convert]::FromBase64String($booleanFalseMethod.expressionData)
	if ((Get-NativeByteSequenceCount $booleanTrueExpression $canonicalTrueLiteral) -ne 1 -or
		(Get-NativeByteSequenceCount $booleanTrueExpression $positiveTrueLiteral) -ne 0 -or
		(Get-NativeByteSequenceCount $booleanFalseExpression $canonicalFalseLiteral) -ne 1) {
		throw 'semantic boolean encoding or unchanged native snapshot preservation failed'
	}
	$unpackedMeta = Get-Content -LiteralPath (Join-Path $crossControlUnpacked 'project\_meta.json') -Raw -Encoding UTF8 | ConvertFrom-Json
	$ownerClassIndex = -1
	$probeClassIndex = -1
	for ($sourceIndex = 0; $sourceIndex -lt $unpackedMeta.sourceFiles.Count; $sourceIndex++) {
		if ($unpackedMeta.sourceFiles[$sourceIndex].logicalName -eq $sharedOwnerClassName) {
			$ownerClassIndex = $sourceIndex
		}
		elseif ($unpackedMeta.sourceFiles[$sourceIndex].logicalName -eq $crossControlClassName) {
			$probeClassIndex = $sourceIndex
		}
	}
	if ($ownerClassIndex -lt 0 -or $probeClassIndex -lt 0) {
		throw 'same-name native function regression classes missing'
	}
	$ownerSharedMethod = @($nativeMap[$ownerClassIndex].methods | Where-Object { $_.name -eq 'ProbeSharedName' })[0]
	$probeSharedMethod = @($nativeMap[$probeClassIndex].methods | Where-Object { $_.name -eq 'ProbeSharedName' })[0]
	$localSharedCallMethod = @($nativeMap[$probeClassIndex].methods | Where-Object { $_.name -eq 'ProbeLocalSharedCall' })[0]
	$qualifiedSharedCallMethod = @($nativeMap[$probeClassIndex].methods | Where-Object { $_.name -eq 'ProbeQualifiedSharedCall' })[0]
	if ($null -eq $ownerSharedMethod -or $null -eq $probeSharedMethod -or
		$null -eq $localSharedCallMethod -or $null -eq $qualifiedSharedCallMethod) {
		throw 'same-name native function regression methods missing'
	}
	$ownerSharedCall = [byte[]](@(0x21) +
		[BitConverter]::GetBytes([int]$ownerSharedMethod.id) +
		[BitConverter]::GetBytes([int16]-2))
	$probeSharedCall = [byte[]](@(0x21) +
		[BitConverter]::GetBytes([int]$probeSharedMethod.id) +
		[BitConverter]::GetBytes([int16]-2))
	$qualifiedOwnerSharedCall = [byte[]](@(0x6A) +
		[BitConverter]::GetBytes([int]$ownerSharedMethod.id) +
		[BitConverter]::GetBytes([int16]-2))
	$qualifiedProbeSharedCall = [byte[]](@(0x6A) +
		[BitConverter]::GetBytes([int]$probeSharedMethod.id) +
		[BitConverter]::GetBytes([int16]-2))
	$localSharedExpression = [Convert]::FromBase64String($localSharedCallMethod.expressionData)
	$qualifiedSharedExpression = [Convert]::FromBase64String($qualifiedSharedCallMethod.expressionData)
	if ((Get-NativeByteSequenceCount $localSharedExpression $probeSharedCall) -ne 1 -or
		(Get-NativeByteSequenceCount $localSharedExpression $ownerSharedCall) -ne 0) {
		throw 'unqualified same-name call did not bind to the current assembly'
	}
	if ((Get-NativeByteSequenceCount $qualifiedSharedExpression $qualifiedOwnerSharedCall) -ne 1 -or
		(Get-NativeByteSequenceCount $qualifiedSharedExpression $qualifiedProbeSharedCall) -ne 0) {
		throw 'qualified same-name call did not bind through its target owner'
	}
	$sharedBindingIds.Add(('{0}:{1}' -f [int]$ownerSharedMethod.id, [int]$probeSharedMethod.id))
    $controlSnapshot = @($symbolMap.forms.elements | Where-Object { $_.name -eq '超级列表框1' })[0]
    if ($null -eq $controlSnapshot) { throw 'cross-form current control identity missing' }
	if ([int]$controlSnapshot.dataType -ne $iextControlTypeId) {
		throw ('cross-form current control used dependency slot type 0x{0:X8}, expected 0x{1:X8}' -f
			[int]$controlSnapshot.dataType,
			$iextControlTypeId)
	}
    $crossControlIds.Add([int]$controlSnapshot.id)
	$crossControlRoundIndex++
}
if ($crossControlIds.Count -ne 2 -or $crossControlIds[0] -ne $crossControlIds[1]) {
    throw 'cross-form control id changed during the second roundtrip'
}
if ($sharedBindingIds.Count -ne 2 -or $sharedBindingIds[0] -ne $sharedBindingIds[1]) {
	throw 'same-name function identities changed during the second roundtrip'
}

# Native snapshots from E projects legitimately use both 1 and -1 for logical
# true. A dependency-free fixture makes the JSON snapshot the sole authority,
# then verifies that an unchanged positive-one snapshot survives two packs.
$booleanSeedWorkspace = Join-Path $OutputRoot 'boolean-snapshot-seed-workspace'
Copy-TestWorkspace $consoleWorkspace $booleanSeedWorkspace
$booleanSeedProgram = Get-ChildItem -LiteralPath (Join-Path $booleanSeedWorkspace 'src') -Filter '*.txt' -File |
	Where-Object { -not $_.Name.StartsWith('.') } |
	Select-Object -First 1
if ($null -eq $booleanSeedProgram) { throw 'boolean snapshot seed source missing' }
Write-EText $booleanSeedProgram.FullName @'
.版本 2

.程序集 程序集1

.子程序 ProbeBooleanTrue, 逻辑型

返回 (真)

.子程序 ProbeBooleanFalse, 逻辑型

返回 (假)

.子程序 ProbeSharedName, 整数型, 公开

返回 (202)

.子程序 ProbeLocalSharedCall, 整数型

返回 (ProbeSharedName ())
'@
$booleanOwnerClassName = 'BooleanSharedOwnerProbe'
$booleanOwnerSourcePath = Join-Path $booleanSeedWorkspace "src\$booleanOwnerClassName.txt"
Write-EText $booleanOwnerSourcePath @'
.版本 2

.程序集 BooleanSharedOwnerProbe, , 公开

.子程序 ProbeSharedName, 整数型, 公开

返回 (101)
'@
$booleanSeedMetaPath = Join-Path $booleanSeedWorkspace 'project\_meta.json'
$booleanSeedMeta = Get-Content -LiteralPath $booleanSeedMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
$booleanSeedMeta.sourceFiles = @($booleanSeedMeta.sourceFiles) + @([pscustomobject]@{
	key = "class:$booleanOwnerClassName"
	logicalName = $booleanOwnerClassName
	relativePath = "src/$booleanOwnerClassName.txt"
})
$booleanSeedMeta.rootChildKeys = @($booleanSeedMeta.rootChildKeys) + "class:$booleanOwnerClassName"
Write-EText $booleanSeedMetaPath (($booleanSeedMeta | ConvertTo-Json -Depth 20) + "`r`n")
$booleanSeedCandidate = Join-Path $OutputRoot 'boolean-snapshot-seed.e'
$booleanSeedUnpacked = Join-Path $OutputRoot 'boolean-snapshot-seed-unpacked'
Invoke-Packager @('pack', $booleanSeedWorkspace, $booleanSeedCandidate)
Invoke-Packager @('unpack', $booleanSeedCandidate, $booleanSeedUnpacked, '--main-only')
$booleanPositiveWorkspace = Join-Path $OutputRoot 'boolean-snapshot-positive-workspace'
Copy-TestWorkspace $booleanSeedUnpacked $booleanPositiveWorkspace
$booleanPositiveMapPath = Join-Path $booleanPositiveWorkspace 'project\.native_source_map.json'
$booleanPositiveMap = @(Get-Content -LiteralPath $booleanPositiveMapPath -Raw -Encoding UTF8 | ConvertFrom-Json)
$booleanPositiveMethod = @($booleanPositiveMap.methods | Where-Object { $_.name -eq 'ProbeBooleanTrue' })[0]
if ($null -eq $booleanPositiveMethod) { throw 'boolean positive-one native snapshot method missing' }
$booleanPositiveExpression = [Convert]::FromBase64String($booleanPositiveMethod.expressionData)
$booleanPositiveRewriteCount = 0
for ($offset = 0; $offset + 2 -lt $booleanPositiveExpression.Length; $offset++) {
	if ($booleanPositiveExpression[$offset] -eq 0x18 -and
		$booleanPositiveExpression[$offset + 1] -eq 0xFF -and
		$booleanPositiveExpression[$offset + 2] -eq 0xFF) {
		$booleanPositiveExpression[$offset + 1] = 0x01
		$booleanPositiveExpression[$offset + 2] = 0x00
		$booleanPositiveRewriteCount++
	}
}
if ($booleanPositiveRewriteCount -ne 1) {
	throw "boolean positive-one native snapshot rewrite mismatch: $booleanPositiveRewriteCount"
}
$booleanPositiveMethod.expressionData = [Convert]::ToBase64String($booleanPositiveExpression)
$booleanCurrentClass = @($booleanPositiveMap | Where-Object { $_.methods.name -contains 'ProbeLocalSharedCall' })[0]
$booleanOwnerClass = @($booleanPositiveMap | Where-Object {
	$_.methods.name -contains 'ProbeSharedName' -and $_.methods.name -notcontains 'ProbeLocalSharedCall'
})[0]
if ($null -eq $booleanCurrentClass -or $null -eq $booleanOwnerClass) {
	throw 'boolean same-name stale snapshot classes missing'
}
$booleanCurrentSharedMethod = @($booleanCurrentClass.methods | Where-Object { $_.name -eq 'ProbeSharedName' })[0]
$booleanOwnerSharedMethod = @($booleanOwnerClass.methods | Where-Object { $_.name -eq 'ProbeSharedName' })[0]
$booleanStaleLocalCallMethod = @($booleanCurrentClass.methods | Where-Object { $_.name -eq 'ProbeLocalSharedCall' })[0]
if ($null -eq $booleanCurrentSharedMethod -or $null -eq $booleanOwnerSharedMethod -or
	$null -eq $booleanStaleLocalCallMethod) {
	throw 'boolean same-name stale snapshot methods missing'
}
$booleanStaleLocalCallReferences = [Convert]::FromBase64String($booleanStaleLocalCallMethod.methodReference)
if ($booleanStaleLocalCallReferences.Length -ne 4) {
	throw 'boolean same-name stale snapshot method reference mismatch'
}
$booleanStaleLocalCallOffset = [BitConverter]::ToInt32($booleanStaleLocalCallReferences, 0)
$booleanStaleLocalCallExpression = [Convert]::FromBase64String($booleanStaleLocalCallMethod.expressionData)
if ($booleanStaleLocalCallOffset -lt 0 -or
	$booleanStaleLocalCallOffset + 5 -gt $booleanStaleLocalCallExpression.Length -or
	$booleanStaleLocalCallExpression[$booleanStaleLocalCallOffset] -ne 0x21 -or
	[BitConverter]::ToInt32($booleanStaleLocalCallExpression, $booleanStaleLocalCallOffset + 1) -ne [int]$booleanCurrentSharedMethod.id) {
	throw 'boolean same-name stale snapshot call encoding mismatch'
}
[BitConverter]::GetBytes([int]$booleanOwnerSharedMethod.id).CopyTo(
	$booleanStaleLocalCallExpression,
	$booleanStaleLocalCallOffset + 1)
$booleanStaleLocalCallMethod.expressionData = [Convert]::ToBase64String($booleanStaleLocalCallExpression)
Write-EText $booleanPositiveMapPath ((ConvertTo-Json -InputObject $booleanPositiveMap -Depth 100) + "`r`n")
[IO.File]::Delete((Join-Path $booleanPositiveWorkspace 'project\.native_source.bin'))
$booleanPositiveCandidate1 = Join-Path $OutputRoot 'boolean-snapshot-positive-1.e'
$booleanPositiveUnpacked1 = Join-Path $OutputRoot 'boolean-snapshot-positive-unpacked-1'
$booleanPositiveCandidate2 = Join-Path $OutputRoot 'boolean-snapshot-positive-2.e'
$booleanPositiveUnpacked2 = Join-Path $OutputRoot 'boolean-snapshot-positive-unpacked-2'
Invoke-Packager @('pack', $booleanPositiveWorkspace, $booleanPositiveCandidate1)
Invoke-Packager @('unpack', $booleanPositiveCandidate1, $booleanPositiveUnpacked1, '--main-only')
Invoke-Packager @('compare-bundle', $booleanPositiveCandidate1, $booleanPositiveUnpacked1)
Invoke-Packager @('pack', $booleanPositiveUnpacked1, $booleanPositiveCandidate2)
Invoke-Packager @('unpack', $booleanPositiveCandidate2, $booleanPositiveUnpacked2, '--main-only')
Invoke-Packager @('compare-bundle', $booleanPositiveCandidate2, $booleanPositiveUnpacked2)
foreach ($booleanPositiveUnpacked in @($booleanPositiveUnpacked1, $booleanPositiveUnpacked2)) {
	$booleanPositiveRoundMap = @(Get-Content -LiteralPath (Join-Path $booleanPositiveUnpacked 'project\.native_source_map.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
	$booleanPositiveRoundTrue = @($booleanPositiveRoundMap.methods | Where-Object { $_.name -eq 'ProbeBooleanTrue' })[0]
	$booleanPositiveRoundFalse = @($booleanPositiveRoundMap.methods | Where-Object { $_.name -eq 'ProbeBooleanFalse' })[0]
	$booleanPositiveRoundCurrentClass = @($booleanPositiveRoundMap | Where-Object { $_.methods.name -contains 'ProbeLocalSharedCall' })[0]
	$booleanPositiveRoundOwnerClass = @($booleanPositiveRoundMap | Where-Object {
		$_.methods.name -contains 'ProbeSharedName' -and $_.methods.name -notcontains 'ProbeLocalSharedCall'
	})[0]
	if ($null -eq $booleanPositiveRoundTrue -or $null -eq $booleanPositiveRoundFalse -or
		$null -eq $booleanPositiveRoundCurrentClass -or $null -eq $booleanPositiveRoundOwnerClass) {
		throw 'boolean positive-one roundtrip methods missing'
	}
	$booleanPositiveRoundTrueExpression = [Convert]::FromBase64String($booleanPositiveRoundTrue.expressionData)
	$booleanPositiveRoundFalseExpression = [Convert]::FromBase64String($booleanPositiveRoundFalse.expressionData)
	if ((Get-NativeByteSequenceCount $booleanPositiveRoundTrueExpression $positiveTrueLiteral) -ne 1 -or
		(Get-NativeByteSequenceCount $booleanPositiveRoundTrueExpression $canonicalTrueLiteral) -ne 0 -or
		(Get-NativeByteSequenceCount $booleanPositiveRoundFalseExpression $canonicalFalseLiteral) -ne 1) {
		throw 'unchanged native logical snapshot representation was not preserved'
	}
	$booleanPositiveRoundCurrentShared = @($booleanPositiveRoundCurrentClass.methods | Where-Object { $_.name -eq 'ProbeSharedName' })[0]
	$booleanPositiveRoundOwnerShared = @($booleanPositiveRoundOwnerClass.methods | Where-Object { $_.name -eq 'ProbeSharedName' })[0]
	$booleanPositiveRoundLocalCall = @($booleanPositiveRoundCurrentClass.methods | Where-Object { $_.name -eq 'ProbeLocalSharedCall' })[0]
	$booleanPositiveRoundCurrentCallBytes = [byte[]](@(0x21) +
		[BitConverter]::GetBytes([int]$booleanPositiveRoundCurrentShared.id) +
		[BitConverter]::GetBytes([int16]-2))
	$booleanPositiveRoundOwnerCallBytes = [byte[]](@(0x21) +
		[BitConverter]::GetBytes([int]$booleanPositiveRoundOwnerShared.id) +
		[BitConverter]::GetBytes([int16]-2))
	$booleanPositiveRoundLocalCallExpression = [Convert]::FromBase64String($booleanPositiveRoundLocalCall.expressionData)
	if ((Get-NativeByteSequenceCount $booleanPositiveRoundLocalCallExpression $booleanPositiveRoundCurrentCallBytes) -ne 1 -or
		(Get-NativeByteSequenceCount $booleanPositiveRoundLocalCallExpression $booleanPositiveRoundOwnerCallBytes) -ne 0) {
		throw 'stale unqualified same-name native call was not repaired to its local assembly'
	}
}

if ($rawHandlerFailureEvidence.Count -ne 9) {
    throw "raw form handler negative evidence count mismatch: $($rawHandlerFailureEvidence.Count)"
}

$result = [ordered]@{
    schema = 'e-packager-roundtrip-core'
    version = (& $Packager version | Out-String).Trim()
    output_root = $OutputRoot
    console_subsystem = $consoleMeta.projectSubsystem
    window_subsystem = $windowMeta.projectSubsystem
    unchanged_console_sha256 = (Get-FileHash -LiteralPath $unchangedConsole -Algorithm SHA256).Hash.ToLowerInvariant()
    unchanged_window_sha256 = (Get-FileHash -LiteralPath $unchangedWindow -Algorithm SHA256).Hash.ToLowerInvariant()
    candidate_sha256 = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
    second_candidate_sha256 = (Get-FileHash -LiteralPath $candidate2 -Algorithm SHA256).Hash.ToLowerInvariant()
    form_control_xml_sha256 = $controlXmlHash.ToLowerInvariant()
    form_control_projection_sha256 = (Get-FileHash -LiteralPath $controlSource1 -Algorithm SHA256).Hash.ToLowerInvariant()
    form_control_second_projection_sha256 = (Get-FileHash -LiteralPath $controlSource2 -Algorithm SHA256).Hash.ToLowerInvariant()
    form_control_reference_count = 2
    cross_form_control_id = ('0x{0:X8}' -f $crossControlIds[0])
    cross_form_control_owner_type = ('0x{0:X8}' -f $iextControlTypeId)
    cross_form_control_projection_sha256 = (Get-FileHash -LiteralPath $crossControlSource1 -Algorithm SHA256).Hash.ToLowerInvariant()
    cross_form_control_second_projection_sha256 = (Get-FileHash -LiteralPath $crossControlSource2 -Algorithm SHA256).Hash.ToLowerInvariant()
	same_name_function_ids = $sharedBindingIds[0]
	stale_same_name_snapshot_repaired = $true
	semantic_true_encoding = '0xFFFF'
	preserved_snapshot_true_encoding = '0x0001'
    raw_form_handler_id = ('0x{0:X8}' -f $nativeHandlerId)
    raw_form_handler_alias = $rawHandlerAlias
    raw_form_handler_positive_sha256 = (Get-FileHash -LiteralPath $rawHandlerPositive -Algorithm SHA256).Hash.ToLowerInvariant()
    raw_form_handler_legacy_map_sha256 = (Get-FileHash -LiteralPath $legacyMapCandidate -Algorithm SHA256).Hash.ToLowerInvariant()
    raw_control_handler_positive_sha256 = (Get-FileHash -LiteralPath $rawControlHandlerPositive -Algorithm SHA256).Hash.ToLowerInvariant()
    raw_form_handler_positive_case_count = 3
    raw_form_handler_negative_case_count = 9
    raw_form_handler_failure_evidence = @($rawHandlerFailureEvidence)
    status = 'passed'
}
$reportPath = Join-Path $OutputRoot 'roundtrip-core-report.json'
[IO.File]::WriteAllText(
    $reportPath,
    (($result | ConvertTo-Json -Depth 5) -replace "`r?`n", "`r`n") + "`r`n",
    $utf8Bom)
Write-Host "PASS e-packager roundtrip core: $reportPath"
