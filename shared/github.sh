#!/bin/bash

github_prepare() {
	local uid entry account home
	github_cli=(gh)
	[[ "$2" == linux* && "$1" -eq 0 ]] || return 0
	uid=$(stat -c %u .) || return 1
	[[ "$uid" != 0 ]] || return 0
	entry=$(getent passwd "$uid") || return 1
	IFS=: read -r account _ _ _ _ home _ <<<"$entry"
	[[ -n "$account" && -n "$home" ]] || return 1
	github_cli=(runuser -u "$account" -- env "HOME=$home" "XDG_RUNTIME_DIR=/run/user/$uid" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" gh)
}

github_authenticated() {
	github_prepare "$EUID" "$OSTYPE" || return 1
	command -v "${github_cli[0]}" >/dev/null 2>&1 || return 1
	GH_TELEMETRY=0 GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 uv run --quiet python -c '
import subprocess
import sys
try:
    subprocess.run(sys.argv[1:], timeout=5, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
except (OSError, subprocess.SubprocessError):
    sys.exit(1)
' "${github_cli[@]}" auth status --active --hostname github.com
}

github_gh() {
	GH_TELEMETRY=0 GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 "${github_cli[@]}" "$@"
}

github_latest_version() {
	local repo="$1" tag
	if github_authenticated &&
		tag=$(GH_TELEMETRY=0 GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 uv run --quiet python -c '
import subprocess
import sys
subprocess.run(sys.argv[1:], timeout=5, check=True)
' "${github_cli[@]}" api --hostname github.com "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null) &&
		[[ "$tag" =~ ^v?[0-9][0-9A-Za-z._+-]*$ ]]; then
		printf '%s\n' "${tag#v}"
		return 0
	fi

	echo '[github] authenticated gh release lookup failed' >&2
	return 1
}

github_release_download() {
	local repo="$1" tag="$2" asset="$3" dst="$4"
	if github_authenticated &&
		github_gh release download "$tag" --repo "github.com/$repo" --pattern "$asset" --output - >"$dst" 2>/dev/null &&
		[[ -s "$dst" ]]; then
		return 0
	fi

	echo '[github] authenticated gh release download failed' >&2
	return 1
}

github_raw_download() {
	local url="$1" dst="$2" owner repo ref path
	if [[ "$url" == https://raw.githubusercontent.com/* ]]; then
		IFS=/ read -r owner repo ref path <<<"${url#https://raw.githubusercontent.com/}"
		if [[ -n "$owner" && -n "$repo" && -n "$ref" && -n "$path" ]] && github_authenticated &&
			github_gh api --hostname github.com -H 'Accept: application/vnd.github.raw+json' "repos/$owner/$repo/contents/$path?ref=$ref" >"$dst" 2>/dev/null &&
			[[ -s "$dst" ]]; then
			return 0
		fi
	fi

	echo '[github] authenticated gh raw download failed' >&2
	return 1
}
