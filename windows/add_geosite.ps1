#Requires -Version 7.0
#Requires -PSEdition Core
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Add a geosite to a proxy in proxies.conf, restart proxy.
#>
[CmdletBinding()]
param(
    [string]$Geosite = '',
    [string]$Proxy  = ''
)
. "$PSScriptRoot\common.ps1"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Assert-Admin

if (-not (Test-Path $ProxiesConf)) { Write-Error "$ProxiesConf not found"; exit 1 }
Invoke-GitPullIfClean

if ([string]::IsNullOrWhiteSpace($Geosite)) {
    $Geosite = Read-Host 'Enter geosite (e.g. booking)'
}
$Geosite = $Geosite -replace '^geosite:', ''

$tagsArgs = @((Join-Path $RepoRoot 'shared\proxies_conf.py'), 'tags', $ProxiesConf)
$tags = @(Invoke-Python -Arguments $tagsArgs | Where-Object { $_ })
if ($tags.Count -eq 0) { Write-Error 'No proxy tags found'; exit 1 }

if ([string]::IsNullOrWhiteSpace($Proxy)) {
    Write-Host 'Available proxy tags:'
    for ($i = 0; $i -lt $tags.Count; $i++) { Write-Host "  $($i+1)) $($tags[$i])" }
    do {
        $choice = Read-Host "Select proxy by number (1-$($tags.Count))"
    } until ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $tags.Count)
    $Proxy = $tags[[int]$choice - 1]
} elseif ($Proxy -match '^\d+$') {
    $idx = [int]$Proxy
    if ($idx -lt 1 -or $idx -gt $tags.Count) { Write-Error "Invalid number $Proxy"; exit 1 }
    $Proxy = $tags[$idx - 1]
} elseif ($tags -notcontains $Proxy) {
    Write-Error "Invalid proxy tag: $Proxy. Valid: $($tags -join ', ')"
    exit 1
}

$addArgs = @(
    (Join-Path $RepoRoot 'shared\proxies_conf.py'),
    'add-geosite', $Proxy, $Geosite, $ProxiesConf
)
Invoke-Python -Arguments $addArgs

$geositeDat = Join-Path $GeodataDir 'geosite.dat'
$geoipDat = Join-Path $GeodataDir 'geoip.dat'
if ((Test-Path $geositeDat) -and (Test-Path $geoipDat)) {
    $convertArgs = @(
        (Join-Path $RepoRoot 'shared\geo_convert.py'),
        $geositeDat, $geoipDat, $RuleSetDir,
        '--from-proxies-conf', $ProxiesConf
    )
    Invoke-Python -Arguments $convertArgs
}

Invoke-GitCommitAndPush "chore(routing): add geosite $Geosite to $Proxy"

Write-Host 'Restarting proxy...'
Restart-Proxy
