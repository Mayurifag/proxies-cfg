#Requires -Version 7.0
#Requires -PSEdition Core
<#
.SYNOPSIS
    Shared helpers for Windows PS1 scripts (sing-box-extended TUN proxy).
    Dot-source this file; do NOT run it directly.
#>

$Script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Script:RuntimeDir = Join-Path $PSScriptRoot 'runtime'
$Script:SingboxDir = Join-Path $RuntimeDir 'bin'
$Script:SingboxExe = Join-Path $SingboxDir 'sing-box.exe'
$Script:SingboxConfig = Join-Path $RuntimeDir 'config.json'
$Script:SingboxLog = Join-Path $RuntimeDir 'singbox.log'
$Script:RuleSetDir = Join-Path $RuntimeDir 'rule-sets'
$Script:GeodataDir = Join-Path $RuntimeDir 'geodata'
$Script:ProxiesConf = Join-Path $RepoRoot 'proxies.conf'
$Script:SecretsFile = Join-Path $RepoRoot 'secrets.json'
$Script:TaskNameSingbox = 'proxies-cfg-singbox'
$Script:TaskNameGeodata = 'proxies-cfg-geodata'
$Script:TunAdapterName = 'singbox_tun'

function Assert-Unlocked {
    foreach ($f in @($SecretsFile, $ProxiesConf)) {
        if (-not (Test-Path $f)) { continue }
        $magic = [byte[]](Get-Content $f -AsByteStream -TotalCount 10 -ErrorAction SilentlyContinue)
        if (-not ($magic -and $magic.Length -ge 10 -and $magic[0] -eq 0 -and
                  ([System.Text.Encoding]::ASCII.GetString($magic[1..8]) -eq 'GITCRYPT'))) {
            continue
        }
        if (-not (Get-Command git-crypt -ErrorAction SilentlyContinue)) {
            throw "$f is git-crypt-locked and git-crypt is not installed."
        }
        Write-Host "[common] git-crypt locked -> running 'git-crypt unlock'" -ForegroundColor Yellow
        Push-Location $RepoRoot
        try {
            & git-crypt unlock
            $unlockExit = $LASTEXITCODE
        } finally { Pop-Location }
        if ($unlockExit -ne 0) {
            throw "'git-crypt unlock' failed (working tree dirty? gpg agent?)."
        }
        return
    }
}

function Assert-Admin {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error 'Run as Administrator.'
        exit 1
    }
}

function Write-Phase {
    param([string]$Script, [string]$Message, [string]$Color = 'DarkGray')
    Write-Host "[$Script] $Message" -ForegroundColor $Color
}

function Invoke-Python {
    param([Parameter(Mandatory)][string[]]$Arguments)
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        throw 'uv not found. Install via `winget install astral-sh.uv`.'
    }
    $global:LASTEXITCODE = 0
    Push-Location $RepoRoot
    try {
        $output = & uv run --quiet python @Arguments
    } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) {
        throw "Python failed (exit $LASTEXITCODE): $($Arguments -join ' ')"
    }
    return $output
}

function Install-Singbox {
    foreach ($d in $RuntimeDir, $SingboxDir) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    }
    $sentinel = Join-Path $SingboxDir '.version'
    $current  = if (Test-Path $sentinel) { (Get-Content $sentinel -Raw).Trim() } else { '' }

    $resolved = $null
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$SingboxRepo/releases/latest" `
            -TimeoutSec 5 -UseBasicParsing
        $resolved = ($rel.tag_name -replace '^v', '')
    } catch { $resolved = $null }

    if (-not $resolved) {
        if ((Test-Path $SingboxExe) -and $current) {
            Write-Phase 'install_singbox' "github unreachable; using local $current"
            return
        }
        Write-Error 'github unreachable and no local binary'; exit 1
    }

    if ((Test-Path $SingboxExe) -and $current -eq $resolved) {
        Write-Phase 'install_singbox' "up to date ($resolved)"
        return
    }

    if ($current) {
        Write-Phase 'install_singbox' "updating $current -> $resolved"
    } else {
        Write-Phase 'install_singbox' "installing $resolved"
    }

    $zipUrl  = "https://github.com/$SingboxRepo/releases/download/v$resolved/sing-box-$resolved-windows-amd64.zip"
    $zipPath = Join-Path $RuntimeDir "sing-box-$resolved-windows-amd64.zip"
    $zipTmp = "$zipPath.tmp"
    $extractTmp = Join-Path $RuntimeDir "sing-box-$resolved-windows-amd64.extract"

    Remove-Item $zipTmp -Force -ErrorAction SilentlyContinue
    Remove-Item $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Phase 'install_singbox' "downloading $zipUrl"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipTmp -UseBasicParsing
    Move-Item $zipTmp $zipPath -Force
    Expand-Archive -Path $zipPath -DestinationPath $extractTmp -Force
    $installSource = $extractTmp
    $nested = Join-Path $extractTmp "sing-box-$resolved-windows-amd64"
    if (Test-Path (Join-Path $nested 'sing-box.exe')) { $installSource = $nested }
    if (-not (Test-Path (Join-Path $installSource 'sing-box.exe'))) { Write-Error 'sing-box.exe missing after extract'; exit 1 }

    Get-ChildItem $SingboxDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
    Get-ChildItem $installSource -Force | Move-Item -Destination $SingboxDir -Force
    Remove-Item $extractTmp -Recurse -Force
    Get-ChildItem $RuntimeDir -Filter 'sing-box-*.zip' -ErrorAction SilentlyContinue | Remove-Item -Force
    if (-not (Test-Path $SingboxExe)) { Write-Error 'sing-box.exe missing after extract'; exit 1 }
    Set-Content -Path $sentinel -Value $resolved -NoNewline
}

