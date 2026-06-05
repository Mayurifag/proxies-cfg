#Requires -Version 7.0
#Requires -PSEdition Core
<#
.SYNOPSIS
    Lightweight CI for Windows: PowerShell parser + JSON lint.
.DESCRIPTION
    Heavy e2e lives in `make test` and requires admin + network.
    Mirrors macos/ci.sh.
#>
. "$PSScriptRoot\common.ps1"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failed = 0

foreach ($f in Get-ChildItem -Path (Join-Path $RepoRoot 'windows'), (Join-Path $RepoRoot 'shared') -Filter '*.ps1' -File) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        Write-Host "PARSE FAIL: $($f.FullName)" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        $failed++
    }
}

foreach ($j in Get-ChildItem -Path $RepoRoot -Filter '*.json' -File -Recurse |
        Where-Object { $_.FullName -notmatch '\\(\.git|v2rayn|runtime|node_modules)\\' }) {
    try {
        Get-Content $j.FullName -Raw | ConvertFrom-Json | Out-Null
    } catch {
        Write-Host "JSON FAIL: $($j.FullName) - $_" -ForegroundColor Red
        $failed++
    }
}

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Error 'uv required (https://astral.sh/uv).'
    exit 1
}
& uv run ruff check (Join-Path $RepoRoot 'shared')
if ($LASTEXITCODE -ne 0) { $failed++ }
& uv run ruff format --check (Join-Path $RepoRoot 'shared')
if ($LASTEXITCODE -ne 0) { $failed++ }

$locked = $false
if (Test-Path $ProxiesConf) {
    $magic = [byte[]](Get-Content $ProxiesConf -AsByteStream -TotalCount 9 -ErrorAction SilentlyContinue)
    if ($magic -and $magic.Length -ge 9 -and $magic[0] -eq 0 -and
        ([System.Text.Encoding]::ASCII.GetString($magic[1..8]) -eq 'GITCRYPT')) {
        $locked = $true
    }
}

if (-not $locked) {
    $tagsArgs = @((Join-Path $RepoRoot 'shared\proxies_conf.py'), 'tags', $ProxiesConf)
    try {
        Invoke-Python -Arguments $tagsArgs | Out-Null
    } catch {
        Write-Host "PROXIES.CONF FAIL: $_" -ForegroundColor Red
        $failed++
    }

    if (Get-Command git-crypt -ErrorAction SilentlyContinue) {
        $crypt = & git-crypt status 2>&1
        if ($crypt -cmatch 'NOT ENCRYPTED') {
            Write-Host "GIT-CRYPT FAIL: tracked file is staged plaintext. Run 'git-crypt status -f'." -ForegroundColor Red
            $failed++
        }
    }
} else {
    Write-Host '[windows] proxies.conf locked — skipping plaintext-dependent checks'
}

if ($failed -gt 0) {
    Write-Error "windows ci: $failed file(s) failed"
    exit 1
}

Write-Output 'windows ci: PowerShell parse + JSON + ruff + git-crypt pass'
