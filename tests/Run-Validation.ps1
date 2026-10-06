[CmdletBinding()]
param(
    [string]$RootPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $RootPath) {
    $RootPath = Split-Path -Parent $PSScriptRoot
}

$testPath = Join-Path $PSScriptRoot 'ProfessionalVideoDownloader.Tests.ps1'
if (-not (Test-Path -LiteralPath $testPath)) {
    throw "Missing Pester test file: $testPath"
}

$pesterModule = Get-Module -ListAvailable Pester |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pesterModule) {
    throw 'Pester is not installed.'
}

Import-Module $pesterModule.Path -Force
$pesterVersion = (Get-Module Pester).Version

if ($pesterVersion.Major -ge 5) {
    Invoke-Pester -Path $testPath -EnableExit
}
else {
    Invoke-Pester -Script @{
        Path       = $testPath
        Parameters  = @{ RootPath = $RootPath }
    } -EnableExit
}
