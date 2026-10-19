#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source linux/common.sh

assert_root "$@"

systemctl disable --now proxies-cfg-geodata.timer 2>/dev/null || true
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
rm -f "/etc/systemd/system/$SERVICE_NAME.service" \
	/etc/systemd/system/proxies-cfg-geodata.service \
	/etc/systemd/system/proxies-cfg-geodata.timer

systemctl daemon-reload

deadline=$(($(date +%s) + 5))
while (($(date +%s) < deadline)); do
	pgrep -x sing-box >/dev/null || break
	sleep 1
done
pgrep -x sing-box >/dev/null && pkill -KILL -x sing-box 2>/dev/null || true

# Belt-and-suspenders: SIGKILL skips graceful nftables/route cleanup.
nft list table inet sing-box >/dev/null 2>&1 && nft delete table inet sing-box 2>/dev/null || true

bash linux/ufw.sh remove

echo '[teardown] complete'
