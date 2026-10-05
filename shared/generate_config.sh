#!/bin/bash
# Print the sing-box config (built from proxies.conf + subscriptions) to stdout.
# Caller must `cd` to repo root and source platform common.sh so $RULE_SET_DIR
# (and optionally $INTERFACE_NAME) are set.
set -euo pipefail

: "${RULE_SET_DIR:?RULE_SET_DIR must be set by caller}"

[[ -f "$SECRETS_FILE" ]] || { echo "Error: $SECRETS_FILE missing — run 'git-crypt unlock'." >&2; exit 1; }

args=("$PROXIES_CONF" "$(pwd)/$RULE_SET_DIR")
[[ -n "${INTERFACE_NAME:-}" ]] && args+=(--interface-name "$INTERFACE_NAME")
[[ -n "${SINGBOX_LOG:-}" ]] && args+=(--log-output "$(pwd)/$SINGBOX_LOG")
[[ -n "${LOCAL_DNS_SERVER:-}" ]] && args+=(--local-dns-server "$LOCAL_DNS_SERVER")

exec uv run --quiet python shared/build_config.py "${args[@]}" < "$SECRETS_FILE"
