#!/usr/bin/env python3
"""Fetch a subscription URL, parse first proxy URI, emit sing-box outbound JSON.

Base64-decode the body, parse the first proxy URI on a line, and emit a
sing-box-extended outbound or endpoint JSON dict.

Supported schemes:
    hysteria2://password@host:port?...   (alpn=h3 mandatory for QUIC)
    vless://uuid@host:port?type=xhttp&security=reality&...   (alpn=h2 for xhttp)
    wireguard://private_key@host:port?publickey=peer_public_key&address=cidr[,cidr]

Usage:
    python3 sub_parse.py <sub_url> <tag>
    → JSON outbound on stdout

Hard-aborts on fetch error, decode error, or unknown scheme.
"""

from __future__ import annotations

import base64
import json
import re
import sys
import urllib.parse
import urllib.request


def fetch_first_uri(sub_url: str) -> str:
    req = urllib.request.Request(sub_url, headers={"User-Agent": "sing-box/1.13"})  # noqa: S310
    with urllib.request.urlopen(req, timeout=15) as resp:  # noqa: S310
        body = resp.read()
    decoded = base64.b64decode(body).decode("utf-8", errors="strict")
    for raw in decoded.splitlines():
        line = raw.strip()
        if line and re.match(r"^[a-z0-9]+://", line):
            return line
    msg = f"no proxy URI found in subscription body: {decoded!r}"
    raise RuntimeError(msg)


def _query_first(query: dict, key: str, default: str = "") -> str:
    values = query.get(key, [])
    return values[0] if values else default


def _query_any(query: dict, keys: tuple[str, ...], default: str = "") -> str:
    for key in keys:
        value = _query_first(query, key)
        if value:
            return value
    return default


def _query_csv(query: dict, keys: tuple[str, ...]) -> list[str]:
    value = _query_any(query, keys)
    return [part.strip() for part in value.split(",") if part.strip()]


def parse_hysteria2(uri: str, tag: str) -> dict:
    parsed = urllib.parse.urlparse(uri)
    query = urllib.parse.parse_qs(parsed.query)
    password = urllib.parse.unquote(parsed.username or "")
    host = parsed.hostname or ""
    port = parsed.port or 443
    sni = _query_first(query, "sni", host)
    alpn = _query_first(query, "alpn", "h3")

    out = {
        "type": "hysteria2",
        "tag": tag,
        "server": host,
        "server_port": port,
        "password": password,
        "tls": {
            "enabled": True,
            "server_name": sni,
            "alpn": alpn.split(","),
        },
    }

    obfs_type = _query_first(query, "obfs")
    if obfs_type:
        out["obfs"] = {
            "type": obfs_type,
            "password": _query_first(query, "obfs-password"),
        }

    ech = _query_first(query, "ech")
    if ech:
        out["tls"]["ech"] = {
            "enabled": True,
            "config": [_ech_to_pem(ech)],
        }
    # fp/utls intentionally skipped for hysteria2: sing-box rejects uTLS over QUIC.
    # fm intentionally skipped: duplicates `obfs` data.
    return out


