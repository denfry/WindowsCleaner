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

# Every root script ships (new libraries are picked up automatically) plus the docs.
# install.ps1 is the one-line web installer: shipped NEXT TO the zip, not inside it.
$include = @(Get-ChildItem -Path $root -Filter *.ps1 -File | Where-Object { $_.Name -ne 'install.ps1' } |
             ForEach-Object { $_.Name }) +
           @('WinSenior.cmd', 'Cleanup-Windows-Senior.bat', 'README.md', 'LICENSE', 'CHANGELOG.md')
$files = foreach ($f in $include) { $p = Join-Path $root $f; if (Test-Path $p) { $p } }

# Stage a copy and force CRLF on scripts. cmd.exe mis-resolves `call :label` / `goto`
# in LF-only batch files (jumps to the wrong place), and a working tree checked out
# without eol conversion has exactly that - so the zip must not depend on it.
$stage = Join-Path ([IO.Path]::GetTempPath()) ("winsenior-release-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($p in $files) {
    $dest = Join-Path $stage (Split-Path $p -Leaf)
    if ($p -match '\.(bat|cmd|ps1)$') {
        $bytes = [IO.File]::ReadAllBytes($p)
        $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $text = [IO.File]::ReadAllText($p) -replace "`r?`n", "`r`n"
        [IO.File]::WriteAllText($dest, $text, (New-Object System.Text.UTF8Encoding($bom)))
    }
    else { Copy-Item -LiteralPath $p -Destination $dest }
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$zipName = "WinSenior-$version.zip"
$zip = Join-Path $OutDir $zipName
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal -Force
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue

# .NET hash (not Get-FileHash): works even when Windows PowerShell inherits pwsh's PSModulePath.
function Get-Sha256 {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create(); $fs = [IO.File]::OpenRead($Path)
    try { -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('X2') }) } finally { $fs.Dispose(); $sha.Dispose() }
}

$hash = Get-Sha256 $zip
$sums = @("$hash  $zipName")

# The web installer goes out as its own asset (releases/latest/download/install.ps1).
$installer = Join-Path $root 'install.ps1'
if (Test-Path $installer) {
    $instOut = Join-Path $OutDir 'install.ps1'
    [IO.File]::WriteAllText($instOut, ([IO.File]::ReadAllText($installer) -replace "`r?`n", "`r`n"),
        (New-Object System.Text.UTF8Encoding($false)))
    $sums += "$(Get-Sha256 $instOut)  install.ps1"
}
$sums | Set-Content -Path (Join-Path $OutDir 'SHA256SUMS.txt') -Encoding ASCII

Write-Host "Version : $version"            -ForegroundColor Cyan
Write-Host "Files   : $(@($files).Count) bundled"
Write-Host "Zip     : $zip"                -ForegroundColor Green
Write-Host "SHA256  : $hash"
[pscustomobject]@{ Version = $version; Zip = $zip; Sha256 = $hash; FileCount = @($files).Count }
