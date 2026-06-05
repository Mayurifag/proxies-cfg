#Requires -Version 7.0
#Requires -PSEdition Core
<#
.SYNOPSIS
    Audit prerequisites + repo state for proxies-cfg on Windows.
#>
. "$PSScriptRoot\common.ps1"
Set-StrictMode -Version Latest

$ok = 0
$fail = 0
function Section($name) { Write-Host "`n== $name ==" }
function Check {
    param([string]$Name, [scriptblock]$Test, [string]$Fix)
    $passed = $false
    try {
        $global:LASTEXITCODE = 0
        $null = & $Test
        $passed = $? -and $LASTEXITCODE -eq 0
    } catch {}
    if ($passed) { Write-Host ('  ok    ' + $Name); $script:ok++ }
    else { Write-Host ('  FAIL  ' + $Name + '   → ' + $Fix); $script:fail++ }
}

Section 'tools'
Check 'jq present'        { $null = Get-Command jq -ErrorAction Stop } 'winget install jqlang.jq'
Check 'gpg present'       { $null = Get-Command gpg -ErrorAction Stop } 'winget install GnuPG.GnuPG'
Check 'git-crypt present' { $null = Get-Command git-crypt -ErrorAction Stop } 'winget install AGWA.git-crypt'
Check 'uv present'        { $null = Get-Command uv -ErrorAction Stop } 'winget install astral-sh.uv'
Check 'python ≥ 3.14'     { & uv run python -c 'import sys; sys.exit(0 if sys.version_info >= (3,14) else 1)'; if ($LASTEXITCODE -ne 0) { throw 'too old' } } 'uv python install 3.14'

Section 'gpg'
Check 'GPG [E] subkey'    { $r = & gpg --list-secret-keys --with-subkey-fingerprints 2>$null; if ($r -match '(?m)^ssb.*\[E\]') { $true } else { throw 'no [E] subkey' } } 'gpg --edit-key <id> → addkey → encrypt-only'

Section 'repo state'
Check 'unlocked: secrets.json' { Get-Content -Raw $SecretsFile | ConvertFrom-Json | Out-Null } 'git-crypt unlock'
Check 'unlocked: proxies.conf' { $a = @((Join-Path $RepoRoot 'shared\proxies_conf.py'), 'tags', $ProxiesConf); Invoke-Python -Arguments $a | Out-Null } 'git-crypt unlock'
Check 'git-crypt status clean' { $s = & git-crypt status 2>&1; if ($s -cmatch 'NOT ENCRYPTED') { throw 'plaintext staged' } } 'git-crypt status -f'

Section 'consistency'
Check 'secrets covers proxies tags' {
    Push-Location $RepoRoot
    try {
        & uv run --quiet python -c @"
import json, sys
sys.path.insert(0, 'shared')
from build_config import _missing_outbounds
from proxies_conf import load
secrets = json.load(open('secrets.json'))
sys.exit(1 if _missing_outbounds(load('proxies.conf'), secrets) else 0)
"@
        if ($LASTEXITCODE -ne 0) { throw 'missing outbound config' }
    } finally { Pop-Location }
} 'add missing <tag>.sub_url or <tag>.uri to secrets.json'

Section 'hooks'
Check 'pre-commit hook installed' { $h = git config --get core.hooksPath 2>$null; if ($h -ne '.githooks') { throw 'not set' } } 'make install-hooks'

Section 'lint'
Check 'ruff check shared/'  { & uv run ruff check (Join-Path $RepoRoot 'shared'); if ($LASTEXITCODE -ne 0) { throw 'lint failed' } } 'uv run ruff check --fix shared/'
Check 'ruff format clean'   { & uv run ruff format --check (Join-Path $RepoRoot 'shared'); if ($LASTEXITCODE -ne 0) { throw 'format diff' } } 'uv run ruff format shared/'

Write-Host ("`ndoctor: $ok ok, $fail fail")
if ($fail -gt 0) { exit 1 }
