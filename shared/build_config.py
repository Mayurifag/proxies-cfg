#!/usr/bin/env python3
"""Assemble a sing-box-extended config from proxies.conf + subscription URLs.

Usage:
    cat secrets.json | python3 build_config.py <proxies_conf> <rule_set_dir> \
        [--interface-name NAME] [--log-output PATH]

Reads proxies.conf for routing source-of-truth, expands rule_set + route.rules,
fetches each non-direct `<tag>.sub_url` or parses `<tag>.uri` from the secrets
dict (read from stdin), and appends the resulting outbounds/endpoints.
Sub fetch failure is fatal. The reserved tag `direct` routes via the built-in
direct outbound and needs no sub_url.

Secrets come via stdin so multi-line JSON survives PowerShell 5.1 native
arg passing (which mangles arg-borne quotes).

Static base config (log/dns/inbounds/sniff+hijack rules/final/etc.) is inlined
below — single source of truth. `--interface-name` pins the TUN adapter name
(Windows uses `singbox_tun` so teardown can find it; other OSes auto-name).
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import socket
import sys
import urllib.parse
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sub_parse
from proxies_conf import all_of_kind, load

# auto_redirect uses nftables — Linux-only. Other platforms ignore the flag's
# routing hop and break TCP forwarding (verified on Linux: without it, kernel
# binds outbound sockets to the TUN address and packets never reach sing-box).
_AUTO_REDIRECT = sys.platform == "linux"


def _base_config(log_output: str | None = None) -> dict:
    log = {"level": "warn", "timestamp": True}
    if log_output:
        log["output"] = log_output
    tun = {
        "type": "tun",
        "tag": "tun-in",
        "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
        "mtu": 1500,
        "auto_route": True,
        "strict_route": True,
        "stack": "mixed",
    }
    if _AUTO_REDIRECT:
        tun["auto_redirect"] = True
    return {
        "log": log,
        "dns": {
            "servers": [
                {
                    "type": "fakeip",
                    "tag": "fakeip",
                    "inet4_range": "172.19.1.0/24",
                    "inet6_range": "fc00::/18",
                },
                {"type": "https", "tag": "doh-cf", "server": "1.1.1.1"},
                {"type": "https", "tag": "doh-google", "server": "8.8.8.8"},
            ],
            "rules": [],
            "final": "doh-cf",
            "strategy": "prefer_ipv4",
        },
        "inbounds": [tun],
        "outbounds": [{"type": "direct", "tag": "direct"}],
        "route": {
            "rule_set": [],
            "rules": [
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
            ],
            "final": "direct",
            "auto_detect_interface": True,
            "default_domain_resolver": "doh-cf",
        },
    }


def _geo_tags(kinds: dict) -> list[str]:
    return [f"geosite-{c}" for c in sorted(set(kinds.get("geosites", [])))] + [
        f"geoip-{c}" for c in sorted(set(kinds.get("geoips", [])))
    ]


def _missing_outbounds(proxies: dict, secrets: dict) -> list[str]:
    missing = []
    for t in proxies:
        if t == "direct":
            continue
        entry = secrets.get(t)
        if not isinstance(entry, dict) or not (
            entry.get("sub_url") or entry.get("uri")
        ):
            missing.append(t)
    return missing


def _proxy(entry: dict, tag: str) -> dict:
    if uri := entry.get("uri"):
        return sub_parse.parse_uri(uri, tag)
    return sub_parse.fetch_outbound(entry["sub_url"], tag)


def _resolve_ipv4(host: str) -> list[str]:
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        return [host]
    try:
        info = socket.getaddrinfo(host, None, socket.AF_INET)
    except OSError as e:
        msg = f"failed to resolve {host!r}: {e}"
        raise SystemExit(msg) from e
    return sorted({str(entry[4][0]) for entry in info})


def _server_hosts(proxy: dict[str, Any]) -> list[str]:
    hosts = []
    if server := proxy.get("server"):
        hosts.append(str(server))
    hosts.extend(
        str(server)
        for peer in proxy.get("peers", [])
        if (server := peer.get("address"))
    )
    return hosts


def _endpoint_ips(
    secrets: dict, proxies: dict, parsed: list[dict[str, Any]]
) -> list[str]:
    # Pin proxy server + panel IPs to direct so raw-IP connections (SSH,
    # deploy scripts) bypass TUN even when the IP would otherwise match
    # a geoip rule the proxy belongs to.
    hosts: set[str] = set()
    for tag in proxies:
        if tag == "direct":
            continue
        if sub_url := secrets[tag].get("sub_url"):
            host = urllib.parse.urlparse(sub_url).hostname
            if host:
                hosts.add(host)
    for proxy in parsed:
        hosts.update(_server_hosts(proxy))
    ips: set[str] = set()
    for h in hosts:
        ips.update(_resolve_ipv4(h))
    return sorted(ips)


def _route_rules(proxies: dict) -> list[dict]:
    # Prefer specific domain suffixes before broader ones, then broad routing.
    direct_ipv4_only = any(
        tag != "direct" and "6" in kinds.get("ip_versions", [])
        for tag, kinds in proxies.items()
    )
    domain_rules: list[tuple[str, str, int | None]] = []
    protocol_rules: list[dict] = []
    broad_proxy_rules: list[dict] = []

    for tag in sorted(proxies, key=lambda t: (t != "direct", t)):
        kinds = proxies[tag]

        domains = sorted(set(kinds.get("domains", [])))
        ip_version = 4 if tag == "direct" and direct_ipv4_only else None
        domain_rules.extend((domain, tag, ip_version) for domain in domains)
        protocols = sorted(set(kinds.get("protocols", [])))
        if protocols:
            protocol_rules.append({"protocol": protocols, "outbound": tag})
        for ip_version in sorted(set(kinds.get("ip_versions", []))):
            if ip_version not in {"4", "6"}:
                msg = f"invalid ip_version for {tag}: {ip_version!r}"
                raise SystemExit(msg)
            broad_proxy_rules.append({"ip_version": int(ip_version), "outbound": tag})
        rs = _geo_tags(kinds)
        if rs:
            broad_proxy_rules.append({"rule_set": rs, "outbound": tag})

    domain_rules = sorted(
        domain_rules,
        key=lambda item: (
            -len(item[0].split(".")),
            -len(item[0]),
            item[1] != "direct",
            item,
        ),
    )
    domain_route_rules = []
    for domain, tag, ip_version in domain_rules:
        rule = {"domain_suffix": [domain], "outbound": tag}
        if ip_version:
            rule["ip_version"] = ip_version
        domain_route_rules.append(rule)
    return domain_route_rules + protocol_rules + broad_proxy_rules


def _fakeip_dns_rules(proxies: dict) -> list[dict]:
    domains = sorted(
        {
            d
            for tag, kinds in proxies.items()
            if tag != "direct"
            for d in kinds.get("domains", [])
        },
    )
    rule_sets = sorted(
        {
            f"geosite-{geosite}"
            for tag, kinds in proxies.items()
            if tag != "direct"
            for geosite in kinds.get("geosites", [])
        },
    )
    rules = []
    if domains:
        rules.append({
            "domain_suffix": domains,
            "query_type": ["A", "AAAA"],
            "action": "route",
            "server": "fakeip",
        })
    if rule_sets:
        rules.append({
            "rule_set": rule_sets,
            "query_type": ["A", "AAAA"],
            "action": "route",
            "server": "fakeip",
        })
    rules.append({"query_type": ["AAAA"], "action": "reject"})
    return rules


def build(
    proxies_path: str,
    secrets: dict,
    rule_set_dir: str,
    interface_name: str | None = None,
    log_output: str | None = None,
) -> dict:
    cfg = _base_config(log_output)
    if interface_name:
        cfg["inbounds"][0]["interface_name"] = interface_name

    proxies = load(proxies_path)
    cfg["dns"]["rules"] = _fakeip_dns_rules(proxies)

    missing = _missing_outbounds(proxies, secrets)
    if missing:
        msg = f"secrets.json missing sub_url/uri for proxies.conf tag(s): {missing}"
        raise SystemExit(msg)

    all_tags = [f"geosite-{c}" for c in all_of_kind(proxies, "geosites")] + [
        f"geoip-{c}" for c in all_of_kind(proxies, "geoips")
    ]
    cfg["route"]["rule_set"] = [
        {
            "type": "local",
            "tag": t,
            "format": "source",
            "path": f"{rule_set_dir}/{t}.json",
        }
        for t in sorted(all_tags)
    ]

    parsed = [_proxy(secrets[tag], tag) for tag in sorted(proxies) if tag != "direct"]
    endpoint_ips = _endpoint_ips(secrets, proxies, parsed)
    if endpoint_ips:
        cfg["route"]["rules"].append({"ip_cidr": endpoint_ips, "outbound": "direct"})
    cfg["route"]["rules"].extend(_route_rules(proxies))
    endpoints = [proxy for proxy in parsed if proxy["type"] == "wireguard"]
    outbounds = [proxy for proxy in parsed if proxy["type"] != "wireguard"]
    if endpoints:
        cfg["endpoints"] = endpoints
    cfg["outbounds"].extend(outbounds)

    return cfg


def main() -> int:
    p = argparse.ArgumentParser(description="Reads secrets JSON from stdin.")
    p.add_argument("proxies_conf")
    p.add_argument("rule_set_dir")
    p.add_argument("--interface-name", default=None)
    p.add_argument("--log-output", default=None)
    args = p.parse_args()
    secrets = json.load(sys.stdin)
    cfg = build(
        args.proxies_conf,
        secrets,
        args.rule_set_dir,
        args.interface_name,
        args.log_output,
    )
    json.dump(cfg, sys.stdout, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
