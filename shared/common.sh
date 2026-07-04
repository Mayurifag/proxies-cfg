#!/bin/bash
# Sourced by every bash script. Caller must `cd` to the repo root first.

PROXIES_CONF=proxies.conf
SECRETS_FILE=secrets.json
export PROXIES_CONF SECRETS_FILE

ensure_unlocked() {
	local f
	for f in "$SECRETS_FILE" "$PROXIES_CONF"; do
		[[ -f "$f" ]] || continue
		# \0GITCRYPT\0 magic = 10 bytes. Bash strips embedded nulls,
		# so match the printable middle via grep -aF.
		head -c10 "$f" 2>/dev/null | grep -aqF GITCRYPT || continue
		command -v git-crypt >/dev/null || {
			echo "Error: $f is git-crypt-locked and git-crypt is not installed." >&2
			exit 1
		}
		echo "[common] git-crypt locked → running 'git-crypt unlock'" >&2
		git-crypt unlock || {
			echo "Error: 'git-crypt unlock' failed (working tree dirty? gpg agent?)." >&2
			exit 1
		}
		return 0
	done
}

# Skip under sudo re-exec: user side already unlocked, and the gpg-agent
# socket is not reliably available to root.
[[ $EUID -eq 0 ]] || ensure_unlocked

format_domain() {
	local d="$1"
	d="${d#domain:}"
	d="${d#http://}"
	d="${d#https://}"
	echo "${d%%/*}"
}

read_secret() {
	local key="$1"
	[[ -f "$SECRETS_FILE" ]] || {
		echo "Error: $SECRETS_FILE missing — run 'git-crypt unlock'." >&2
		exit 1
	}
	command -v jq >/dev/null || {
		echo 'Error: jq required.' >&2
		exit 1
	}
	jq -er --arg k "$key" '.[$k]' "$SECRETS_FILE"
}

assert_root() {
	if [[ $EUID -ne 0 ]]; then
		: "${OS_TAG:?}" "${SUDO_KEY:?}"
		echo "[$OS_TAG] re-exec under sudo (using $SUDO_KEY from $SECRETS_FILE)" >&2
		local pw script
		pw=$(read_secret "$SUDO_KEY")
		script="$(pwd)/$0"
		printf '%s\n' "$pw" | sudo -S -k -p '' env "PATH=$PATH" bash "$script" "$@"
		exit $?
	fi
}

elevate_and_run() {
	: "${SUDO_KEY:?}" "${OS_COMMON:?}"
	local pw fn
	fn="$1"
	[[ "$fn" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
		echo "Error: invalid function name: $fn" >&2
		exit 1
	}
	pw=$(read_secret "$SUDO_KEY")
	printf '%s\n' "$pw" | sudo -S -k -p '' env "PATH=$PATH" "REPO_ROOT=$(pwd)" "OS_COMMON=$OS_COMMON" "FUNC=$fn" bash -c 'cd "$REPO_ROOT" && source "$OS_COMMON" && "$FUNC"'
}

generate_singbox_config() {
	mkdir -p "$RUNTIME_DIR"
	bash "$GENERATE_CONFIG" >"$SINGBOX_CONFIG"
}

refresh_rule_sets() {
	: "${GEODATA_DIR:?}" "${RULE_SET_DIR:?}"
	[[ -s "$GEODATA_DIR/geosite.dat" && -s "$GEODATA_DIR/geoip.dat" ]] || return 0
	mkdir -p "$RULE_SET_DIR"
	uv run --quiet python shared/geo_convert.py "$GEODATA_DIR/geosite.dat" "$GEODATA_DIR/geoip.dat" "$RULE_SET_DIR" --from-proxies-conf "$PROXIES_CONF"
}

git_pull_if_clean() {
	[[ -n "${NO_GIT:-}" ]] && return 0
	local branch default unpushed
	branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
	default=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || return 0
	if [[ "$branch" == "$default" ]]; then
		git diff --quiet || return 0
		git diff --cached --quiet || return 0
		unpushed=$(git log "origin/$branch..HEAD" --oneline 2>/dev/null) || true
		[[ -z "$unpushed" ]] && git pull --ff-only
	fi
}

git_commit_and_push() {
	[[ -n "${NO_GIT:-}" ]] && return 0
	if ! git diff --quiet HEAD -- "$PROXIES_CONF"; then
		git add "$PROXIES_CONF"
		git commit -m "$1" -- "$PROXIES_CONF"
		git push
	fi
}
