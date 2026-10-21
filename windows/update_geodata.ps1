#Requires -Version 7.0
#Requires -PSEdition Core
. "$PSScriptRoot\common.ps1"
. (Join-Path $PSScriptRoot '..\shared\constants.ps1')
<#
.SYNOPSIS
    Download geoip.dat + geosite.dat (24h TTL) and convert to sing-box JSON
    rule-sets via shared/geo_convert.py.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Invoke-Python -Arguments @((Join-Path $RepoRoot 'shared\rotate_logs.py'), $RuntimeDir)

if (-not (Test-Path $GeodataDir)) { New-Item -ItemType Directory -Path $GeodataDir | Out-Null }
if (-not (Test-Path $RuleSetDir)) { New-Item -ItemType Directory -Path $RuleSetDir | Out-Null }

$GeoIpPath   = Join-Path $GeodataDir 'geoip.dat'
$GeoSitePath = Join-Path $GeodataDir 'geosite.dat'

function Test-NeedsUpdate {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $true }
    $age = (Get-Date) - (Get-Item $Path).LastWriteTime
    return $age.TotalSeconds -gt 86400
}

if (Test-NeedsUpdate $GeoIpPath) {
    Write-Phase 'geodata' "downloading geoip.dat from $GeoipUrl"
    Invoke-WebRequest -Uri $GeoipUrl -OutFile "$GeoIpPath.tmp" -UseBasicParsing
    Move-Item "$GeoIpPath.tmp" $GeoIpPath -Force
}

if (Test-NeedsUpdate $GeoSitePath) {
    Write-Phase 'geodata' "downloading geosite.dat from $GeositeUrl"
    Invoke-WebRequest -Uri $GeositeUrl -OutFile "$GeoSitePath.tmp" -UseBasicParsing
    Move-Item "$GeoSitePath.tmp" $GeoSitePath -Force
}

if ((Get-Item $GeoIpPath).Length -eq 0)   { Write-Error 'geoip.dat empty';   exit 1 }
if ((Get-Item $GeoSitePath).Length -eq 0) { Write-Error 'geosite.dat empty'; exit 1 }

Write-Phase 'geodata' "converting .dat -> sing-box rule-sets in $RuleSetDir"
$pyArgs = @(
    (Join-Path $RepoRoot 'shared\geo_convert.py'),
    $GeoSitePath, $GeoIpPath, $RuleSetDir,
    '--from-proxies-conf', $ProxiesConf
)
Invoke-Python -Arguments $pyArgs
