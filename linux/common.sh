#!/bin/bash
# Linux-specific helpers. Sourced after caller cd's to repo root.

source shared/common.sh
source shared/constants.sh

RUNTIME_DIR=linux/runtime
SINGBOX_BIN="$RUNTIME_DIR/bin/sing-box"
SINGBOX_CONFIG="$RUNTIME_DIR/config.json"
SINGBOX_LOG="$RUNTIME_DIR/singbox.log"
RULE_SET_DIR="$RUNTIME_DIR/rule-sets"
GEODATA_DIR="$RUNTIME_DIR/geodata"
GENERATE_CONFIG="linux/generate_config.sh"
LOCAL_DNS_SERVER="${LOCAL_DNS_SERVER:-$(ip route show default 2>/dev/null | awk '$1 == "default" && $3 != "" {print $3; exit}')}"

SERVICE_NAME=proxies-cfg-singbox

export RULE_SET_DIR GEODATA_DIR SINGBOX_LOG LOCAL_DNS_SERVER

restart_proxy() {
    if [[ $EUID -ne 0 ]]; then elevate_and_run restart_proxy; return $?; fi
    generate_singbox_config
    systemctl restart "$SERVICE_NAME"
}
