# ruff: noqa: INP001, S101, S603, S607

from __future__ import annotations

import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


@unittest.skipUnless(os.name == "posix", "Bash lifecycle runs on Unix")
class LifecycleTest(unittest.TestCase):
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
