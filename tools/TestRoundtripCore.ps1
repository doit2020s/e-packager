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
    status = 'passed'
}
$reportPath = Join-Path $OutputRoot 'roundtrip-core-report.json'
[IO.File]::WriteAllText(
    $reportPath,
    (($result | ConvertTo-Json -Depth 5) -replace "`r?`n", "`r`n") + "`r`n",
    $utf8Bom)
Write-Host "PASS e-packager roundtrip core: $reportPath"
