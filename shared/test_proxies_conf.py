# ruff: noqa: INP001, S101

from __future__ import annotations

import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path

import proxies_conf


class ProxiesConfTest(unittest.TestCase):
    def test_add_geosite_creates_sorted_geosite_section(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "proxies.conf"
            path.write_text("[proxy_it.domains]\nexample.com\n", encoding="utf-8")

            with redirect_stdout(StringIO()):
                assert (
                    proxies_conf.add_geosite(str(path), "proxy_it", "geosite:Booking")
                    == 0
                )

            assert path.read_text(encoding="utf-8") == (
                "[proxy_it.domains]\nexample.com\n\n[proxy_it.geosites]\nbooking\n"
            )


if __name__ == "__main__":
    unittest.main()
