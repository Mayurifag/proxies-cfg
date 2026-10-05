#!/bin/bash
# macOS-specific helpers. Sourced after caller cd's to repo root.

source shared/common.sh
source shared/constants.sh

RUNTIME_DIR=macos/runtime
SINGBOX_DIR="$RUNTIME_DIR/bin"
SINGBOX_BIN="$SINGBOX_DIR/sing-box"
SINGBOX_CONFIG="$RUNTIME_DIR/config.json"
RULE_SET_DIR="$RUNTIME_DIR/rule-sets"
GEODATA_DIR="$RUNTIME_DIR/geodata"
SINGBOX_LOG="$RUNTIME_DIR/singbox.log"
GENERATE_CONFIG="macos/generate_config.sh"
LOCAL_DNS_SERVER="${LOCAL_DNS_SERVER:-$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')}"

LAUNCH_DAEMON_DIR=/Library/LaunchDaemons
LABELS=(com.proxies-cfg.singbox com.proxies-cfg.geodata)

export RULE_SET_DIR GEODATA_DIR SINGBOX_LOG LOCAL_DNS_SERVER

ensure_curl_http3() {
    local candidates=(/opt/homebrew/opt/curl/bin/curl /usr/local/opt/curl/bin/curl curl)
    for c in "${candidates[@]}"; do
        if command -v "$c" >/dev/null 2>&1 && "$c" --http3 -V >/dev/null 2>&1; then
            echo "$c"; return 0
        fi
    done
    if command -v brew >/dev/null 2>&1; then
        brew install curl >&2
        local brewed=/opt/homebrew/opt/curl/bin/curl
        [[ -x "$brewed" ]] || brewed=/usr/local/opt/curl/bin/curl
        [[ -x "$brewed" ]] && echo "$brewed" && return 0
    fi
    echo "Error: no curl with HTTP/3 support found." >&2
    return 1
}

restart_proxy() {
    if [[ $EUID -ne 0 ]]; then elevate_and_run restart_proxy; return $?; fi
    generate_singbox_config
    launchctl kickstart -k system/com.proxies-cfg.singbox
}
