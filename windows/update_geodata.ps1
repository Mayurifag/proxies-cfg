#Requires -Version 7.0
#Requires -PSEdition Core
. "$PSScriptRoot\common.ps1"
. (Join-Path $PSScriptRoot '..\shared\constants.ps1')
<#
.SYNOPSIS
    Download the upstream sing-box rule-set archive (24h TTL) and extract the
    configured categories.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Invoke-Python -Arguments @((Join-Path $RepoRoot 'shared\rotate_logs.py'), $RuntimeDir)

if (-not (Test-Path $GeodataDir)) { New-Item -ItemType Directory -Path $GeodataDir | Out-Null }
if (-not (Test-Path $RuleSetDir)) { New-Item -ItemType Directory -Path $RuleSetDir | Out-Null }

$Archive = Join-Path $GeodataDir 'sing-box.zip'
$Temporary = "$Archive.tmp"

function Test-NeedsUpdate {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $true }
    $age = (Get-Date) - (Get-Item $Path).LastWriteTime
    return $age.TotalSeconds -gt 86400
}

try {
    if (Test-NeedsUpdate $Archive) {
        try {
            Write-Phase 'geodata' 'downloading sing-box rule sets'
            $version = Get-GithubLatestVersion -Repo $GeodataRepo
            if (-not $version) { throw 'Could not resolve the geodata release.' }
            Invoke-GithubReleaseDownload -Repo $GeodataRepo -Tag $version -Asset 'sing-box.zip' -Destination $Temporary
            if ((Get-Item $Temporary).Length -eq 0) { throw 'Rule-set archive is empty.' }
            Invoke-Python -Arguments @('-m', 'zipfile', '-t', $Temporary) | Out-Null
            Invoke-Python -Arguments @((Join-Path $RepoRoot 'shared\extract_rule_sets.py'), $Temporary, $RuleSetDir, $ProxiesConf) | Out-Null
            [System.IO.File]::Move($Temporary, $Archive, $true)
            return
        } catch {
            if (-not (Test-Path $Archive) -or (Get-Item $Archive).Length -eq 0) { throw }
            Write-Phase 'geodata' 'update failed; using the cached archive'
        }
    }
    Invoke-Python -Arguments @((Join-Path $RepoRoot 'shared\extract_rule_sets.py'), $Archive, $RuleSetDir, $ProxiesConf) | Out-Null
} finally {
    Remove-Item $Temporary -Force -ErrorAction SilentlyContinue
}
