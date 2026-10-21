#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source linux/common.sh

SETUP=linux/setup.sh
TEARDOWN=linux/teardown.sh
PROXY_WAS_RUNNING=0
systemctl is-active --quiet "$SERVICE_NAME" && PROXY_WAS_RUNNING=1
export SETUP TEARDOWN RULE_SET_DIR SINGBOX_LOG PROXY_WAS_RUNNING
exec bash shared/test_core.sh
