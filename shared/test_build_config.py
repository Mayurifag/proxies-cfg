# ruff: noqa: INP001, S101, SLF001

from __future__ import annotations

import unittest
from io import BytesIO
from pathlib import Path
from unittest.mock import patch

import build_config


class BuildConfigTest(unittest.TestCase):
    def test_wireguard_mtu_defaults_to_ipv6_minimum_and_accepts_uri_override(
        self,
    ) -> None:
        uri = "wireguard://unused@192.0.2.1?publickey=unused&address=2001:db8::1/128"
        assert build_config.sub_parse.parse_wireguard(uri, "check")["mtu"] == 1280
        assert (
            build_config.sub_parse.parse_wireguard(uri + "&mtu=1408", "check")["mtu"]
            == 1408
        )

    def test_endpoint_resolution_uses_real_dns_while_fake_ip_is_active(self) -> None:
        response = BytesIO(b'{"Status":0,"Answer":[{"type":1,"data":"192.0.2.10"}]}')
        with patch.object(
            build_config.urllib.request, "urlopen", return_value=response
        ):
            assert build_config._resolve_ipv4("proxy.example") == ["192.0.2.10"]

    def test_fakeip_mappings_persist_in_runtime_directory(self) -> None:
        with patch.object(build_config, "load", return_value={"direct": {}}):
            config = build_config.build("unused", {}, "/runtime/rule-sets")

        assert config["experimental"]["cache_file"] == {
            "enabled": True,
            "path": str(Path("/runtime") / "cache.db"),
            "store_fakeip": True,
        }

    def test_missing_outbounds_treats_non_object_secret_as_missing(self) -> None:
        proxies = {"direct": {}, "proxy_it": {}}
        secrets = {"proxy_it": "https://example.invalid/sub"}

        assert build_config._missing_outbounds(proxies, secrets) == ["proxy_it"]

    def test_wireguard_aaaa_bypasses_nodata_without_disabling_fake_a(self) -> None:
        proxies = {"proxy_ipv6_it_novnc": {"domains": ["ntc.party"]}}
        secrets = {"proxy_ipv6_it_novnc": {"uri": "unused"}}
        with (
            patch.object(build_config, "load", return_value=proxies),
            patch.object(
                build_config,
                "_proxy",
                return_value={"type": "wireguard", "tag": "proxy_ipv6_it_novnc"},
            ),
            patch.object(build_config, "_endpoint_ips", return_value=[]),
        ):
            config = build_config.build("unused", secrets, "/runtime/rule-sets")
        assert config["dns"]["rules"][1] == {
            "domain_suffix": ["ntc.party"],
            "query_type": ["AAAA"],
            "server": "doh-google",
        }
        assert config["dns"]["rules"][-1] == {
            "query_type": ["A"],
            "action": "route",
            "server": "fakeip",
        }
        assert config["route"]["rules"][0] == {
            "inbound": ["proxy_ipv6_it_novnc"],
            "action": "reject",
        }
        assert config["dns"]["rules"][0] == config["route"]["rules"][0]

    def test_route_rules_keep_explicit_novnc_domain_before_direct_parent(self) -> None:
        proxies = {
            "direct": {"domains": ["c1vhosting.it"]},
            "proxy_ipv6_it_novnc": {
                "domains": ["pom3.c1vhosting.it"],
            },
        }

        rules = build_config._route_rules(proxies)

        assert rules[:3] == [
            {
                "domain_suffix": ["pom3.c1vhosting.it"],
                "action": "resolve",
                "server": "doh-google",
                "strategy": "prefer_ipv4",
            },
            {
                "domain_suffix": ["pom3.c1vhosting.it"],
                "outbound": "proxy_ipv6_it_novnc",
            },
            {
                "domain_suffix": ["c1vhosting.it"],
                "outbound": "direct",
            },
        ]

    def test_dns_uses_fake_ipv4_and_returns_nodata_for_aaaa(self) -> None:
        rules = build_config._fakeip_dns_rules()

        assert rules == [
            {
                "query_type": ["AAAA"],
                "action": "predefined",
                "rcode": "NOERROR",
                "answer": [],
            },
            {
                "query_type": ["A"],
                "action": "route",
                "server": "fakeip",
            },
        ]

    def test_explicit_ipv6_domains_do_not_add_ipv6_catch_all(self) -> None:
        proxies = {
            "direct": {},
            "proxy_ipv6_it_novnc": {"domains": ["ntc.party", "pom3.c1vhosting.it"]},
        }

        rules = build_config._route_rules(proxies)

        assert {"ip_version": 6, "outbound": "proxy_ipv6_it_novnc"} not in rules

    def test_resolve_filters_ipv4_before_geoip_and_ipv6_fallback(self) -> None:
        proxies = {
            "direct": {},
            "proxy_ru": {"geosites": ["tld-ru"], "geoips": ["ru"]},
            "proxy_ipv6_it_novnc": {"domains": ["ntc.party"]},
        }

        rules = build_config._route_rules(proxies)

        assert rules[2:] == [
            {"rule_set": ["geosite-tld-ru"], "outbound": "proxy_ru"},
            {"action": "resolve", "server": "doh-google", "strategy": "prefer_ipv4"},
            {
                "ip_cidr": ["0.0.0.0/0"],
                "action": "resolve",
                "server": "doh-google",
                "strategy": "ipv4_only",
            },
            {"rule_set": ["geoip-ru"], "outbound": "proxy_ru"},
            {"ip_cidr": ["::/0"], "outbound": "proxy_ipv6_it_novnc"},
        ]

    def test_no_ipv6_fallback_without_configured_outbound(self) -> None:
        rules = build_config._route_rules({"direct": {}})

        assert not any(rule.get("outbound") == "proxy_ipv6_it_novnc" for rule in rules)

    def test_endpoint_bypass_matches_raw_and_resolved_addresses(self) -> None:
        rules = build_config._route_rules(
            {"proxy_ru": {"geoips": ["ru"]}}, ["192.0.2.1"]
        )

        bypass = {"ip_cidr": ["192.0.2.1"], "outbound": "direct"}
        assert rules[0] == bypass
        assert rules[-2] == bypass
        assert rules[-1] == {"rule_set": ["geoip-ru"], "outbound": "proxy_ru"}

    def test_lan_names_bypass_fake_ip_and_resolve_locally(self) -> None:
        with patch.object(build_config, "load", return_value={"direct": {}}):
            config = build_config.build(
                "unused", {}, "/runtime/rule-sets", local_dns_server="192.0.2.1"
            )

        assert config["dns"]["rules"][0] == {
            "domain_suffix": ["home.arpa", "lan"],
            "server": "local",
        }
        assert config["route"]["rules"][2:4] == [
            {
                "domain_suffix": ["home.arpa", "lan"],
                "action": "resolve",
                "server": "local",
                "strategy": "prefer_ipv4",
            },
            {"domain_suffix": ["home.arpa", "lan"], "outbound": "direct"},
        ]


if __name__ == "__main__":
    unittest.main()
