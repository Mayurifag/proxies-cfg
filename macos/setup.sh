#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

source macos/common.sh

assert_root "$@"

phase() { echo "[$(date '+%H:%M:%S')] [setup] $*" >&2; }

mkdir -p "$RUNTIME_DIR" "$SINGBOX_DIR" "$RULE_SET_DIR" "$GEODATA_DIR"

case "$(uname -m)" in
arm64) SINGBOX_ARCH=darwin-arm64 ;;
x86_64) SINGBOX_ARCH=darwin-amd64 ;;
*)
	echo "Unsupported arch: $(uname -m)" >&2
	exit 1
	;;
esac
export SINGBOX_ARCH SINGBOX_BIN RUNTIME_DIR

phase "arch=$SINGBOX_ARCH"
bash shared/install_singbox.sh

phase 'geodata + rule-sets'
bash macos/update_geodata.sh

phase 'build sing-box config from subscription'
generate_singbox_config

phase 'validate config'
"$SINGBOX_BIN" check -c "$SINGBOX_CONFIG"

phase 'install LaunchDaemons'
REPO_ROOT_ABS="$(pwd)"
for label in "${LABELS[@]}"; do
	src="macos/plists/$label.plist"
	dst="$LAUNCH_DAEMON_DIR/$label.plist"
	launchctl bootout "system/$label" 2>/dev/null || true
	rm -f "$dst"
	sed "s|__REPO_ROOT__|$REPO_ROOT_ABS|g" "$src" >"$dst"
	chown root:wheel "$dst"
	chmod 644 "$dst"
	plutil -lint "$dst" >/dev/null
	launchctl bootstrap system "$dst"
	phase "  installed $label"
done

phase 'wait for utun'
deadline=$(($(date +%s) + 15))
utun=""
while (($(date +%s) < deadline)); do
	utun=$(ifconfig | awk -v ip="$TUN_INET" '
        /^utun[0-9]+: / { iface=$1; sub(/:/, "", iface) }
        $1 == "inet" && $2 == ip { print iface; exit }
    ')
	[[ -n "$utun" ]] && break
	sleep 1
done
[[ -n "$utun" ]] || {
	ifconfig >&2
	launchctl print system/com.proxies-cfg.singbox 2>&1 | head -40 >&2
	echo "FAIL: TUN $TUN_INET not up in 15s" >&2
	exit 1
}
phase "TUN: $utun"

phase 'install DNS resolver overrides'
mkdir -p /etc/resolver
resolver="/etc/resolver/$PROXY_IT_IPV6_TEST_HOST"
if [[ -f "$resolver" ]] && ! grep -qF '# proxies-cfg' "$resolver"; then
	phase "  warn: $resolver exists; leaving unchanged"
else
	{
		printf '# proxies-cfg\n'
		printf 'nameserver %s\n' "$TUN_INET"
	} >"$resolver"
fi

deadline=$(($(date +%s) + 10))
while (($(date +%s) < deadline)); do
	netstat -rn -f inet | awk -v iface="$utun" '$NF == iface { found=1; exit } END { exit !found }' && break
	sleep 1
done

phase 'flush DNS'
dscacheutil -flushcache
killall -HUP mDNSResponder 2>/dev/null || true

phase 'prefetch'
for url in "${ALL_TEST_URLS[@]}"; do
	curl -sS --max-time 10 -o /dev/null "$url" && phase "  prefetch ok: $url" || phase "  prefetch warn: $url"
done

echo "Setup complete. utun=$utun  pid=$(launchctl print system/com.proxies-cfg.singbox | awk '/pid =/ {print $3; exit}')"
