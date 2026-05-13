#Requires -Version 7.0
#Requires -PSEdition Core
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Full integration test for sing-box-extended TUN proxy on Windows.
    Mirrors shared/test_core.sh: teardown -> verify direct -> setup -> verify all.
#>
. "$PSScriptRoot\common.ps1"
. (Join-Path $PSScriptRoot '..\shared\constants.ps1')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Assert-Admin

$script:pass = 0
$script:fail = 0

function Write-Result {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    if ($Passed) {
        Write-Host "[test] PASS: $Name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "[test] FAIL: $Name $(if ($Detail) {"- $Detail"})" -ForegroundColor Red
        $script:fail++
    }
}

function Reset-ConnectionPool {
    foreach ($uri in $AllTestUrls) {
        $null = [System.Net.ServicePointManager]::FindServicePoint($uri).CloseConnectionGroup('')
    }
}

Write-Host '=== Phase: teardown ===' -ForegroundColor Cyan
& "$PSScriptRoot\teardown.ps1"
Reset-ConnectionPool

Write-Host '=== Verify: proxy down ===' -ForegroundColor Cyan
$d = Test-Outbound $DirectTestUrl
$i = Test-Outbound $ProxyItTestUrl
$r = Test-Outbound $ProxyRuTestUrl
Write-Result 'direct (checkip) non-empty' ([bool]$d)
if ($d -and $i) { Write-Result 'eth0 == checkip (proxy down)'  ($i -eq $d) -Detail "eth0=$i checkip=$d" }
if ($d -and $r) { Write-Result 'ident == checkip (proxy down)' ($r -eq $d) -Detail "ident=$r checkip=$d" }

Write-Host '=== Phase: setup ===' -ForegroundColor Cyan
& "$PSScriptRoot\setup.ps1"
Reset-ConnectionPool

Write-Host '=== Verify: pre-flight ===' -ForegroundColor Cyan
Write-Result 'sing-box process running' ([bool](Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue))
Write-Result "$TunAdapterName adapter present" ([bool](Get-NetAdapter -Name $TunAdapterName -ErrorAction SilentlyContinue))

Write-Host '=== Verify: outbounds distinct ===' -ForegroundColor Cyan
$directIp = Test-Outbound $DirectTestUrl
$itIp     = Test-Outbound $ProxyItTestUrl
$ruIp     = Test-Outbound $ProxyRuTestUrl
Write-Result 'direct IP non-empty'   ([bool]$directIp)
Write-Result 'proxy_it IP non-empty' ([bool]$itIp)
Write-Result 'proxy_ru IP non-empty' ([bool]$ruIp)
if ($directIp -and $itIp -and $ruIp) {
    Write-Host "[test] IPs: direct=$directIp it=$itIp ru=$ruIp" -ForegroundColor DarkGray
    Write-Result 'direct != proxy_it'   ($directIp -ne $itIp) -Detail "both=$directIp"
    Write-Result 'direct != proxy_ru'   ($directIp -ne $ruIp) -Detail "both=$directIp"
    Write-Result 'proxy_it != proxy_ru' ($itIp     -ne $ruIp) -Detail "both=$itIp"
}

Write-Host '=== Verify: proxy_it IPv6 routing ===' -ForegroundColor Cyan
$itIpv6Ok = $false
try {
    $ipv6Addr = [System.Net.Dns]::GetHostAddresses($ProxyItIpv6TestHost) |
        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 } |
        Select-Object -First 1
    if ($ipv6Addr -and (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        & curl.exe -6 -fsSI --resolve "$($ProxyItIpv6TestHost):443:[$ipv6Addr]" --max-time 15 $ProxyItIpv6TestUrl | Out-Null
        $itIpv6Ok = $LASTEXITCODE -eq 0
    }
} catch { }
Write-Result 'proxy_it IPv6 ntc.party reachable' $itIpv6Ok

