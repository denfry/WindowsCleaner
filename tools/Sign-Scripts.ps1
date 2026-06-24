<#
.SYNOPSIS
    Authenticode-sign every root WinSenior .ps1 with a code-signing certificate.

.DESCRIPTION
    Signs the engines, libraries and menu so users do not need -ExecutionPolicy Bypass
    (an AllSigned/RemoteSigned policy will trust them). Supply the SHA1 thumbprint of a
    code-signing certificate in Cert:\CurrentUser\My (or Cert:\LocalMachine\My).
    Run this AFTER Build-Release if you want the zip to contain signed scripts (re-zip after).

.PARAMETER CertThumbprint
    Thumbprint of the code-signing certificate.

.PARAMETER TimestampUrl
    RFC-3161 timestamp server (so signatures stay valid after the cert expires).

.EXAMPLE
    .\tools\Sign-Scripts.ps1 -CertThumbprint ABC123...DEF
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CertThumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Thumbprint -eq $CertThumbprint } | Select-Object -First 1
if (-not $cert) { throw "No code-signing certificate with thumbprint $CertThumbprint found in CurrentUser\My or LocalMachine\My." }

$scripts = Get-ChildItem -Path $root -Filter *.ps1 -File
foreach ($s in $scripts) {
    $r = Set-AuthenticodeSignature -FilePath $s.FullName -Certificate $cert `
        -TimestampServer $TimestampUrl -HashAlgorithm SHA256
    Write-Host ("{0,-34} {1}" -f $s.Name, $r.Status) -ForegroundColor $(if ($r.Status -eq 'Valid') { 'Green' } else { 'Yellow' })
}
