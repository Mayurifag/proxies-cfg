#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source linux/common.sh

assert_root "$@"

rules=/etc/ufw/before.rules
[[ -f "$rules" ]] || exit 0

case "${1:-install}" in
install)
	if ! grep -Fq -- '--comment proxies-cfg-docker-https' "$rules"; then
		grep -qx '# End required lines' "$rules" || {
			echo 'Error: unrecognized UFW before.rules layout; no changes made.' >&2
			exit 1
		}
		sed -i '/^# End required lines$/r linux/ufw-docker.rules' "$rules"
	fi
	;;
remove)
	sed -i '/--comment proxies-cfg-docker-https /d' "$rules"
	;;
*)
	echo 'Usage: bash linux/ufw.sh [install|remove]' >&2
	exit 1
	;;
esac

ufw reload
