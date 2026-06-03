#!/bin/bash
# Cross-platform constants. Sourced (not executed).

case "$(uname -s)" in
Linux)
	OS_TAG=linux
	SUDO_KEY=sudo_password
	;;
Darwin)
	OS_TAG=macos
	SUDO_KEY=macos_sudo_password
	;;
*)
	OS_TAG=unknown
	SUDO_KEY=sudo_password
	;;
esac
OS_COMMON="$OS_TAG/common.sh"

SINGBOX_REPO="shtorm-7/sing-box-extended"

GEOIP_URL="https://raw.githubusercontent.com/runetfreedom/russia-blocked-geoip/release/geoip.dat"
GEOSITE_URL="https://raw.githubusercontent.com/runetfreedom/russia-blocked-geosite/release/geosite.dat"

DIRECT_TEST_URL="https://checkip.amazonaws.com"
PROXY_IT_TEST_URL="https://api.ipify.org"
PROXY_IPV6_IT_NOVNC_TAG="proxy_ipv6_it_novnc"
PROXY_RU_TEST_URL="https://ident.me"
ALL_TEST_URLS=("$DIRECT_TEST_URL" "$PROXY_IT_TEST_URL" "$PROXY_RU_TEST_URL")

# Non-.ru domain inside geosite-ru-available-only-inside; echoes caller IP.
# Used to verify the rule-set actually drives traffic through proxy_ru.
RU_INSIDE_PROBE_URL="https://showip.net/"

# IPv4 inside the TUN's /30. Must match address in shared/build_config.py base.
TUN_INET=172.19.0.1
