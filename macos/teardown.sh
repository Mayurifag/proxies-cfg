#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

source macos/common.sh
assert_root "$@"

for label in "${LABELS[@]}"; do
	if launchctl bootout "system/$label" 2>/dev/null; then
		echo "[teardown] booted out $label"
	fi
	rm -f "$LAUNCH_DAEMON_DIR/$label.plist"
done

resolver="/etc/resolver/$PROXY_IT_IPV6_TEST_HOST"
if [[ -f "$resolver" ]] && grep -qF '# proxies-cfg' "$resolver"; then
	rm -f "$resolver"
fi

pkill -TERM -x sing-box 2>/dev/null || true

deadline=$(($(date +%s) + 10))
while (($(date +%s) < deadline)); do
	pgrep -x sing-box >/dev/null || break
	sleep 1
done
pgrep -x sing-box >/dev/null && pkill -KILL -x sing-box 2>/dev/null || true

deadline=$(($(date +%s) + 5))
while (($(date +%s) < deadline)); do
	ifconfig | grep -qE "inet $TUN_INET" || break
	sleep 1
done

dirty=()
pgrep -x sing-box >/dev/null && dirty+=('sing-box still running')
ifconfig | grep -qE "inet $TUN_INET" && dirty+=("utun with $TUN_INET still present")
for label in "${LABELS[@]}"; do
	[[ -f "$LAUNCH_DAEMON_DIR/$label.plist" ]] && dirty+=("plist $label")
done

if ((${#dirty[@]} == 0)); then
	echo 'Teardown complete.'
	exit 0
fi
printf 'Teardown incomplete:\n'
printf '  - %s\n' "${dirty[@]}"
exit 1