def parse_vless(uri: str, tag: str) -> dict:
    parsed = urllib.parse.urlparse(uri)
    query = urllib.parse.parse_qs(parsed.query)
    uuid = parsed.username or ""
    host = parsed.hostname or ""
    port = parsed.port or 443
    sni = _query_first(query, "sni", host)
    security = _query_first(query, "security")
    transport_type = _query_first(query, "type")
    fp = _query_first(query, "fp")

    tls = {
        "enabled": bool(security in ("tls", "reality")),
        "server_name": sni,
    }
    alpn = _query_first(query, "alpn")
    if alpn:
        tls["alpn"] = alpn.split(",")
    elif transport_type == "xhttp":
        tls["alpn"] = ["h2"]
    if fp:
        tls["utls"] = {"enabled": True, "fingerprint": fp}
    if security == "reality":
        tls["reality"] = {
            "enabled": True,
            "public_key": _query_first(query, "pbk"),
            "short_id": _query_first(query, "sid"),
        }
    ech = _query_first(query, "ech")
    if ech:
        tls["ech"] = {"enabled": True, "config": [_ech_to_pem(ech)]}

    out = {
        "type": "vless",
        "tag": tag,
        "server": host,
        "server_port": port,
        "uuid": uuid,
    }
    if tls["enabled"]:
        out["tls"] = tls

    if transport_type == "xhttp":
        host_hdr = _query_first(query, "host") or sni
        out["transport"] = {
            "type": "xhttp",
            "path": _query_first(query, "path", "/"),
            "host": host_hdr,
            "mode": _query_first(query, "mode", "auto"),
            "x_padding_bytes": "100-1000",
        }
    elif transport_type == "ws":
        out["transport"] = {
            "type": "ws",
            "path": _query_first(query, "path", "/"),
            "headers": {"Host": _query_first(query, "host", sni)},
        }
    elif transport_type == "grpc":
        out["transport"] = {
            "type": "grpc",
            "service_name": _query_first(query, "serviceName"),
        }
    # spx (Reality spiderX): no schema in sing-box-extended, skipped.
    return out


def parse_wireguard(uri: str, tag: str) -> dict:
    parsed = urllib.parse.urlparse(uri)
    query = urllib.parse.parse_qs(parsed.query)
    private_key = urllib.parse.unquote(parsed.username or "") or _query_any(
        query,
        ("private_key", "privatekey"),
    )
    peer_public_key = _query_any(
        query,
        ("peer_public_key", "peerpublickey", "public_key", "publickey"),
    )
    address = _query_csv(query, ("local_address", "address"))
    allowed_ips = _query_csv(query, ("allowed_ips", "allowedips")) or [
        "0.0.0.0/0",
        "::/0",
    ]

    out = {
        "type": "wireguard",
        "tag": tag,
        "address": address,
        "private_key": private_key,
        "peers": [
            {
                "address": parsed.hostname or "",
                "port": parsed.port or 51820,
                "public_key": peer_public_key,
                "allowed_ips": allowed_ips,
            },
        ],
    }

    pre_shared_key = _query_any(
        query,
        ("pre_shared_key", "preshared_key", "psk"),
    )
    if pre_shared_key:
        out["peers"][0]["pre_shared_key"] = pre_shared_key

    reserved = _query_first(query, "reserved")
    if reserved:
        out["peers"][0]["reserved"] = [int(part) for part in reserved.split(",")]

    keepalive = _query_first(query, "persistent_keepalive_interval")
    if keepalive:
        out["peers"][0]["persistent_keepalive_interval"] = int(keepalive)

    mtu = _query_first(query, "mtu")
    if mtu:
        out["mtu"] = int(mtu)

    return out


def _ech_to_pem(ech_param: str) -> str:
    raw = base64.b64decode(urllib.parse.unquote(ech_param))
    encoded = base64.b64encode(raw).decode("ascii")
    lines = [encoded[i : i + 64] for i in range(0, len(encoded), 64)]
    return (
        "-----BEGIN ECH CONFIGS-----\n"
        + "\n".join(lines)
        + "\n-----END ECH CONFIGS-----\n"
    )


PARSERS = {
    "hysteria2": parse_hysteria2,
    "vless": parse_vless,
    "wireguard": parse_wireguard,
}


def parse_uri(uri: str, tag: str) -> dict:
    scheme = uri.split("://", 1)[0].lower()
    parser = PARSERS.get(scheme)
    if parser is None:
        msg = f"unsupported scheme: {scheme!r} (uri: {uri!r})"
        raise RuntimeError(msg)
    return parser(uri, tag)


def fetch_outbound(sub_url: str, tag: str) -> dict:
    return parse_uri(fetch_first_uri(sub_url), tag)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    sub_url, tag = sys.argv[1], sys.argv[2]
    print(json.dumps(fetch_outbound(sub_url, tag), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
