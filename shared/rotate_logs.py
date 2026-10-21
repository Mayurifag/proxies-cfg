#!/usr/bin/env python3
"""Keep three bounded log archives without restarting the running proxy."""

from __future__ import annotations

import sys
from pathlib import Path

LIMIT = 10 * 1024 * 1024
BACKUPS = 3


def rotate(path: Path) -> None:
    if not path.is_file() or path.stat().st_size <= LIMIT:
        return
    try:
        current = path.open("r+b")
    except PermissionError as error:
        print(
            f"Skipping rotation of {path.name}: cannot open active log ({error})",
            file=sys.stderr,
        )
        return
    # ponytail: copytruncate may lose concurrent lines;
    # use a streaming logger if lossless logs are required.
    with current:
        for index in range(BACKUPS - 1, 0, -1):
            previous = path.with_name(f"{path.name}.{index}")
            if previous.exists():
                previous.replace(path.with_name(f"{path.name}.{index + 1}"))
        current.seek(-LIMIT, 2)
        current.readline()
        with path.with_name(f"{path.name}.1").open("wb") as archive:
            archive.write(current.read(LIMIT))
        current.seek(0)
        current.truncate()
    print(f"Rotated {path.name}; retained at most {BACKUPS} archives of {LIMIT} bytes")


if __name__ == "__main__":
    for log in Path(sys.argv[1]).glob("*.log"):
        rotate(log)
