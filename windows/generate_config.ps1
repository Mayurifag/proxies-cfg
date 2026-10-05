#Requires -Version 7.0
#Requires -PSEdition Core
<#
.SYNOPSIS
    Print the sing-box config (built from proxies.conf + subscriptions) to stdout.
#>
. "$PSScriptRoot\common.ps1"
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SecretsFile)) {
    Write-Error "$SecretsFile missing — run 'git-crypt unlock'."
    exit 1
}

$pyArgs = @(
    (Join-Path $RepoRoot 'shared\build_config.py'),
    $ProxiesConf,
    $RuleSetDir,
    '--interface-name', $TunAdapterName,
    '--log-output', $SingboxLog
)
$gateway = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
    Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' -and $_.InterfaceAlias -ne $TunAdapterName } |
    Sort-Object RouteMetric |
    Select-Object -First 1 -ExpandProperty NextHop
if (-not $gateway) { throw 'No default gateway found for local DNS routing.' }
$pyArgs += '--local-dns-server', $gateway
$global:LASTEXITCODE = 0
Push-Location $RepoRoot
try {
    Get-Content -Raw $SecretsFile | & uv run --quiet python @pyArgs
} finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw "build_config.py exit $LASTEXITCODE" }
