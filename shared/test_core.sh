#!/bin/bash
# Cross-platform integration test core. Caller must `cd` to repo root and
# export: SETUP, TEARDOWN. Optional: CURL_HTTP3, DNS_CHECK_CMD.
set -euo pipefail

source shared/constants.sh

CURL_HTTP3="${CURL_HTTP3:-curl}"
DNS_CHECK_CMD="${DNS_CHECK_CMD:-dig +short checkip.amazonaws.com A | head -1}"

check_ip() { curl -s --max-time 10 "$1" | tr -d '[:space:]'; }
assert_nonempty() {
	[[ -n "$2" ]] || {
		echo "FAIL: $1 empty IP" >&2
		exit 1
	}
	echo "  $1: $2"
}
assert_ne() { [[ "$2" != "$4" ]] || {
	echo "FAIL: $1 ($2) == $3 ($4)" >&2
	exit 1
}; }

bash "$TEARDOWN"

echo '=== Verify: proxy down ==='
DIRECT=$(check_ip "$DIRECT_TEST_URL")
IT=$(check_ip "$PROXY_IT_TEST_URL")
RU=$(check_ip "$PROXY_RU_TEST_URL")
assert_nonempty 'direct (checkip.amazonaws.com)' "$DIRECT"
for pair in "it=$IT" "ru=$RU"; do
	label="${pair%%=*}"
	ip="${pair#*=}"
	if [[ -n "$ip" && "$ip" != "$DIRECT" ]]; then
		echo "FAIL: $label IP ($ip) != direct ($DIRECT) — proxy still routing" >&2
		exit 1
	fi
done
echo "  All checkers agree on real IP: $DIRECT"

uv run --quiet python shared/proxies_conf.py tags proxies.conf >/dev/null || {
	echo 'proxies.conf invalid' >&2
	exit 1
}

echo '=== Setup ==='
bash "$SETUP"

echo '=== Verify: outbounds distinct ==='
DIRECT=$(check_ip "$DIRECT_TEST_URL")
IT=$(check_ip "$PROXY_IT_TEST_URL")
RU=$(check_ip "$PROXY_RU_TEST_URL")
assert_nonempty 'direct (checkip.amazonaws.com)' "$DIRECT"
assert_nonempty 'proxy_it (api.ipify.org)' "$IT"
assert_nonempty 'proxy_ru (ident.me)' "$RU"
assert_ne 'direct' "$DIRECT" 'proxy_it' "$IT"
assert_ne 'direct' "$DIRECT" 'proxy_ru' "$RU"
assert_ne 'proxy_it' "$IT" 'proxy_ru' "$RU"

echo "=== Verify: $PROXY_IPV6_IT_NOVNC_TAG IPv6 routing ==="
IPV6_TEST_URL=$(jq -er --arg tag "$PROXY_IPV6_IT_NOVNC_TAG" '.[$tag].ipv6_test_url' "$SECRETS_FILE")
IPV6_TEST_HOST=$(jq -ern --arg url "$IPV6_TEST_URL" '$url | sub("^https?://"; "") | split("/")[0] | split(":")[0]')
IPV6_TEST_ADDR=$(dig +short AAAA "$IPV6_TEST_HOST" | head -1)
[[ -n "$IPV6_TEST_ADDR" ]] || {
	echo "FAIL: $PROXY_IPV6_IT_NOVNC_TAG IPv6 test host has no AAAA" >&2
	exit 1
}
curl -6 -fsSI --resolve "$IPV6_TEST_HOST:443:[$IPV6_TEST_ADDR]" --max-time 15 "$IPV6_TEST_URL" >/dev/null || {
	echo "FAIL: $PROXY_IPV6_IT_NOVNC_TAG IPv6 test URL unreachable" >&2
	exit 1
}
echo "  $PROXY_IPV6_IT_NOVNC_TAG IPv6 test URL ok"
NOVNC_TEST_URL=$(jq -er --arg tag "$PROXY_IPV6_IT_NOVNC_TAG" '.[$tag].novnc_url' "$SECRETS_FILE")
curl -k -fsS --max-time 15 -o /dev/null "$NOVNC_TEST_URL" || {
	echo "FAIL: $PROXY_IPV6_IT_NOVNC_TAG noVNC unreachable" >&2
	exit 1
}
echo "  $PROXY_IPV6_IT_NOVNC_TAG noVNC ok"

echo '=== Verify: route precedence ==='
SINGBOX_CONFIG=${SINGBOX_CONFIG:-$OS_TAG/runtime/config.json}
read -r POM3_IDX C1V_IDX < <(
	jq -r '
		.route.rules as $rules |
		[
			($rules | to_entries[] | select(.value.domain_suffix?[]? == "pom3.c1vhosting.it" and .value.outbound == $tag) | .key),
			($rules | to_entries[] | select(.value.domain_suffix?[]? == "c1vhosting.it" and .value.outbound == "direct") | .key)
		] | @tsv
	' --arg tag "$PROXY_IPV6_IT_NOVNC_TAG" "$SINGBOX_CONFIG"
)
[[ -n "$POM3_IDX" && -n "$C1V_IDX" ]] || {
	echo "FAIL: missing pom3/$PROXY_IPV6_IT_NOVNC_TAG or c1vhosting/direct rule" >&2
	exit 1
}
((POM3_IDX < C1V_IDX)) || {
	echo "FAIL: bad route order pom3=$POM3_IDX c1vhosting=$C1V_IDX" >&2
	exit 1
}
echo "  pom3.c1vhosting.it -> $PROXY_IPV6_IT_NOVNC_TAG before c1vhosting.it -> direct"

