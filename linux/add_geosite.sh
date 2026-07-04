#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source linux/common.sh
RESTART_HOOK=restart_proxy
source shared/add_geosite.sh "$@"