function Build-SingboxConfig {
    if (-not (Test-Path $RuntimeDir)) { New-Item -ItemType Directory -Path $RuntimeDir | Out-Null }
    $json = (& "$PSScriptRoot\generate_config.ps1") -join "`n"
    [System.IO.File]::WriteAllText($SingboxConfig, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Restart-Proxy {
    Build-SingboxConfig
    Stop-ScheduledTask -TaskName $TaskNameSingbox -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $TaskNameSingbox
}

function Format-Domain {
    param([string]$Domain)
    if ($Domain -match '^domain:') { $Domain = $Domain -replace '^domain:', '' }
    $Domain = $Domain -replace '^https?://', ''
    $Domain = ($Domain -split '/')[0]
    return $Domain
}

function Invoke-GitPullIfClean {
    param([string]$Path = $RepoRoot)
    if ($env:NO_GIT) { return }
    Push-Location $Path
    try {
        $branch = & git rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -ne 0) { return }
        $default = & git symbolic-ref refs/remotes/origin/HEAD 2>$null
        if ($LASTEXITCODE -ne 0) { return }
        if ($default) { $default = $default -replace 'refs/remotes/origin/', '' }
        if ($branch -and $default -and $branch -eq $default) {
            & git diff --quiet
            if ($LASTEXITCODE -eq 1) { return }
            if ($LASTEXITCODE -ne 0) { throw "git diff --quiet failed (exit $LASTEXITCODE)" }
            & git diff --cached --quiet
            if ($LASTEXITCODE -eq 1) { return }
            if ($LASTEXITCODE -ne 0) { throw "git diff --cached --quiet failed (exit $LASTEXITCODE)" }
            $unpushed = & git log "origin/${branch}..HEAD" --oneline 2>$null
            if ($LASTEXITCODE -ne 0) { return }
            if (-not $unpushed) {
                Write-Host 'Pulling latest changes...'
                & git pull --ff-only
                if ($LASTEXITCODE -ne 0) { throw "git pull --ff-only failed (exit $LASTEXITCODE)" }
            }
        }
    } finally { Pop-Location }
}

function Invoke-GitCommitAndPush {
    param([string]$CommitMessage, [string]$Path = $RepoRoot)
    if ($env:NO_GIT) { return }
    Push-Location $Path
    try {
        & git diff --quiet HEAD -- proxies.conf
        $diffExit = $LASTEXITCODE
        if ($diffExit -eq 0) { return }
        if ($diffExit -ne 1) { throw "git diff HEAD -- proxies.conf failed (exit $diffExit)" }

        & git add proxies.conf
        if ($LASTEXITCODE -ne 0) { throw "git add proxies.conf failed (exit $LASTEXITCODE)" }
        & git commit -m $CommitMessage -- proxies.conf
        if ($LASTEXITCODE -ne 0) { throw "git commit failed (exit $LASTEXITCODE)" }
        & git push
        if ($LASTEXITCODE -ne 0) { throw "git push failed (exit $LASTEXITCODE)" }
        Write-Host 'Changes committed and pushed.'
    } finally { Pop-Location }
}

function Test-Outbound {
    param([string]$Url)
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15
        return $resp.Content.Trim()
    } catch {
        return $null
    }
}

Assert-Unlocked
