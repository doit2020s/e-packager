param(
    [string]$Packager = (Join-Path $PSScriptRoot '..\bin\Win32\Release\e-packager.exe'),
    [string]$OutputRoot = (Join-Path $PSScriptRoot "..\.autolinker\work\upstream-semantic-$([guid]::NewGuid().ToString('N'))")
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$managedRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '.autolinker\work'))
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (-not $OutputRoot.StartsWith($managedRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputRoot must stay below $managedRoot"
}
if (Test-Path -LiteralPath $OutputRoot) {
    throw "OutputRoot already exists: $OutputRoot"
}
[IO.Directory]::CreateDirectory($OutputRoot) | Out-Null

$Packager = (Resolve-Path -LiteralPath $Packager).Path
$template = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'eproj\e-console-exe-new-proj.e')).Path
$utf8Bom = [Text.UTF8Encoding]::new($true)

function Invoke-Packager {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$ExpectFailure)
    $text = & $Packager @Arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    if ($ExpectFailure) {
        if ($exitCode -eq 0) { throw "Expected failure: $($Arguments -join ' ')" }
    }
    elseif ($exitCode -ne 0) {
        throw "e-packager failed: $($Arguments -join ' ')`n$text"
    }
    return $text
}

function Write-EText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $normalized = ($Text -replace "`r?`n", "`r`n").TrimEnd("`r", "`n") + "`r`n"
    [IO.File]::WriteAllText($Path, $normalized, $utf8Bom)
}

function New-Workspace([string]$Name) {
    $workspace = Join-Path $OutputRoot $Name
    Invoke-Packager @('unpack', $template, $workspace, '--main-only') | Out-Null
    return $workspace
}

function Get-ProgramPage([string]$Workspace) {
    return Get-ChildItem -LiteralPath (Join-Path $Workspace 'src') -Filter '*.txt' -File |
        Where-Object { -not $_.Name.StartsWith('.') } |
        Select-Object -First 1
}

# A new global has no native snapshot. Its new ID and type must nevertheless be
# registered before method expression encoding starts.
$globalWorkspace = New-Workspace 'new-global-workspace'
Write-EText (Join-Path $globalWorkspace 'src\.全局变量.txt') @'
.版本 2

.全局变量 新增全局, 整数型, , , 新增变量必须参与方法名称连接
'@
Write-EText (Get-ProgramPage $globalWorkspace).FullName @'
.版本 2

.程序集 程序集1

.子程序 _启动子程序, 整数型
新增全局 ＝ 7
返回 (新增全局)
'@
$globalOutput = Join-Path $OutputRoot 'new-global.e'
$globalDecoded = Join-Path $OutputRoot 'new-global-decoded'
Invoke-Packager @('pack', $globalWorkspace, $globalOutput) | Out-Null
Invoke-Packager @('unpack', $globalOutput, $globalDecoded, '--main-only') | Out-Null
$globalText = [IO.File]::ReadAllText((Join-Path $globalDecoded 'src\.全局变量.txt'))
$programText = [IO.File]::ReadAllText((Get-ProgramPage $globalDecoded).FullName)
if (-not $globalText.Contains('新增全局') -or -not $programText.Contains('返回 (新增全局)')) {
    throw 'New global declaration or reference was lost during semantic rebuild'
}

# Resolve an inherited method through a base class that appears later in the
# serialized source order, including an array receiver.
$inheritanceWorkspace = New-Workspace 'inheritance-workspace'
Write-EText (Join-Path $inheritanceWorkspace 'src\派生类.txt') @'
.版本 2
.程序集 派生类, 中间类, 公开
'@
Write-EText (Join-Path $inheritanceWorkspace 'src\中间类.txt') @'
.版本 2
.程序集 中间类, 基类, 公开
'@
Write-EText (Join-Path $inheritanceWorkspace 'src\基类.txt') @'
.版本 2
.程序集 基类, <对象>, 公开
.子程序 取值, 整数型, 公开
返回 (42)
'@
Write-EText (Get-ProgramPage $inheritanceWorkspace).FullName @'
.版本 2
.程序集 程序集1
.子程序 _启动子程序, 整数型
.局部变量 实例, 派生类, , "2"
返回 (实例[1].取值 ())
'@
$inheritanceOutput = Join-Path $OutputRoot 'inheritance.e'
$inheritanceDecoded = Join-Path $OutputRoot 'inheritance-decoded'
Invoke-Packager @('pack', $inheritanceWorkspace, $inheritanceOutput) | Out-Null
Invoke-Packager @('unpack', $inheritanceOutput, $inheritanceDecoded, '--main-only') | Out-Null
if (-not [IO.File]::ReadAllText((Get-ProgramPage $inheritanceDecoded).FullName).Contains('实例[1].取值 ()')) {
    throw 'Inherited method call did not survive roundtrip'
}

