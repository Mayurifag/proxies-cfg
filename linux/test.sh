#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source linux/common.sh

SETUP=linux/setup.sh
TEARDOWN=linux/teardown.sh
export SETUP TEARDOWN RULE_SET_DIR SINGBOX_LOG
exec bash shared/test_core.sh
