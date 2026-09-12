param(
    [string]$Packager = (Join-Path $PSScriptRoot '..\bin\Win32\Release\e-packager.exe'),
    [string]$OutputRoot = (Join-Path $PSScriptRoot "..\.autolinker\work\pack-output-rebinding-$([guid]::NewGuid().ToString('N'))")
)

$ErrorActionPreference = 'Stop'
$packagerPath = (Resolve-Path -LiteralPath $Packager).Path
$templatePath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\eproj\e-console-exe-new-proj.e')).Path
$workspace = Join-Path $OutputRoot 'workspace'
$packed = Join-Path $OutputRoot 'renamed-output.e'
$unpacked = Join-Path $OutputRoot 'unpacked-renamed'

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
& $packagerPath unpack $templatePath $workspace
if ($LASTEXITCODE -ne 0) { throw 'template unpack failed' }
$before = Get-Content -LiteralPath (Join-Path $workspace 'project\.module.json') -Raw -Encoding UTF8 | ConvertFrom-Json

& $packagerPath pack $workspace $packed
if ($LASTEXITCODE -ne 0) { throw 'renamed pack failed' }
& $packagerPath unpack $packed $unpacked
if ($LASTEXITCODE -ne 0) { throw 'renamed output unpack failed' }
$after = Get-Content -LiteralPath (Join-Path $unpacked 'project\.module.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$expectedPath = [IO.Path]::GetFullPath($packed)
if ($after.sourcePath -ne $expectedPath) {
    throw "packed sourcePath was not rebound: expected=$expectedPath actual=$($after.sourcePath)"
}
$expectedProjectName = [IO.Path]::GetFileNameWithoutExtension($packed)
if ($after.projectName -ne $expectedProjectName) {
    throw "derived projectName was not rebound: expected=$expectedProjectName actual=$($after.projectName)"
}

Write-Output "pack_output_rebinding=ok output=$packed"
