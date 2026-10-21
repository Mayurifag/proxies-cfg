#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

source macos/common.sh

CURL_HTTP3="$(ensure_curl_http3)"
DNS_CHECK_CMD='dscacheutil -q host -a name checkip.amazonaws.com | awk "/^ip_address:/ {print \$2; exit}"'
SETUP=macos/setup.sh
TEARDOWN=macos/teardown.sh
PROXY_WAS_RUNNING=0
launchctl print system/com.proxies-cfg.singbox 2>/dev/null | grep -q 'state = running' && PROXY_WAS_RUNNING=1

export CURL_HTTP3 DNS_CHECK_CMD SETUP TEARDOWN RULE_SET_DIR SINGBOX_LOG PROXY_WAS_RUNNING
exec bash shared/test_core.sh