# A valid local overload keeps local precedence. An invalid local arity must
# fall through to the core support command with the same name.
$scopeWorkspace = New-Workspace 'function-scope-workspace'
Write-EText (Get-ProgramPage $scopeWorkspace).FullName @'
.版本 2
.程序集 程序集1
.子程序 _启动子程序, 整数型
返回 (0)
.子程序 写到文件, 逻辑型
.参数 路径, 文本型, 可空
返回 (真)
.子程序 调本地, 逻辑型
返回 (写到文件 ())
.子程序 调支持库, 逻辑型
返回 (写到文件 ("", {}))
'@
$scopeOutput = Join-Path $OutputRoot 'function-scope.e'
$scopeDecoded = Join-Path $OutputRoot 'function-scope-decoded'
Invoke-Packager @('pack', $scopeWorkspace, $scopeOutput) | Out-Null
Invoke-Packager @('unpack', $scopeOutput, $scopeDecoded, '--main-only') | Out-Null
$nativeMap = Get-Content -LiteralPath (Join-Path $scopeDecoded 'project\.native_source_map.json') -Raw -Encoding UTF8 |
    ConvertFrom-Json
$owner = @($nativeMap | Where-Object { $_.methods.name -contains '调本地' })[0]
$localId = @($owner.methods | Where-Object name -eq '写到文件')[0].id
foreach ($case in @(
    @{ Name = '调本地'; Library = -2; Method = $localId },
    @{ Name = '调支持库'; Library = 0; Method = 155 }
)) {
    $method = @($owner.methods | Where-Object name -eq $case.Name)[0]
    $bytes = [Convert]::FromBase64String($method.expressionData)
    if ($bytes[18] -ne 0x21 -or
        [BitConverter]::ToInt32($bytes, 19) -ne $case.Method -or
        [BitConverter]::ToInt16($bytes, 23) -ne $case.Library) {
        throw "Incorrect call target for $($case.Name)"
    }
}

# Support-library member types must carry through chained property access.
$propertyWorkspace = New-Workspace 'support-property-workspace'
Write-EText (Get-ProgramPage $propertyWorkspace).FullName @'
.版本 2
.程序集 程序集1
.子程序 _启动子程序, 整数型
返回 (0)
.子程序 读取字体名, 文本型
.参数 画布, 画板
返回 (画布.字体.字体名称)
'@
$propertyOutput = Join-Path $OutputRoot 'support-property.e'
$propertyDecoded = Join-Path $OutputRoot 'support-property-decoded'
Invoke-Packager @('pack', $propertyWorkspace, $propertyOutput) | Out-Null
Invoke-Packager @('unpack', $propertyOutput, $propertyDecoded, '--main-only') | Out-Null
if (-not [IO.File]::ReadAllText((Get-ProgramPage $propertyDecoded).FullName).Contains('画布.字体.字体名称')) {
    throw 'Chained support-library property type was lost'
}

# Direct .ec unpacking is supported, but an edited module must be emitted as a
# new .e project so E 5.9 can compile it back to a native module deliberately.
$ecSeedWorkspace = New-Workspace 'ec-seed-workspace'
$ecInfoPath = Join-Path $ecSeedWorkspace 'info.json'
$ecInfo = Get-Content -LiteralPath $ecInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
$ecInfo.sourceFileKind = 'ec'
$ecInfo.sourceFileName = 'semantic-seed.ec'
Write-EText $ecInfoPath (($ecInfo | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
$ecMetaPath = Join-Path $ecSeedWorkspace 'project\_meta.json'
$ecMeta = Get-Content -LiteralPath $ecMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
$ecMeta.sourceFileKind = 'ec'
Write-EText $ecMetaPath (($ecMeta | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
$ecBridge = Join-Path $OutputRoot 'semantic-seed.ec.e'
$ecSeed = Join-Path $OutputRoot 'semantic-seed.ec'
Invoke-Packager @('pack', $ecSeedWorkspace, $ecBridge) | Out-Null
Copy-Item -LiteralPath $ecBridge -Destination $ecSeed

$ecWorkspace = Join-Path $OutputRoot 'ec-direct-unpack'
Invoke-Packager @('unpack', $ecSeed, $ecWorkspace, '--main-only') | Out-Null
$ecPage = Get-ProgramPage $ecWorkspace
$ecText = [IO.File]::ReadAllText($ecPage.FullName) + @'

.子程序 新增模块方法, 整数型
返回 (9)
'@
Write-EText $ecPage.FullName $ecText
$rejectedEc = Join-Path $OutputRoot 'edited-module.ec'
$ecFailure = Invoke-Packager @('pack', $ecWorkspace, $rejectedEc) -ExpectFailure
if (-not $ecFailure.Contains('modified_ec_requires_e_output')) {
    throw 'Edited .ec output did not fail with the required safety diagnostic'
}
$editedE = Join-Path $OutputRoot 'edited-module.e'
$editedEDecoded = Join-Path $OutputRoot 'edited-module-decoded'
Invoke-Packager @('pack', $ecWorkspace, $editedE) | Out-Null
Invoke-Packager @('unpack', $editedE, $editedEDecoded, '--main-only') | Out-Null
if (-not [IO.File]::ReadAllText((Get-ProgramPage $editedEDecoded).FullName).Contains('新增模块方法')) {
    throw 'Edited .ec workspace did not survive the safe .e bridge'
}

$report = [ordered]@{
    status = 'passed'
    architecture = 'Win32'
    new_global = $globalOutput
    inheritance = $inheritanceOutput
    function_scope = $scopeOutput
    support_property = $propertyOutput
    ec_direct_unpack = $ecSeed
    ec_modified_e_output = $editedE
}
$reportPath = Join-Path $OutputRoot 'report.json'
[IO.File]::WriteAllText($reportPath, (($report | ConvertTo-Json -Depth 8) + "`r`n"), $utf8Bom)
Write-Host "PASS upstream semantic backports: $reportPath"
