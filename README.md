# proxies-cfg

Personal TUN-based transparent proxy setup. Single binary
([shtorm-7/sing-box-extended](https://github.com/shtorm-7/sing-box-extended) —
upstream sing-box has no `xhttp` transport), driven entirely from subscription
URLs.

- No GUI, no tray app — runs as a system service.
- Auto-installed in autostart (systemd / LaunchDaemon / Scheduled Task).
- Three proxy routes + direct: Russian-only sites via one, blocked sites via
  another, everything else direct. The `direct` routing tag also catches VPS
  panel domains (suffix match) so the proxy server itself is never tunneled.
- Proxy outbounds come from **subscription URLs** or inline URIs. Subscriptions
  are re-fetched on every `setup`.
- runetfreedom geoip + geosite lists, refreshed daily, converted at install time
  to sing-box JSON rule-sets.
- Currently supports hysteria2, VLESS/xhttp/Reality, and WireGuard endpoints.
- DNS-over-HTTPS to 1.1.1.1 / 8.8.8.8.
- `secrets.json` (sub URLs, sudo passwords) and `proxies.conf` are
  [git-crypt](https://github.com/AGWA/git-crypt)-encrypted in repo (GPG mode);
  plaintext after `git-crypt unlock`.
- Linux (systemd), macOS (LaunchDaemon), Windows (Scheduled Task) — same
  `proxies.conf`, same Python build pipeline.

## Subscription format

Each outbound's `sub_url` returns base64-encoded plaintext containing one or
more `proxy://...` URIs (one per line). The first URI is parsed. Secrets may
also use inline `uri` for static configs like WireGuard.

Supported schemes: `hysteria2://`, `vless://`, `wireguard://`. Both `ws`/`grpc`
transports recognised; `xhttp` requires the `sing-box-extended` fork which is
used in this repo.

### Dropped URI fields

| Field          | Scheme    | Why                                               |
| -------------- | --------- | ------------------------------------------------- |
| `fp=<browser>` | hysteria2 | uTLS can't wrap QUIC; sing-box errors if set      |
| `fm=<json>`    | hysteria2 | duplicates `obfs=` + `obfs-password=`             |
| `spx=<path>`   | vless     | sing-box-extended Reality has no `spider_x` field |

All three are anti-detection polish, not auth — connections still succeed.

## Prerequisites

| OS      | Required                                              |
| ------- | ----------------------------------------------------- |
| Linux   | `git-crypt`, `gnupg`, `jq`, `uv`, `curl`, `systemd`   |
| macOS   | `git-crypt`, `gnupg`, `jq`, `uv`, brew `curl` for HTTP/3 |
| Windows | `git-crypt`, `gnupg`, `jq`, `uv`, `make`              |

`uv` provides the Python interpreter (3.14, pinned via `.python-version`)
plus dev tools (ruff) via `pyproject.toml` + `uv.lock`. No system Python
needed — `uv python install` materialises 3.14 on first `uv run`. Plus a GPG
keypair authorized to unlock the repo (see [Encrypted secrets](#encrypted-secrets)).
Run `make doctor` after a fresh clone to verify everything is wired up.

### macOS: disable Touch ID for sudo (one-time)

Setup/teardown/test feed the sudo password from `secrets.json` via
`sudo -S -k`. macOS PAM puts Touch ID (`pam_tid.so`) ahead of stdin auth, so
`sudo` pops a dialog every run. Disable for sudo only:

~~~sh
sudo cp /etc/pam.d/sudo_local /etc/pam.d/sudo_local.bak.proxiescfg
sudo sed -i '' 's|^auth       sufficient     pam_tid.so|# auth       sufficient     pam_tid.so|' /etc/pam.d/sudo_local
~~~

Restore: `sudo cp /etc/pam.d/sudo_local.bak.proxiescfg /etc/pam.d/sudo_local`.

## Usage

| Command                | Description                                  |
| ---------------------- | -------------------------------------------- |
| `make setup`           | install + start proxy                        |
| `make teardown`        | stop + remove proxy                          |
| `make restart`         | teardown + setup                             |
| `make test`            | full integration cycle                       |
| `make status`          | show proxy status                            |
| `make logs`            | follow proxy log                             |
| `make flush-dns`       | flush DNS cache                              |
| `make update-geodata`  | refresh runetfreedom .dat → JSON rule-sets   |
| `make generate-config` | print sing-box config to stdout (inspection) |
| `make ci`              | shell + python + ruff + git-crypt status     |
| `make doctor`          | verify all prereqs + repo state              |
| `make unlock`          | git-crypt unlock (after fresh clone)         |
| `make lock`            | git-crypt lock (purge plaintext from WT)     |
| `make install-hooks`   | wire `.githooks/` (pre-commit crypto guard)  |

## Domains

~~~sh
make add-domain domain=kremlin.ru proxy=proxy_ru
make add-domain domain=cloud.ru   proxy=direct
make remove-domain domain=kremlin.ru
make add-domain   # interactive prompt
~~~

Routing tags: `proxy_ru`, `proxy_it`, `proxy_ipv6_it_novnc`, `direct` (built-in
bypass). All `domains` entries are suffix-matched — `mayurifag.ru` catches
`mayurifag.ru` and `*.mayurifag.ru`. Edits `proxies.conf` and restarts the proxy.

`[<tag>.ip_versions]` accepts `4` or `6` catch-all routing rules; current IPv6
traffic is routed through `proxy_ipv6_it_novnc`.

When an IPv6 catch-all exists, `direct` domain suffixes apply only to IPv4. This
lets IPv6-only subdomains, such as provider noVNC hosts, use WireGuard without
per-domain entries.

Known IPv6-only test/provider domains may still be listed under
`proxy_ipv6_it_novnc.domains` so macOS resolver overrides and fake-IP DNS make
browser and curl behavior deterministic.

`[<tag>.protocols]` accepts sing-box sniffed protocol names. Current config
routes `bittorrent` via `direct`, while HTTP/HTTPS tracker domains still follow
normal domain/geosite/geoip rules and can go through a proxy.

## Suggested shell aliases

~~~sh
export PROXIES_CFG="$HOME/Code/proxies-cfg"
alias proxy-cd='cd "$PROXIES_CFG"'
alias proxy-setup='make -C "$PROXIES_CFG" setup'
alias proxy-teardown='make -C "$PROXIES_CFG" teardown'
alias proxy-restart='make -C "$PROXIES_CFG" restart'
alias proxy-test='make -C "$PROXIES_CFG" test'
alias proxy-status='make -C "$PROXIES_CFG" status'
alias proxy-logs='make -C "$PROXIES_CFG" logs'
alias proxy-flush-dns='make -C "$PROXIES_CFG" flush-dns'
alias proxy-geodata='make -C "$PROXIES_CFG" update-geodata'
proxy-add() { make -C "$PROXIES_CFG" add-domain    domain="$1" proxy="${2:-proxy_it}"; }
proxy-rm()  { make -C "$PROXIES_CFG" remove-domain domain="$1"; }
alias proxy-remove='proxy-rm'
~~~

PowerShell ($PROFILE):

~~~powershell
$ProxiesCfg = "$HOME\Code\proxies-cfg"
function proxy-cd        { Set-Location $ProxiesCfg }
function proxy-setup     { make -C $ProxiesCfg setup }
function proxy-teardown  { make -C $ProxiesCfg teardown }
function proxy-restart   { make -C $ProxiesCfg restart }
function proxy-test      { make -C $ProxiesCfg test }
function proxy-status    { make -C $ProxiesCfg status }
function proxy-logs      { make -C $ProxiesCfg logs }
function proxy-flush-dns { make -C $ProxiesCfg flush-dns }
function proxy-geodata   { make -C $ProxiesCfg update-geodata }
function proxy-add($d, $p = 'proxy_it') { make -C $ProxiesCfg add-domain    domain=$d proxy=$p }
function proxy-rm($d)                   { make -C $ProxiesCfg remove-domain domain=$d }
function proxy-remove($d)               { proxy-rm $d }
~~~

## Encrypted secrets

`secrets.json` + `proxies.conf` are git-crypt-encrypted in repo (GPG mode).
Working tree plaintext after unlock; remote stores ciphertext.

### Fresh clone (your GPG key already imported)

~~~sh
# macOS
brew install git-crypt gnupg jq uv

# Debian/Ubuntu
sudo apt install git-crypt gnupg jq
curl -LsSf https://astral.sh/uv/install.sh | sh

# Windows (winget)
winget install AGWA.git-crypt GnuPG.GnuPG jqlang.jq astral-sh.uv

git clone <url>
cd proxies-cfg
make unlock           # git-crypt unlock
make install-hooks    # arms .githooks/pre-commit
make doctor           # sanity-check everything
~~~

GPG key needs an encryption subkey (`[E]` flag). Verify:
`gpg --list-secret-keys --with-subkey-fingerprints <email>` — look for
`ssb … [E]`. If missing: `gpg --edit-key <keyid>` → `addkey` → encrypt-only →
`save`, re-publish the public key.

### Authorize another GPG key

~~~sh
git-crypt add-gpg-user <keyid>
git push
~~~

## Notes

- DNS prefers IPv4, but `[proxy_ipv6_it_novnc.ip_versions]` routes IPv6-only
  sites and other IPv6 traffic through WireGuard.
- BitTorrent peer traffic is routed direct by `[direct.protocols]`; tracker
  domains are not exempted and still follow normal proxy rules.
- `twitch.tv` needs proxy for country restriction; CDN stays direct.
- `api.ipify.org` / `ident.me` are test-only domains for verifying routing.
- Subscription panels rate-limit. One fetch per `setup` is fine; rapid
  successive fetches return 403 for ~30s.
