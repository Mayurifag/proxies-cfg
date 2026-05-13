#!/usr/bin/env python3
"""Source-of-truth parser/editor for proxies.conf.

File format (INI-ish, hand-editable):
    [<tag>.<kind>]              # kind in {domains, geosites, geoips, ip_versions}
    value                       # one bare value per line, no leading whitespace
    ...

`<tag>` names a sing-box outbound. The reserved tag `direct` routes via the
built-in direct outbound (no sub_url needed). Any other tag must have a
`<tag>.sub_url` entry in secrets.json.

`domains` entries are matched as **domain suffixes** (apex + all subdomains).
Empty lines and `#` comments (full-line or trailing inline) are ignored on
read. The writer always sorts values alphabetically, deduplicates, drops empty
sections, and inserts one blank line between sections. Comments are not
preserved.

CLI:
    python3 proxies_conf.py tags <path>
        Print routing tags (sections with `.domains`), one per line.

    python3 proxies_conf.py add-domain <tag> <domain> <path>
        Add domain to [tag.domains]. Tag must already exist in the file.
        Creates the section if missing. No-op if already present.

    python3 proxies_conf.py remove-domain <domain> <path>
        Remove domain from any `.domains` section. Exit 0 even if absent.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

KINDS = ("domains", "geosites", "geoips", "ip_versions")
_HEADER = re.compile(r"^\[([A-Za-z0-9_]+)\.(" + "|".join(KINDS) + r")\]$")


def load(path: str) -> dict[str, dict[str, list[str]]]:
    out: dict[str, dict[str, list[str]]] = {}
    cur: list[str] | None = None
    with Path(path).open() as f:
        for raw in f:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            m = _HEADER.match(line)
            if m:
                tag, kind = m.group(1), m.group(2)
                cur = out.setdefault(tag, {}).setdefault(kind, [])
                continue
            if cur is None:
                msg = f"{path}: value before any section header: {line!r}"
                raise ValueError(msg)
            cur.append(line)
    return out


def dump(data: dict[str, dict[str, list[str]]], path: str) -> None:
    parts: list[str] = []
    for tag, kinds in data.items():
        for kind in KINDS:
            values = kinds.get(kind)
            if not values:
                continue
            parts.append(f"[{tag}.{kind}]\n" + "\n".join(sorted(set(values))))
    with Path(path).open("w", newline="\n") as f:
        f.write("\n\n".join(parts) + "\n")


def proxy_tags(data: dict) -> list[str]:
    return [t for t, kinds in data.items() if "domains" in kinds]


def all_of_kind(data: dict, kind: str) -> list[str]:
    out: set[str] = set()
    for kinds in data.values():
        out.update(kinds.get(kind, []))
    return sorted(out)


def _add_domain(path: str, tag: str, domain: str) -> int:
    data = load(path)
    if tag not in data:
        print(f"error: tag {tag!r} not in {path}", file=sys.stderr)
        return 1
    section = data[tag].setdefault("domains", [])
    if domain in section:
        print(f"no-op: {domain} already in {tag}")
        return 0
    section.append(domain)
    dump(data, path)
    print(f"added {domain} to {tag}")
    return 0


def _remove_domain(path: str, domain: str) -> int:
    data = load(path)
    found = False
    for kinds in data.values():
        domains = kinds.get("domains")
        if domains and domain in domains:
            kinds["domains"] = [d for d in domains if d != domain]
            found = True
    if not found:
        print(f"{domain} not found")
        return 0
    dump(data, path)
    print(f"removed {domain}")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) >= 3 and argv[1] == "tags" and len(argv) == 3:
        for t in proxy_tags(load(argv[2])):
            print(t)
        return 0
    if len(argv) == 5 and argv[1] == "add-domain":
        return _add_domain(argv[4], argv[2], argv[3])
    if len(argv) == 4 and argv[1] == "remove-domain":
        return _remove_domain(argv[3], argv[2])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
