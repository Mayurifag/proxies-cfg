#!/bin/bash
# Audits prerequisites + repo state. Cross-platform (Linux + macOS).
set -uo pipefail
cd "$(dirname "$0")/.."
source shared/common.sh
source shared/constants.sh

ok=0
fail=0
section() { printf '\n== %s ==\n' "$1"; }

check() {
	local name="$1" cmd="$2" fix="$3"
	if eval "$cmd" >/dev/null 2>&1; then
		printf '  ok    %s\n' "$name"
		ok=$((ok + 1))
	else
		printf '  FAIL  %s   → %s\n' "$name" "$fix"
		fail=$((fail + 1))
	fi
}

section 'tools'
check 'jq present' 'command -v jq' 'install jq'
check 'gpg present' 'command -v gpg' 'install gnupg'
check 'git-crypt present' 'command -v git-crypt' 'install git-crypt'
check 'uv present' 'command -v uv' 'curl -LsSf https://astral.sh/uv/install.sh | sh'
check 'python ≥ 3.14' 'uv run python -c "import sys; sys.exit(0 if sys.version_info >= (3,14) else 1)"' 'uv python install 3.14'

section 'gpg'
check 'GPG [E] subkey' 'gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: "\$1==\"ssb\" && \$12 ~ /e/ {found=1} END{exit !found}"' 'gpg --edit-key <id> → addkey → encrypt-only'

section 'repo state'
check 'unlocked: secrets.json' 'uv run --quiet python -c "import json; json.load(open(\"secrets.json\"))"' 'git-crypt unlock'
check 'unlocked: proxies.conf' 'uv run --quiet python shared/proxies_conf.py tags proxies.conf' 'git-crypt unlock'
check 'git-crypt status clean' '! git-crypt status 2>&1 | grep -qF "NOT ENCRYPTED"' 'git-crypt status -f'

section 'consistency'
check 'secrets covers proxies tags' 'uv run --quiet python -c "
import json, sys
sys.path.insert(0, \"shared\")
from build_config import _missing_outbounds
from proxies_conf import load
secrets = json.load(open(\"secrets.json\"))
sys.exit(1 if _missing_outbounds(load(\"proxies.conf\"), secrets) else 0)
"' 'add missing <tag>.sub_url or <tag>.uri to secrets.json'

section 'hooks'
check 'pre-commit hook installed' '[[ "$(git config --get core.hooksPath)" == ".githooks" ]]' 'make install-hooks'

section 'lint'
check 'ruff check shared/' 'uv run ruff check shared/' 'uv run ruff check --fix shared/'
check 'ruff format clean' 'uv run ruff format --check shared/' 'uv run ruff format shared/'

printf '\ndoctor: %d ok, %d fail\n' "$ok" "$fail"
[[ $fail -eq 0 ]]
