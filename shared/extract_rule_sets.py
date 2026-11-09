#!/usr/bin/env python3
"""Extract the configured sing-box rule sets from the upstream release."""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path
from zipfile import ZipFile

from proxies_conf import all_of_kind, load


def extract(archive: Path, destination: Path, config: Path) -> None:
    proxies = load(str(config))
    names = {
        f"{kind}-{category.lower()}.srs": (
            f"rule-set-{kind}/{kind}-{category.lower()}.srs"
        )
        for kind, section in (("geosite", "geosites"), ("geoip", "geoips"))
        for category in all_of_kind(proxies, section)
    }
    destination.mkdir(parents=True, exist_ok=True)
    with (
        tempfile.TemporaryDirectory(dir=destination) as temporary,
        ZipFile(archive) as source,
    ):
        staging = Path(temporary)
        for name, member in names.items():
            data = source.read(member)
            if not data:
                msg = f"empty rule set: {member}"
                raise ValueError(msg)
            (staging / name).write_bytes(data)
        for name in names:
            (staging / name).replace(destination / name)
    for path in destination.glob("*.srs"):
        if path.name.startswith(("geosite-", "geoip-")) and path.name not in names:
            path.unlink()


if __name__ == "__main__":
    extract(*(Path(arg) for arg in sys.argv[1:]))
