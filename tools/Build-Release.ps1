<#
.SYNOPSIS
    Package a WinSenior release: a versioned zip of the runtime files + SHA256SUMS.

.DESCRIPTION
    Reads the version from Get-WinSeniorVersion (single source of truth), bundles the
    engines, libraries, menu, the .bat, README/LICENSE/CHANGELOG into dist\WinSenior-<ver>.zip,
    and writes dist\SHA256SUMS.txt. The dist\ folder is git-ignored.

.EXAMPLE
    .\tools\Build-Release.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param([string]$OutDir)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

. (Join-Path $root 'WinSenior.Common.ps1')
$version = Get-WinSeniorVersion

$include = @(
    'WinSenior.ps1', 'WinSenior.Common.ps1', 'WinSenior.UI.ps1', 'WinSenior.Schedule.ps1',
    'Cleanup-Windows-Senior.ps1', 'Optimize-Windows-Senior.ps1', 'Repair-Windows-Senior.ps1',
    'Cleanup-Windows-Senior.bat', 'README.md', 'LICENSE', 'CHANGELOG.md'
)
$files = foreach ($f in $include) { $p = Join-Path $root $f; if (Test-Path $p) { $p } }

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$zipName = "WinSenior-$version.zip"
$zip = Join-Path $OutDir $zipName
Compress-Archive -Path $files -DestinationPath $zip -CompressionLevel Optimal -Force

$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
"$hash  $zipName" | Set-Content -Path (Join-Path $OutDir 'SHA256SUMS.txt') -Encoding ASCII

Write-Host "Version : $version"            -ForegroundColor Cyan
Write-Host "Files   : $(@($files).Count) bundled"
Write-Host "Zip     : $zip"                -ForegroundColor Green
Write-Host "SHA256  : $hash"
[pscustomobject]@{ Version = $version; Zip = $zip; Sha256 = $hash; FileCount = @($files).Count }
