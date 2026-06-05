#Requires -Version 7.0
#Requires -PSEdition Core
#Requires -RunAsAdministrator
param([switch]$Boot)
. "$PSScriptRoot\common.ps1"
. (Join-Path $PSScriptRoot '..\shared\constants.ps1')
<#
.SYNOPSIS
    Set up sing-box-extended TUN proxy on Windows.
.DESCRIPTION
    Downloads sing-box-extended, builds config from subscription URLs, registers
    a Scheduled Task that runs sing-box.exe at logon, waits for the WinTun
    adapter to come up. Idempotent: safe to re-run.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Assert-Admin

foreach ($d in $RuntimeDir, $SingboxDir, $RuleSetDir, $GeodataDir) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

Start-Transcript -Path (Join-Path $RuntimeDir 'setup.log') -Append | Out-Null

if ($Boot) {
    Start-Sleep -Seconds 15
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue) { break }
        Start-Sleep -Seconds 3
    }
}

Write-Phase 'setup' 'Phase 1: ensure sing-box-extended binary'
Install-Singbox

Write-Phase 'setup' 'Phase 2: geodata + rule-sets'
& "$PSScriptRoot\update_geodata.ps1"
if ($LASTEXITCODE -ne 0) { Write-Error 'update_geodata.ps1 failed'; exit 1 }

Write-Phase 'setup' 'Phase 3: build sing-box config from subscriptions'
Build-SingboxConfig

Write-Phase 'setup' 'Phase 4: validate config'
& $SingboxExe check -c $SingboxConfig
if ($LASTEXITCODE -ne 0) { Write-Error 'sing-box check failed'; exit 1 }

Write-Phase 'setup' 'Phase 5: stop existing process if any'
Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Phase 'setup' 'Phase 6: register Scheduled Tasks'
$settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -RunLevel Highest
$common = @{ Settings = $settings; Principal = $principal; Force = $true }

$singboxAction  = New-ScheduledTaskAction -Execute $SingboxExe -Argument "run -c `"$SingboxConfig`"" -WorkingDirectory $RuntimeDir
$singboxTrigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName $TaskNameSingbox -Action $singboxAction -Trigger $singboxTrigger @common | Out-Null

$geoExe = (Get-Command pwsh -ErrorAction Stop).Source
$geoArgs = "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSScriptRoot\update_geodata.ps1`""
$geoAction = New-ScheduledTaskAction -Execute $geoExe -Argument $geoArgs
$geoTrigger = New-ScheduledTaskTrigger -Daily -At '03:00'
Register-ScheduledTask -TaskName $TaskNameGeodata -Action $geoAction -Trigger $geoTrigger @common | Out-Null

Write-Phase 'setup' 'Phase 7: start sing-box task'
Start-ScheduledTask -TaskName $TaskNameSingbox

Write-Phase 'setup' 'Phase 8: wait for TUN adapter'
$adapter = $null
$restarts = 0
for ($i = 0; $i -lt 60; $i++) {
    $adapter = Get-NetAdapter -Name $TunAdapterName -ErrorAction SilentlyContinue
    if ($adapter -and $adapter.Status -eq 'Up') { break }
    $task = Get-ScheduledTask -TaskName $TaskNameSingbox -ErrorAction SilentlyContinue
    if ($task -and $task.State -ne 'Running' -and $restarts -lt 2) {
        $restarts++
        Start-ScheduledTask -TaskName $TaskNameSingbox
    }
    Start-Sleep -Seconds 1
}
if (-not $adapter -or $adapter.Status -ne 'Up') {
    $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskNameSingbox -ErrorAction SilentlyContinue
    if ($taskInfo) { Write-Host "[setup] $TaskNameSingbox last result: $($taskInfo.LastTaskResult)" -ForegroundColor Yellow }
    Write-Error 'TUN adapter not up within 60s'
    Get-NetAdapter | Select-Object Name, InterfaceDescription, Status | Format-Table | Out-String | Write-Host
    exit 1
}

Write-Phase 'setup' 'Phase 9: wait for default route via TUN'
$routeFound = $false
for ($i = 0; $i -lt 50; $i++) {
    $route = Get-NetRoute -InterfaceAlias $TunAdapterName -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
    if ($route) { $routeFound = $true; break }
    Start-Sleep -Milliseconds 200
}
if (-not $routeFound) {
    Write-Host '[setup] WARNING: default route not seen after 10s' -ForegroundColor Yellow
}

Write-Phase 'setup' 'Phase 10: flush DNS + IP cache'
ipconfig /flushdns | Out-Null
netsh interface ip delete destinationcache 2>&1 | Out-Null

Write-Phase 'setup' 'Phase 11: prefetch'
foreach ($url in $AllTestUrls) {
    try { $null = Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing }
    catch { Write-Host "[setup] prefetch warn: $url" -ForegroundColor Yellow }
}

Write-Output 'Setup complete.'
Write-Output "  TUN adapter : $($adapter.Name) [$($adapter.InterfaceDescription)] - $($adapter.Status)"
Write-Output "  Tasks: $TaskNameSingbox, $TaskNameGeodata"
