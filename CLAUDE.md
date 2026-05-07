# proxies-cfg

TUN-based transparent proxy on Linux, macOS, Windows. Single binary
[`shtorm-7/sing-box-extended`](https://github.com/shtorm-7/sing-box-extended)
(upstream sing-box lacks `xhttp` transport). Outbound configs are pulled from
**subscription URLs** at every `setup`; nothing about the wire protocol is
hard-coded. The sing-box binary itself is auto-updated to the latest GitHub
release on each `setup` (resolved via `releases/latest` API; falls back to the
existing local binary when offline). Version is tracked in
`<runtime>/bin/.version`.

## Code Style

Only comment non-obvious behaviour — things that would surprise a reader who
understands the language and tools.

## Secrets

`secrets.json` and `proxies.conf` are git-crypt-encrypted in repo (GPG mode).
Fresh clone: `git-crypt unlock`. Authorize key: `git-crypt add-gpg-user <keyid>`.

Sudo password lookup (scripts use `read_secret <key>`, manual:
`jq -r .sudo_password secrets.json` — macOS key is `macos_sudo_password`).
Use `printf '%s\n' "$pw" | sudo -S -k CMD`; `-k` forces fresh auth. Linux
`pam_faillock` locks after 3 fails: `faillock --user mayurifag --reset`.

Windows: `#Requires -RunAsAdministrator`.

## Project Layout

~~~
proxies.conf                      git-crypt-encrypted: per-tag [domains/geosites/geoips] sections
secrets.json                      git-crypt-encrypted: sudo_password, macos_sudo_password, proxy_*.sub_url, ssh_test_command
Makefile                          platform-detecting wrapper for setup/test/ci/doctor/etc.
pyproject.toml + uv.lock          dev tool deps (ruff). uv manages env.
.python-version                   pinned dev interpreter (3.13)
.githooks/pre-commit              blocks plaintext-staged crypto file commits

shared/sub_parse.py               fetch sub URL → base64-decode → parse first proxy URI → sing-box outbound dict
shared/geo_convert.py             v2ray geosite.dat / geoip.dat → sing-box JSON rule-sets (per category)
shared/proxies_conf.py            parser/editor for proxies.conf (load/dump + add-domain/remove-domain CLI)
shared/build_config.py            assemble final sing-box config; validates secrets covers proxies tags
shared/generate_config.sh         print sing-box config to stdout (used by setup via redirect)
shared/test_core.sh               cross-platform integration test
shared/update_geodata_core.sh     cross-platform geodata download + .dat→json conversion
shared/ci_core.sh                 shared CI driver (shell syntax, ruff, git-crypt status, lock-aware)
shared/doctor_core.sh             prereq + state audit (jq/gpg/git-crypt/uv/ruff/hooks/secrets ↔ proxies)
shared/common.sh                  helpers: format_domain, read_secret (jq), assert_root, elevate_and_run, git_*
shared/{add,remove}_domain.sh     cross-platform domain editor
shared/constants.sh               versions, geodata URLs, test URLs, OS_TAG/SUDO_KEY/OS_COMMON dispatch
shared/constants.ps1              same for Windows

linux/{setup,teardown,test,ci,doctor,generate_config,update_geodata,...}.sh
linux/common.sh                   linux paths + restart_proxy (systemctl)

macos/{setup,teardown,test,ci,doctor,generate_config,update_geodata,...}.sh
macos/common.sh                   macOS paths + ensure_curl_http3 + restart_proxy (launchctl)
macos/plists/*.plist              LaunchDaemon templates with __REPO_ROOT__ placeholder

windows/{setup,teardown,test,ci,doctor,generate_config,update_geodata,...}.ps1
windows/common.ps1                helpers: Assert-Admin, Build-SingboxConfig, Restart-Proxy, Format-Domain

.github/workflows/ci.yml          GHA: ruff lint + shell/pwsh syntax + GITCRYPT-magic check (locked clone)
{linux,macos,windows}/runtime/    gitignored: binary, generated config, rule-sets, geodata, logs
~~~

## proxies.conf format

Source-of-truth file describing routing. INI-ish, hand-editable. One bare value
per line, no leading whitespace, alphabetical (writer enforces sort + dedup).
`#` comments (full-line or trailing inline, e.g. `telegram # blocked in RU`) +
blank lines allowed in input but not preserved on rewrite.

~~~
[<tag>.domains]      # suffix-match: apex + all subdomains
mayurifag.ru

[<tag>.geosites]     # geosite category names (without "geosite-" prefix)
telegram

[<tag>.geoips]       # geoip code names (without "geoip-" prefix)
twitter
~~~

`<tag>` names a sing-box outbound. Reserved tag `direct` routes via the
built-in direct outbound and needs no `sub_url` in `secrets.json`; used for
sites that should bypass the proxy. `direct` rules are emitted before proxy
rules so direct hosts overlapping a geosite still bypass.

Each proxy tag's `sub_url` panel host **and** the parsed proxy `server` field
are auto-resolved to IPv4 at build time and emitted as a single `ip_cidr`
direct rule before all other rules. This lets raw-IP connections (SSH, deploy
scripts) to those endpoints bypass TUN even when the IP would otherwise match
a geoip set the proxy belongs to. Refreshed per `setup`; assumes server IPs
are stable between setups.

`domains` entries become sing-box `domain_suffix` rules — listing
`mayurifag.ru` covers `mayurifag.ru` and `*.mayurifag.ru`. Static base config
(log/dns/inbounds/sniff+hijack/final) is inlined in `build_config.py`.

## Outbounds

| Outbound   | Protocol            | Purpose             | Test domain           |
| ---------- | ------------------- | ------------------- | --------------------- |
| `direct`   | direct              | Default (unmatched) | checkip.amazonaws.com |
| `proxy_ru` | hysteria2           | Russian-only sites  | ident.me              |
| `proxy_it` | vless+xhttp+reality | Blocked sites       | api.ipify.org         |

Outbound *types* and credentials are extracted from each `sub_url` — the table
above reflects what the current servers offer; rotate the subscription and the
parsed outbound shape changes accordingly.

## Cross-platform constants

| Constant     | Value                                          | Where defined                           | Notes                                          |
| ------------ | ---------------------------------------------- | --------------------------------------- | ---------------------------------------------- |
| TUN address  | `172.19.0.1/30`                                | `shared/build_config.py` `_base_config` | Same on all OSes; sing-box auto-assigns        |
| TUN MTU      | `1500`                                         | `shared/build_config.py` `_base_config` | Default; lower if proxy server has smaller MTU |
| Stack        | `mixed`                                        | `shared/build_config.py` `_base_config` | gvisor userspace TCP for reliable sniff        |
| geodata URLs | runetfreedom/*                                 | `shared/geodata_urls.{sh,ps1}`          | Single source of truth                         |
| test URLs    | ident.me, api.ipify.org, checkip.amazonaws.com | `shared/test_urls.{sh,ps1}`             | Single source of truth                         |

## Subscription parsing

`shared/sub_parse.py` understands `hysteria2://` and `vless://`. URI fields with
no sing-box-extended schema match are dropped silently:

| Dropped field | Why                                                                 |
| ------------- | ------------------------------------------------------------------- |
| `fp` (hy2)    | sing-box errors `unsupported usage for uTLS` (uTLS can't wrap QUIC) |
| `fm` (hy2)    | Duplicate of `obfs` UDP block                                       |
| `spx` (vless) | sing-box-extended Reality has no `spider_x` field                   |

`fp` for VLESS is kept (uTLS over TCP works); ECH config (when present in URI)
is wrapped as PEM and passed to `tls.ech.config`. **xhttp transport requires
`alpn: ["h2"]`** (HTTP/2 mandatory).

For VLESS+xhttp+REALITY URIs, the `parser` outbound built into sing-box-extended
is **incomplete** (drops `type=xhttp` silently). `sub_parse.py` builds the full
outbound dict ourselves to compensate.

## Geodata flow

`update_geodata.sh|.ps1` downloads runetfreedom `geoip.dat` + `geosite.dat`
(v2ray protobuf). `geo_convert.py` parses them with a minimal protobuf reader
and emits one `*.json` per category referenced in `proxies.conf`. sing-box
loads each as a `local`/`source`-format rule-set.

Categories are extracted automatically from the geosites/geoips sections in
`proxies.conf` (no separate list to maintain).

## Known gotchas

**Subscription rate limit.** Both 3xui panels return 403 after rapid repeated
fetches. Production usage is one fetch per `setup` so it's a non-issue; in
development, wait ~30s between calls.

**Sub fetch User-Agent.** `urllib.request` default `Python-urllib/X.Y` is
blocked by 3xui. `sub_parse.py` sends `User-Agent: sing-box/1.13` which works.

**`shtorm-7/sing-box-extended` requires `x_padding_bytes` in xhttp.** Empty or
missing → config rejected at startup with `"x_padding_bytes cannot be
disabled"`. Set to `"100-1000"` (xray's xhttp default).

**xhttp client mode = `auto`.** Lets server pick. `packet-up`/`stream-up`/
`stream-one` may fail handshake depending on server config.

**Chromium Secure DNS.** Chrome/Edge use built-in DoH, bypassing system DNS,
so routing breaks for proxy_* domains. Disable in browser, launch with
`--disable-features=DnsOverHttps`, or set managed policy
`/etc/chromium/policies/managed/disable-doh.json` →
`{"DnsOverHttpsMode":"off"}` (Linux).

**`.NET connection pool bypasses TUN (Windows).** `ServicePointManager` reuses
TCP connections across PowerShell requests. After proxy restart, pooled
connections bypass the new TUN routing. Fix: `CloseConnectionGroup('')`
before post-restart checks (already in `windows/test.ps1` direct mode).

**`$pid` in PowerShell.** Reserved read-only variable. Use `$procId`.

**`schtasks /query` with `$ErrorActionPreference = 'Stop'`.** Throws on
nonzero exit. Use `Get-ScheduledTask -ErrorAction SilentlyContinue` instead.
