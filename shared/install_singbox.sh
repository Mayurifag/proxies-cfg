#!/bin/bash
# Resolve latest sing-box-extended release, download + extract if not current.
# Caller must `cd` to repo root, source platform common.sh, and export:
#   SINGBOX_ARCH (e.g. linux-amd64, darwin-arm64)
# Offline (GitHub unreachable): reuse existing binary if present, else fail.
# After return: $SINGBOX_BIN exists and is executable.
set -euo pipefail
source shared/constants.sh

: "${SINGBOX_ARCH:?}" "${SINGBOX_BIN:?}" "${RUNTIME_DIR:?}"

extract_dir=$(dirname "$SINGBOX_BIN")
sentinel="$extract_dir/.version"
mkdir -p "$extract_dir" "$RUNTIME_DIR"

resolved=$(curl -fsSL --max-time 5 \
    "https://api.github.com/repos/$SINGBOX_REPO/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' \
    | head -n1 || true)

current=""
[[ -f "$sentinel" ]] && current=$(<"$sentinel")

if [[ -z "$resolved" ]]; then
    if [[ -x "$SINGBOX_BIN" && -n "$current" ]]; then
        echo "[install_singbox] github unreachable; using local $current" >&2
        exit 0
    fi
    echo "[install_singbox] github unreachable and no local binary" >&2
    exit 1
fi

if [[ -x "$SINGBOX_BIN" && "$current" == "$resolved" ]]; then
    echo "[install_singbox] up to date ($resolved)" >&2
    exit 0
fi

if [[ -n "$current" ]]; then
    echo "[install_singbox] updating $current -> $resolved" >&2
else
    echo "[install_singbox] installing $resolved" >&2
fi

rm -rf "${extract_dir:?}"/* "$sentinel"
rm -f "$RUNTIME_DIR"/sing-box-*.tar.gz

url="https://github.com/$SINGBOX_REPO/releases/download/v$resolved/sing-box-$resolved-$SINGBOX_ARCH.tar.gz"
tar_path="$RUNTIME_DIR/sing-box-$resolved-$SINGBOX_ARCH.tar.gz"
echo "[install_singbox] downloading $url" >&2
curl -fsSL --retry 3 --retry-delay 2 -o "$tar_path.tmp" "$url"
mv "$tar_path.tmp" "$tar_path"
/usr/bin/env tar -xzf "$tar_path" -C "$extract_dir" --strip-components=1
echo "$resolved" > "$sentinel"

[[ "$(uname)" == Darwin ]] && xattr -d com.apple.quarantine "$SINGBOX_BIN" 2>/dev/null || true
chmod +x "$SINGBOX_BIN"
