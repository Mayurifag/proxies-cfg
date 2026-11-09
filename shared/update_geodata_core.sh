#!/bin/bash
# Sourced/exec'd by linux/macos update_geodata.sh. Caller must cd to repo root
# and export GEODATA_DIR + RULE_SET_DIR.
set -euo pipefail
source shared/constants.sh
source shared/github.sh

uv run --quiet python shared/rotate_logs.py "$(dirname "$SINGBOX_LOG")"

mkdir -p "$GEODATA_DIR" "$RULE_SET_DIR"

GEOIP_PATH="$GEODATA_DIR/geoip.dat"
GEOSITE_PATH="$GEODATA_DIR/geosite.dat"

# `find -mtime -1` works on both BSD and GNU find.
fresh() { [[ -s "$1" && -n "$(find "$1" -mtime -1 2>/dev/null)" ]]; }

fetch_if_stale() {
	local url="$1" dst="$2"
	if fresh "$dst"; then return 0; fi
	echo "Downloading $(basename "$dst")..." >&2
	github_raw_download "$url" "$dst.tmp"
	[[ -s "$dst.tmp" ]] || {
		echo "Error: $dst empty" >&2
		exit 1
	}
	mv "$dst.tmp" "$dst"
}

fetch_if_stale "$GEOIP_URL" "$GEOIP_PATH"
fetch_if_stale "$GEOSITE_URL" "$GEOSITE_PATH"

echo "Geodata: $(wc -c <"$GEOIP_PATH") bytes geoip, $(wc -c <"$GEOSITE_PATH") bytes geosite"

uv run --quiet python shared/geo_convert.py "$GEOSITE_PATH" "$GEOIP_PATH" "$RULE_SET_DIR" --from-proxies-conf proxies.conf
