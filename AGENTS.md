# Agent Rules

## Hard Rules

- Do not edit `proxies.conf` directly. Use the repo commands instead: `make add-domain domain=<domain> proxy=<tag>` or `make remove-domain domain=<domain>`.
- Do not hand-edit generated runtime files under `linux/runtime/`, `macos/runtime/`, or `windows/runtime/`, including `config.json`, rule-set JSON, geodata, binaries, and logs.
- Valid routing tags are documented in `README.md`; do not invent new proxy tags without changing the config-building code and tests.

## Verification

- Run `make ci` after code changes when feasible.
- Run `make generate-config` after changes that affect config generation.
- Run `make doctor` after environment, git-crypt, hook, or prerequisite changes.
- For routing-only requests, prefer the add/remove command output as verification; do not run broad integration tests unless needed.

## Project Boundaries

- Keep changes cross-platform unless the request is explicitly OS-specific. This repo supports Windows, macOS, and Linux wrappers around shared logic.
- Put shared behavior in `shared/` when all platforms need it; keep platform-specific service, DNS, and privilege behavior in the OS directories.
- Avoid rapid repeated subscription fetches; provider panels may return temporary 403s after frequent `setup` / config generation runs.
- Preserve the existing minimal CLI style: Bash for Unix wrappers, PowerShell 7 for Windows wrappers, Python for config parsing/building.
- Do not add GUI, tray, or app-level behavior; this project is a service-oriented sing-box setup.

## Secrets And Git

- Run `make install-hooks` if hooks are not installed before committing encrypted files.
- Before committing, check `git status` and only stage intended files.
- Never commit runtime logs, downloaded sing-box binaries, generated configs, geodata outputs, or local virtualenv files.
