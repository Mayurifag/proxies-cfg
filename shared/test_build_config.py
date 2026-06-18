# ruff: noqa: INP001, S101, SLF001

from __future__ import annotations

import unittest

import build_config


class BuildConfigTest(unittest.TestCase):
    def test_missing_outbounds_treats_non_object_secret_as_missing(self) -> None:
        proxies = {"direct": {}, "proxy_it": {}}
        secrets = {"proxy_it": "https://example.invalid/sub"}

        assert build_config._missing_outbounds(proxies, secrets) == ["proxy_it"]

    def test_route_rules_keep_explicit_novnc_domain_before_direct_parent(self) -> None:
        proxies = {
            "direct": {"domains": ["c1vhosting.it"]},
            "proxy_ipv6_it_novnc": {
                "domains": ["pom3.c1vhosting.it"],
            },
        }

        rules = build_config._route_rules(proxies)

        assert rules == [
            {
                "domain_suffix": ["pom3.c1vhosting.it"],
                "outbound": "proxy_ipv6_it_novnc",
            },
            {
                "domain_suffix": ["c1vhosting.it"],
                "outbound": "direct",
            },
        ]

    def test_dns_rejects_unmatched_aaaa_for_dual_stack_direct_sites(self) -> None:
        proxies = {
            "direct": {},
            "proxy_ipv6_it_novnc": {"domains": ["ntc.party", "pom3.c1vhosting.it"]},
        }

        rules = build_config._fakeip_dns_rules(proxies)

        assert rules == [
            {
                "domain_suffix": ["ntc.party", "pom3.c1vhosting.it"],
                "query_type": ["A", "AAAA"],
                "action": "route",
                "server": "fakeip",
            },
            {"query_type": ["AAAA"], "action": "reject"},
        ]

    def test_dns_does_not_fakeip_geosites(self) -> None:
        proxies = {
            "direct": {},
            "proxy_it": {"geosites": ["bestbuy"]},
        }

        rules = build_config._fakeip_dns_rules(proxies)

        assert rules == [{"query_type": ["AAAA"], "action": "reject"}]

    def test_explicit_ipv6_domains_do_not_add_ipv6_catch_all(self) -> None:
        proxies = {
            "direct": {},
            "proxy_ipv6_it_novnc": {"domains": ["ntc.party", "pom3.c1vhosting.it"]},
        }

        rules = build_config._route_rules(proxies)

        assert {"ip_version": 6, "outbound": "proxy_ipv6_it_novnc"} not in rules


if __name__ == "__main__":
    unittest.main()