$sshTestCmd = (Get-Content $SecretsFile -Raw | ConvertFrom-Json).PSObject.Properties['ssh_test_command']
if ($sshTestCmd -and $sshTestCmd.Value) {
    Write-Host '=== Verify: SSH to deploy host (direct routing) ===' -ForegroundColor Cyan
    $tokens = @($sshTestCmd.Value -split '\s+' | Where-Object { $_ })
    $exe = $tokens[0]
    $sshArgs = @()
    if ($tokens.Length -gt 1) {
        $sshArgs += $tokens[1..($tokens.Length - 1)]
    }
    $sshArgs += @('-o','BatchMode=yes','-o','ConnectTimeout=5','true')
    $proc = Start-Process -FilePath $exe -ArgumentList $sshArgs -PassThru -NoNewWindow
    if ($proc.WaitForExit(10000)) {
        Write-Result "$($sshTestCmd.Value) ok" ($proc.ExitCode -eq 0) -Detail "exit=$($proc.ExitCode)"
    } else {
        $proc.Kill()
        Write-Result "$($sshTestCmd.Value) ok" $false -Detail 'timeout 10s (TUN may eat server IP)'
    }
}

$probeRuleset = Join-Path $RuleSetDir 'geosite-ru-available-only-inside.json'
if ((Test-Path $probeRuleset) -and $ruIp) {
    Write-Host '=== Verify: ru-available-only-inside routing ===' -ForegroundColor Cyan
    $null = [System.Net.ServicePointManager]::FindServicePoint($RuInsideProbeUrl).CloseConnectionGroup('')
    $probeIp = $null
    try {
        $resp = Invoke-WebRequest -Uri $RuInsideProbeUrl -TimeoutSec 15 -UseBasicParsing
        if ($resp.Content -match '(\d{1,3}(?:\.\d{1,3}){3})') { $probeIp = $matches[1] }
    } catch { }
    if ($probeIp) {
        Write-Result 'showip.net (non-.ru) routed via proxy_ru' ($probeIp -eq $ruIp) -Detail "got=$probeIp ru=$ruIp"
    } else {
        Write-Result 'showip.net reachable' $false -Detail 'no IP parsed from response'
    }
}

Write-Host '=== Verify: rule-set integrity ===' -ForegroundColor Cyan
$expected = @()
try {
    Push-Location $RepoRoot
    try {
        $expected = & uv run --quiet python -c @"
import sys; sys.path.insert(0, 'shared')
from proxies_conf import all_of_kind, load
d = load('proxies.conf')
for c in all_of_kind(d, 'geosites'): print(f'geosite-{c}.json')
for c in all_of_kind(d, 'geoips'):   print(f'geoip-{c}.json')
"@
    } finally { Pop-Location }
    $expected = $expected | Where-Object { $_ }
} catch { Write-Result 'rule-set: list expected' $false -Detail $_ }
if ($expected) {
    $actual = @(Get-ChildItem -Path $RuleSetDir -Filter '*.json' -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Name })
    $extra   = $actual   | Where-Object { $_ -notin $expected }
    $missing = $expected | Where-Object { $_ -notin $actual }
    Write-Result 'rule-set: no stale files'        (-not $extra)   -Detail "extra=$($extra -join ',')"
    Write-Result 'rule-set: all expected present'  (-not $missing) -Detail "missing=$($missing -join ',')"
    $emptyFiles = $expected | Where-Object {
        $p = Join-Path $RuleSetDir $_; (-not (Test-Path $p)) -or (Get-Item $p).Length -eq 0
    }
    Write-Result 'rule-set: all non-empty' (-not $emptyFiles) -Detail "empty=$($emptyFiles -join ',')"
}

Write-Host '=== Verify: log scan ===' -ForegroundColor Cyan
if (Test-Path $SingboxLog) {
    $suspicious = @(Select-String -Path $SingboxLog -Pattern 'WARN|FATAL|panic' -CaseSensitive:$false -ErrorAction SilentlyContinue)
    Write-Result 'log: no WARN/FATAL/panic' ($suspicious.Count -eq 0) -Detail "lines=$($suspicious.Count)"
    if ($suspicious.Count -gt 0) { $suspicious | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow } }
} else {
    Write-Result "log: $SingboxLog exists" $false
}

Write-Output "=== Results: $($script:pass) passed, $($script:fail) failed ==="
if ($script:fail -gt 0) { Write-Output '=== FAIL ==='; exit 1 }
Write-Output '=== PASS ==='
exit 0
