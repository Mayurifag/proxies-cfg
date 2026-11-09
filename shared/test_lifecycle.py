# ruff: noqa: INP001, S101, S603, S607

from __future__ import annotations

import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from zipfile import ZipFile

REPO = Path(__file__).resolve().parent.parent


@unittest.skipUnless(os.name == "posix", "Bash lifecycle runs on Unix")
class LifecycleTest(unittest.TestCase):
    def use_real_python(self, directory: Path) -> None:
        uv = directory / "uv"
        uv.unlink()
        uv.write_text(f'#!/bin/sh\nshift 3\nexec {shlex.quote(sys.executable)} "$@"\n')
        uv.chmod(0o700)

    def test_rule_set_extraction_preserves_working_files_on_missing_category(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "proxies.conf"
            config.write_text("[direct.geosites]\nexample\n[direct.geoips]\nxx\n")
            archive = root / "sing-box.zip"
            rules = root / "rules"
            rules.mkdir()
            old = rules / "geosite-example.srs"
            old.write_bytes(b"old")
            stale = rules / "geoip-stale.srs"
            stale.write_bytes(b"stale")
            legacy = rules / "geosite-example.json"
            legacy.write_bytes(b"legacy")

            def run_extraction() -> subprocess.CompletedProcess:
                return subprocess.run(
                    [
                        sys.executable,
                        str(REPO / "shared/extract_rule_sets.py"),
                        str(archive),
                        str(rules),
                        str(config),
                    ],
                    check=False,
                    capture_output=True,
                )

            with ZipFile(archive, "w") as data:
                data.writestr("rule-set-geosite/geosite-example.srs", b"new")
            assert run_extraction().returncode != 0
            assert old.read_bytes() == b"old"
            assert stale.read_bytes() == b"stale"

            with ZipFile(archive, "a") as data:
                data.writestr("rule-set-geoip/geoip-xx.srs", b"ip")
            assert run_extraction().returncode == 0
            assert old.read_bytes() == b"new"
            assert (rules / "geoip-xx.srs").read_bytes() == b"ip"
            assert not stale.exists()
            assert legacy.read_bytes() == b"legacy"

    def github_commands(self, root: Path, mode: str) -> dict[str, str]:
        directory = root / "bin"
        directory.mkdir()
        log = root / "calls"
        if mode != "missing":
            gh = directory / "gh"
            gh.write_text(
                """#!/bin/sh
printf 'gh\\n' >> "$CALL_LOG"
[ "$GH_TELEMETRY" = 0 ] && [ "$GH_PROMPT_DISABLED" = 1 ] || exit 90
case "$GH_MODE" in
    fail) printf partial; exit 1 ;;
    empty) exit 0 ;;
    stall) printf '%s' "$$" > "$CALL_LOG.pid"; exec "$SLEEP_BIN" 30 ;;
esac
if [ "$1" = release ]; then
    output=
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --output ]; then shift; output=$1; fi
        shift
    done
    if [ "$output" = - ]; then
        printf '\\000\\377gh'
    else
        printf '\\000\\377gh' > "$output"
    fi
else
    case " $* " in
        *" -H "*) printf '\\000\\377gh' ;;
        *) printf 'v1.2.3\\n' ;;
    esac
fi
""",
            )
            gh.chmod(0o700)
        curl = directory / "curl"
        curl.write_text(
            """#!/bin/sh
printf 'curl\\n' >> "$CALL_LOG"
output=
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then shift; output=$1; fi
    shift
done
if [ "${CURL_MODE:-}" = fail ]; then exit 7; fi
if [ -n "$output" ]; then
    if [ "${CURL_MODE:-}" = empty ]; then
        : > "$output"
    else
        printf '\\000\\376curl' > "$output"
    fi
else
    printf '{"tag_name":"v2.3.4"}\\n'
fi
""",
        )
        curl.chmod(0o700)
        (directory / "curl.exe").symlink_to(curl)
        jq = shutil.which("jq")
        if not jq:
            self.skipTest("jq is required for the curl release fallback")
        (directory / "jq").symlink_to(jq)
        uv = shutil.which("uv")
        assert uv, "uv is required"
        (directory / "uv").symlink_to(uv)
        return {
            **os.environ,
            "PATH": str(directory),
            "CALL_LOG": str(log),
            "GH_MODE": mode,
            "SLEEP_BIN": shutil.which("sleep") or "/bin/sleep",
            "POWERSHELL_TELEMETRY_OPTOUT": "1",
        }

    def test_github_downloads_prefer_gh_and_fall_back_to_curl(self) -> None:
        for operation in ("latest", "raw", "release"):
            for mode in ("success", "fail", "missing", "empty", "stall"):
                if mode == "stall" and operation != "latest":
                    continue
                with (
                    self.subTest(operation=operation, mode=mode),
                    tempfile.TemporaryDirectory() as temporary,
                ):
                    root = Path(temporary)
                    env = self.github_commands(root, mode)
                    destination = root / "download"
                    arguments = {
                        "latest": ["github_latest_version", "owner/repo"],
                        "raw": [
                            "github_raw_download",
                            "https://raw.githubusercontent.com/owner/repo/release/file.dat",
                            str(destination),
                        ],
                        "release": [
                            "github_release_download",
                            "owner/repo",
                            "v1.2.3",
                            "asset.tar.gz",
                            str(destination),
                        ],
                    }[operation]
                    result = subprocess.run(
                        [
                            "/bin/bash",
                            "-c",
                            'source "$1"; shift; "$@"',
                            "check",
                            str(REPO / "shared/github.sh"),
                            *arguments,
                        ],
                        env=env,
                        check=False,
                        capture_output=True,
                        text=True,
                        timeout=15,
                    )
                    assert result.returncode == 0, result.stderr
                    if operation == "latest":
                        assert result.stdout.strip() == (
                            "1.2.3" if mode == "success" else "2.3.4"
                        )
                    else:
                        assert destination.read_bytes() == (
                            b"\x00\xffgh" if mode == "success" else b"\x00\xfecurl"
                        )
                    calls = (root / "calls").read_text().splitlines()
                    assert calls == (
                        ["gh"]
                        if mode == "success"
                        else ["curl"]
                        if mode == "missing"
                        else ["gh", "curl"]
                    )
                    if mode == "stall":
                        pid = (root / "calls.pid").read_text()
                        assert (
                            subprocess.run(
                                ["/bin/kill", "-0", pid],
                                check=False,
                                capture_output=True,
                            ).returncode
                            != 0
                        )

    def test_failed_geodata_download_keeps_cached_archive(self) -> None:
        for curl_mode in ("empty", "fail"):
            with (
                self.subTest(curl_mode=curl_mode),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                env = self.github_commands(
                    root, "empty" if curl_mode == "empty" else "fail"
                )
                directory = Path(env["PATH"])
                self.use_real_python(directory)
                geodata = root / "geodata"
                geodata.mkdir()
                old = geodata / "sing-box.zip"
                with ZipFile(old, "w") as archive:
                    archive.writestr("rule-set-geosite/geosite-example.srs", b"rule")
                original = old.read_bytes()
                os.utime(old, (0, 0))
                config = root / "proxies.conf"
                config.write_text("[direct.geosites]\nexample\n")
                env.update(
                    PATH=str(directory) + os.pathsep + os.defpath,
                    CURL_MODE=curl_mode,
                    GEODATA_DIR=str(geodata),
                    RULE_SET_DIR=str(root / "rules"),
                    SINGBOX_LOG=str(root / "singbox.log"),
                    PROXIES_CONF=str(config),
                )
                result = subprocess.run(
                    ["/bin/bash", "shared/update_geodata_core.sh"],
                    cwd=REPO,
                    env=env,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                assert result.returncode == 0, result.stderr
                assert old.read_bytes() == original
                assert (root / "rules/geosite-example.srs").read_bytes() == b"rule"

    def test_offline_release_lookup_keeps_installed_binary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = self.github_commands(root, "fail")
            directory = Path(env["PATH"])
            runtime = root / "runtime"
            binary = runtime / "bin/sing-box"
            binary.parent.mkdir(parents=True)
            binary.write_text("#!/bin/sh\nexit 0\n")
            binary.chmod(0o700)
            sentinel = binary.parent / ".version"
            sentinel.write_text("1.0.0")
            env.update(
                PATH=str(directory) + os.pathsep + os.defpath,
                CURL_MODE="fail",
                RUNTIME_DIR=str(runtime),
                SINGBOX_BIN=str(binary),
                SINGBOX_ARCH="linux-amd64",
            )
            result = subprocess.run(
                ["/bin/bash", "shared/install_singbox.sh"],
                cwd=REPO,
                env=env,
                check=False,
                capture_output=True,
                text=True,
            )
            assert result.returncode == 0, result.stderr
            assert binary.read_text() == "#!/bin/sh\nexit 0\n"
            assert sentinel.read_text() == "1.0.0"

    def test_powershell_github_downloads_preserve_binary_output(self) -> None:
        pwsh = shutil.which("pwsh")
        if not pwsh:
            self.skipTest("PowerShell is not installed")
        script = r"""
$ErrorActionPreference = 'Stop'
. (Join-Path $env:PROXY_TEST_ROOT 'windows/common.ps1')
$env:GH_TELEMETRY = 'previous'
$env:GH_PROMPT_DISABLED = 'previous'
$env:GH_NO_UPDATE_NOTIFIER = 'previous'
$destination = Join-Path $env:PROXY_TEST_ROOT 'output data.bin'
switch ($env:TEST_OPERATION) {
    latest { $version = Get-GithubLatestVersion -Repo 'owner/repo' }
    raw {
        $url = 'https://raw.githubusercontent.com/owner/repo/release/file.dat'
        Invoke-GithubRawDownload -Url $url -Destination $destination
    }
    release {
        Invoke-GithubReleaseDownload -Repo 'owner/repo' -Tag 'v1.2.3' `
            -Asset 'asset.zip' -Destination $destination
    }
}
if ($env:GH_TELEMETRY -ne 'previous' -or $env:GH_PROMPT_DISABLED -ne 'previous' -or
    $env:GH_NO_UPDATE_NOTIFIER -ne 'previous') {
    throw 'GitHub CLI environment not restored'
}
if ($env:TEST_OPERATION -eq 'latest') { Write-Output "VERSION=$version" }
"""
        for operation in ("latest", "raw", "release"):
            for mode in ("success", "fail", "missing", "empty", "stall"):
                if mode == "stall" and operation != "latest":
                    continue
                with (
                    self.subTest(operation=operation, mode=mode),
                    tempfile.TemporaryDirectory() as temporary,
                ):
                    root = Path(temporary)
                    env = self.github_commands(root, mode)
                    windows = root / "windows"
                    windows.mkdir()
                    shutil.copy2(REPO / "windows/common.ps1", windows / "common.ps1")
                    env.update(PROXY_TEST_ROOT=str(root), TEST_OPERATION=operation)
                    result = subprocess.run(
                        [pwsh, "-NoProfile", "-NonInteractive", "-Command", script],
                        env=env,
                        check=False,
                        capture_output=True,
                        text=True,
                        timeout=20,
                    )
                    assert result.returncode == 0, result.stderr
                    if operation == "latest":
                        expected = "1.2.3" if mode == "success" else "2.3.4"
                        assert f"VERSION={expected}" in result.stdout
                    else:
                        assert (root / "output data.bin").read_bytes() == (
                            b"\x00\xffgh" if mode == "success" else b"\x00\xfecurl"
                        )
                    calls = (root / "calls").read_text().splitlines()
                    assert calls == (
                        ["gh"]
                        if mode == "success"
                        else ["curl"]
                        if mode == "missing"
                        else ["gh", "curl"]
                    )
                    if mode == "stall":
                        pid = (root / "calls.pid").read_text()
                        assert (
                            subprocess.run(
                                ["/bin/kill", "-0", pid],
                                check=False,
                                capture_output=True,
                            ).returncode
                            != 0
                        )

    def test_powershell_failed_geodata_keeps_cached_archive(self) -> None:
        pwsh = shutil.which("pwsh")
        if not pwsh:
            self.skipTest("PowerShell is not installed")
        for curl_mode in ("empty", "fail"):
            with (
                self.subTest(curl_mode=curl_mode),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                env = self.github_commands(
                    root, "empty" if curl_mode == "empty" else "fail"
                )
                self.use_real_python(Path(env["PATH"]))
                windows = root / "windows"
                shared = root / "shared"
                windows.mkdir()
                shared.mkdir()
                for name in ("common.ps1", "update_geodata.ps1"):
                    shutil.copy2(REPO / "windows" / name, windows / name)
                for name in (
                    "constants.ps1",
                    "extract_rule_sets.py",
                    "proxies_conf.py",
                    "rotate_logs.py",
                ):
                    shutil.copy2(REPO / "shared" / name, shared / name)
                (root / "proxies.conf").write_text("[direct.geosites]\nexample\n")
                geodata = windows / "runtime/geodata"
                geodata.mkdir(parents=True)
                old = geodata / "sing-box.zip"
                with ZipFile(old, "w") as archive:
                    archive.writestr("rule-set-geosite/geosite-example.srs", b"rule")
                original = old.read_bytes()
                os.utime(old, (0, 0))
                env["CURL_MODE"] = curl_mode
                result = subprocess.run(
                    [
                        pwsh,
                        "-NoProfile",
                        "-NonInteractive",
                        "-File",
                        str(windows / "update_geodata.ps1"),
                    ],
                    env=env,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                assert result.returncode == 0, result.stderr
                assert old.read_bytes() == original
                assert (
                    windows / "runtime/rule-sets/geosite-example.srs"
                ).read_bytes() == b"rule"

    def test_failed_generation_or_validation_preserves_working_config(self) -> None:
        for generator_exit, validator_exit in [(42, 0), (0, 43), (0, 0)]:
            with (
                self.subTest(generator=generator_exit, validator=validator_exit),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                config = root / "config.json"
                config.write_text("working config")
                generator = root / "generate.sh"
                generator.write_text(f"printf 'new config'\nexit {generator_exit}\n")
                validator = root / "sing-box"
                validator.write_text(f"#!/bin/sh\nexit {validator_exit}\n")
                validator.chmod(0o700)
                result = subprocess.run(
                    [
                        "bash",
                        "-c",
                        f'source "{REPO}/shared/common.sh"; '
                        'RUNTIME_DIR="$1"; GENERATE_CONFIG="$2"; '
                        'SINGBOX_CONFIG="$3"; SINGBOX_BIN="$4"; '
                        "generate_singbox_config",
                        "check",
                        str(root),
                        str(generator),
                        str(config),
                        str(validator),
                    ],
                    cwd=root,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                assert result.returncode == (generator_exit or validator_exit)
                assert config.read_text() == (
                    "working config" if result.returncode else "new config"
                )
                assert not list(root.glob("config.json.*"))

    def test_initial_network_failure_restores_previously_running_proxy(self) -> None:
        for was_running in ["0", "1"]:
            with (
                self.subTest(was_running=was_running),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                marker = root / "proxy-down"
                teardown = root / "teardown.sh"
                teardown.write_text(f'touch "{marker}"\n')
                setup = root / "setup.sh"
                setup.write_text(f'rm -f "{marker}"\n')
                curl = root / "curl"
                curl.write_text("#!/bin/sh\nexit 7\n")
                curl.chmod(0o700)
                result = subprocess.run(
                    ["bash", "shared/test_core.sh"],
                    cwd=REPO,
                    check=False,
                    capture_output=True,
                    text=True,
                    env={
                        **os.environ,
                        "PATH": str(root) + os.pathsep + os.environ["PATH"],
                        "SETUP": str(setup),
                        "TEARDOWN": str(teardown),
                        "PROXY_WAS_RUNNING": was_running,
                    },
                )
                assert result.returncode == 7
                assert marker.exists() == (was_running == "0")

    def test_termination_restores_proxy_and_preserves_signal_exit_status(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            down = root / "proxy-down"
            ready = root / "probe-started"
            teardown = root / "teardown.sh"
            teardown.write_text(f'touch "{down}"\n')
            setup = root / "setup.sh"
            setup.write_text(f'rm -f "{down}"\n')
            curl = root / "curl"
            curl.write_text(f'#!/bin/sh\ntouch "{ready}"\nsleep 30\n')
            curl.chmod(0o700)
            with subprocess.Popen(
                ["bash", "shared/test_core.sh"],
                cwd=REPO,
                env={
                    **os.environ,
                    "PATH": str(root) + os.pathsep + os.environ["PATH"],
                    "SETUP": str(setup),
                    "TEARDOWN": str(teardown),
                    "PROXY_WAS_RUNNING": "1",
                },
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            ) as process:
                try:
                    deadline = time.monotonic() + 5
                    while not ready.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    assert ready.exists(), "Probe did not start"
                    os.killpg(process.pid, signal.SIGTERM)
                    process.communicate(timeout=5)
                    assert process.returncode == 143
                    assert not down.exists()
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.communicate()
