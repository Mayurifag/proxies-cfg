#!/bin/bash
# Shared CI driver. First arg = OS label, rest = shell script paths to syntax-check.
# Detects whether the repo is git-crypt-unlocked and conditionally runs steps that
# need plaintext proxies.conf / secrets.json.

is_locked() {
    # `\0GITCRYPT\0` magic at start = locked clone (working tree is raw blob).
    # Bash strips embedded nulls in argv, so match the plain "GITCRYPT" substring.
    head -c20 proxies.conf 2>/dev/null | grep -aqF GITCRYPT
}

ci_core() {
    local label="$1"; shift
    for f in "$@"; do bash -n "$f"; done

    command -v uv >/dev/null || { echo 'Error: uv required (https://astral.sh/uv).' >&2; exit 1; }
    uv run ruff check shared/
    uv run ruff format --check shared/
    uv run --quiet python -m unittest discover -s shared -p 'test_*.py'

    if is_locked; then
        echo "[$label] proxies.conf locked — skipping plaintext-dependent checks"
        return 0
    fi

    uv run --quiet python shared/proxies_conf.py tags proxies.conf >/dev/null

    if command -v git-crypt >/dev/null && [[ -d .git-crypt ]]; then
        if git-crypt status 2>&1 | grep -qF 'NOT ENCRYPTED'; then
            echo "[$label] ERROR: tracked file marked for encryption is staged plaintext." >&2
            echo "Run 'git-crypt status -f' to re-stage encrypted, then retry." >&2
            return 1
        fi
    fi
}
