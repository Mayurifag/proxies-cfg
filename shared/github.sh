#!/bin/bash

github_gh() {
	GH_TELEMETRY=0 GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "$@"
}

github_latest_version() {
	local repo="$1" tag
	if command -v gh >/dev/null 2>&1 &&
		tag=$(GH_TELEMETRY=0 GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 uv run --quiet python -c '
import subprocess
import sys
subprocess.run(sys.argv[1:], timeout=5, check=True)
' gh api --hostname github.com "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null) &&
		[[ "$tag" =~ ^v?[0-9][0-9A-Za-z._+-]*$ ]]; then
		printf '%s\n' "${tag#v}"
		return 0
	fi

	echo '[github] gh unavailable or failed; trying curl' >&2
	tag=$(curl -fsSL --max-time 5 "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null | jq -er '.tag_name') || return 1
	[[ "$tag" =~ ^v?[0-9][0-9A-Za-z._+-]*$ ]] || return 1
	printf '%s\n' "${tag#v}"
}

github_release_download() {
	local repo="$1" tag="$2" asset="$3" dst="$4"
	if command -v gh >/dev/null 2>&1 &&
		github_gh release download "$tag" --repo "github.com/$repo" --pattern "$asset" --output "$dst" --clobber >/dev/null 2>&1 &&
		[[ -s "$dst" ]]; then
		return 0
	fi

	echo '[github] gh unavailable or failed; trying curl' >&2
	curl -fsSL --retry 3 --retry-delay 2 -o "$dst" "https://github.com/$repo/releases/download/$tag/$asset"
}

github_raw_download() {
	local url="$1" dst="$2" owner repo ref path
	if [[ "$url" == https://raw.githubusercontent.com/* ]]; then
		IFS=/ read -r owner repo ref path <<<"${url#https://raw.githubusercontent.com/}"
		if [[ -n "$owner" && -n "$repo" && -n "$ref" && -n "$path" ]] && command -v gh >/dev/null 2>&1 &&
			github_gh api --hostname github.com -H 'Accept: application/vnd.github.raw+json' "repos/$owner/$repo/contents/$path?ref=$ref" >"$dst" 2>/dev/null &&
			[[ -s "$dst" ]]; then
			return 0
		fi
	fi

	echo '[github] gh unavailable or failed; trying curl' >&2
	curl -fsSL --retry 3 --retry-delay 2 -o "$dst" "$url"
}