SSH_TEST_CMD=$(jq -er '.ssh_test_command // empty' "$SECRETS_FILE" 2>/dev/null || true)
if [[ -n "$SSH_TEST_CMD" ]]; then
	echo '=== Verify: SSH to deploy host (direct routing) ==='
	if timeout 10 $SSH_TEST_CMD -o BatchMode=yes -o ConnectTimeout=5 true; then
		echo "  $SSH_TEST_CMD ok"
	else
		echo "FAIL: $SSH_TEST_CMD failed (TUN may be eating server IP)" >&2
		exit 1
	fi
fi

echo '=== Verify: QUIC routing ==='
if "$CURL_HTTP3" --http3 -V >/dev/null 2>&1; then
	QUIC_IT=$("$CURL_HTTP3" -s --http3 --max-time 10 "$PROXY_IT_TEST_URL" | tr -d '[:space:]')
	QUIC_RU=$("$CURL_HTTP3" -s --http3 --max-time 10 "$PROXY_RU_TEST_URL" | tr -d '[:space:]')
	assert_nonempty 'api.ipify.org QUIC' "$QUIC_IT"
	assert_nonempty 'ident.me QUIC' "$QUIC_RU"
	[[ "$QUIC_IT" == "$IT" ]] || {
		echo "FAIL: QUIC proxy_it ($QUIC_IT) != TLS ($IT)" >&2
		exit 1
	}
	[[ "$QUIC_RU" == "$RU" ]] || {
		echo "FAIL: QUIC proxy_ru ($QUIC_RU) != TLS ($RU)" >&2
		exit 1
	}
	echo "  QUIC matches TLS for both proxies"
else
	echo "  QUIC tests skipped ($CURL_HTTP3 lacks --http3)"
fi

if [[ -s "$RULE_SET_DIR/geosite-ru-available-only-inside.json" ]]; then
	echo '=== Verify: ru-available-only-inside routing ==='
	PROBE_IP=$(curl -s --max-time 15 "$RU_INSIDE_PROBE_URL" |
		grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)
	if [[ -z "$PROBE_IP" ]]; then
		echo "FAIL: showip.net unreachable" >&2
		exit 1
	fi
	[[ "$PROBE_IP" == "$RU" ]] || {
		echo "FAIL: showip.net ($PROBE_IP) != proxy_ru ($RU)" >&2
		exit 1
	}
	echo "  showip.net (non-.ru) routed via proxy_ru: $PROBE_IP"
fi

echo '=== Verify: DNS sanity ==='
RESOLVED=$(eval "$DNS_CHECK_CMD")
[[ -n "$RESOLVED" ]] || {
	echo "FAIL: DNS sanity check returned empty" >&2
	exit 1
}
echo "  checkip.amazonaws.com -> $RESOLVED"

echo '=== Verify: geosite DNS fake-IP ==='
jq -e '.dns.rules[] | select(.server == "fakeip" and (.rule_set // [] | index("geosite-bestbuy")))' "$SINGBOX_CONFIG" >/dev/null || {
	echo 'FAIL: geosite-bestbuy missing from DNS fake-IP rules' >&2
	exit 1
}
jq -e '.. | strings | select(. == "bestbuy.com")' "$RULE_SET_DIR/geosite-bestbuy.json" >/dev/null || {
	echo 'FAIL: geosite-bestbuy rule-set missing bestbuy.com' >&2
	exit 1
}
GEOSITE_REMOTE=$(curl -sS --connect-timeout 15 --max-time 30 -o /dev/null -w '%{remote_ip}' 'https://www.bestbuy.com/' || true)
[[ "$GEOSITE_REMOTE" == 172.19.1.* || "$GEOSITE_REMOTE" == fc00:* ]] || {
	echo "FAIL: www.bestbuy.com did not resolve to fake-IP: $GEOSITE_REMOTE" >&2
	exit 1
}
echo "  www.bestbuy.com -> $GEOSITE_REMOTE"

echo '=== Verify: rule-set integrity ==='
expected=$(
	uv run --quiet python - <<'PY'
import os, sys
sys.path.insert(0, 'shared')
from proxies_conf import all_of_kind, load
d = load('proxies.conf')
for c in all_of_kind(d, 'geosites'): print(f'geosite-{c}.json')
for c in all_of_kind(d, 'geoips'):   print(f'geoip-{c}.json')
PY
)
actual=$(cd "$RULE_SET_DIR" 2>/dev/null && ls -1 2>/dev/null | sort)
expected_sorted=$(echo "$expected" | sort)
diff_out=$(diff <(echo "$expected_sorted") <(echo "$actual") || true)
[[ -z "$diff_out" ]] || {
	echo "FAIL: rule-set dir mismatch:" >&2
	echo "$diff_out" >&2
	exit 1
}
for f in $expected; do
	[[ -s "$RULE_SET_DIR/$f" ]] || {
		echo "FAIL: $RULE_SET_DIR/$f empty" >&2
		exit 1
	}
done
echo "  $(echo "$expected" | wc -l | tr -d ' ') rule-sets match proxies.conf"

if [[ -n "${SINGBOX_LOG:-}" && -f "$SINGBOX_LOG" ]]; then
	echo '=== Verify: log scan ==='
	suspicious=$(grep -E -i 'WARN|FATAL|panic' "$SINGBOX_LOG" || true)
	[[ -z "$suspicious" ]] || {
		echo "FAIL: log issues:" >&2
		echo "$suspicious" >&2
		exit 1
	}
	echo '  log clean'
fi

echo '=== PASS ==='
