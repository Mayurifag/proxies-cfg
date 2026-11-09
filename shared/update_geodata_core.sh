#!/bin/bash
# Sourced/exec'd by linux/macos update_geodata.sh. Caller must cd to repo root
# and export GEODATA_DIR + RULE_SET_DIR.
set -euo pipefail
source shared/constants.sh
source shared/github.sh

uv run --quiet python shared/rotate_logs.py "$(dirname "$SINGBOX_LOG")"

mkdir -p "$GEODATA_DIR" "$RULE_SET_DIR"

ARCHIVE="$GEODATA_DIR/sing-box.zip"
TEMPORARY="$ARCHIVE.tmp"
PROXIES_CONF=${PROXIES_CONF:-proxies.conf}
trap 'rm -f "$TEMPORARY"' EXIT

# `find -mtime -1` works on both BSD and GNU find.
fresh() { [[ -s "$1" && -n "$(find "$1" -mtime -1 2>/dev/null)" ]]; }

if ! fresh "$ARCHIVE"; then
	echo 'Downloading sing-box rule sets...' >&2
	version=$(github_latest_version "$GEODATA_REPO" || true)
	if [[ -n "$version" ]] &&
		github_release_download "$GEODATA_REPO" "$version" sing-box.zip "$TEMPORARY" &&
		[[ -s "$TEMPORARY" ]] &&
		uv run --quiet python -m zipfile -t "$TEMPORARY" >/dev/null &&
		uv run --quiet python shared/extract_rule_sets.py "$TEMPORARY" "$RULE_SET_DIR" "$PROXIES_CONF"; then
		mv "$TEMPORARY" "$ARCHIVE"
		exit 0
	elif [[ -s "$ARCHIVE" ]]; then
		echo 'Geodata update failed; using the cached archive.' >&2
	else
		echo 'Error: geodata download failed and no cached archive exists.' >&2
		exit 1
	fi
fi

uv run --quiet python shared/extract_rule_sets.py "$ARCHIVE" "$RULE_SET_DIR" "$PROXIES_CONF"
