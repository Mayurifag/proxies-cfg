#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

source linux/common.sh

assert_root "$@"

mkdir -p "$RUNTIME_DIR/bin" "$RULE_SET_DIR" "$GEODATA_DIR"

case "$(uname -m)" in
    x86_64)  SINGBOX_ARCH=linux-amd64 ;;
    aarch64) SINGBOX_ARCH=linux-arm64 ;;
    *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
export SINGBOX_ARCH SINGBOX_BIN RUNTIME_DIR

echo "[setup] arch=$SINGBOX_ARCH"
bash shared/install_singbox.sh

echo '[setup] geodata + rule-sets'
bash linux/update_geodata.sh

echo '[setup] build config'
generate_singbox_config

echo '[setup] validate config'
"$SINGBOX_BIN" check -c "$SINGBOX_CONFIG"

echo "[setup] install systemd unit ($SERVICE_NAME)"
SINGBOX_BIN_ABS="$(pwd)/$SINGBOX_BIN"
SINGBOX_CONFIG_ABS="$(pwd)/$SINGBOX_CONFIG"
tee "/etc/systemd/system/$SERVICE_NAME.service" >/dev/null <<EOF
[Unit]
Description=proxies-cfg sing-box-extended TUN proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SINGBOX_BIN_ABS run -c $SINGBOX_CONFIG_ABS
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_DAC_READ_SEARCH
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_DAC_READ_SEARCH
NoNewPrivileges=true
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

tee /etc/systemd/system/proxies-cfg-geodata.service >/dev/null <<EOF
[Unit]
Description=proxies-cfg daily geodata refresh
After=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$(pwd)
ExecStart=/bin/bash linux/update_geodata.sh
EOF

tee /etc/systemd/system/proxies-cfg-geodata.timer >/dev/null <<'EOF'
[Unit]
Description=proxies-cfg daily geodata refresh

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
systemctl enable --now proxies-cfg-geodata.timer

echo '[setup] wait for TUN'
deadline=$(($(date +%s) + 15))
tun_iface=""
while (( $(date +%s) < deadline )); do
    tun_iface=$(ip -o addr show | awk -v ip="$TUN_INET" '$3 == "inet" && $4 ~ ip { print $2; exit }')
    [[ -n "$tun_iface" ]] && break
    sleep 1
done
[[ -n "$tun_iface" ]] || { systemctl status "$SERVICE_NAME" --no-pager >&2; journalctl -u "$SERVICE_NAME" --no-pager -n 50 >&2; echo "FAIL: TUN $TUN_INET not up in 15s" >&2; exit 1; }
echo "[setup] TUN: $tun_iface"

resolvectl flush-caches 2>/dev/null || true

for url in "${ALL_TEST_URLS[@]}"; do
    curl -sS --max-time 10 -o /dev/null "$url" && echo "  prefetch ok: $url" || echo "  prefetch warn: $url"
done

echo "[setup] complete. service=$SERVICE_NAME tun=$tun_iface"
