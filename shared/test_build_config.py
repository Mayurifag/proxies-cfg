# ruff: noqa: INP001, S101, SLF001

from __future__ import annotations

import unittest

import build_config


class BuildConfigTest(unittest.TestCase):
    def test_missing_outbounds_treats_non_object_secret_as_missing(self) -> None:
        proxies = {"direct": {}, "proxy_it": {}}
        secrets = {"proxy_it": "https://example.invalid/sub"}

        assert build_config._missing_outbounds(proxies, secrets) == ["proxy_it"]

    def test_route_rules_keep_specific_ipv6_override_before_direct_parent(self) -> None:
        proxies = {
            "direct": {"domains": ["c1vhosting.it"]},
            "proxy_ipv6_it_novnc": {
                "domains": ["pom3.c1vhosting.it"],
                "ip_versions": ["6"],
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
                "ip_version": 4,
            },
            {"ip_version": 6, "outbound": "proxy_ipv6_it_novnc"},
        ]


if __name__ == "__main__":
    unittest.main()
