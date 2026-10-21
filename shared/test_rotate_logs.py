# ruff: noqa: INP001, S101

from __future__ import annotations

import io
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch

import rotate_logs


class RotateLogsTest(unittest.TestCase):
    def test_locked_active_log_skips_rotation_without_changing_any_files(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(rotate_logs, "LIMIT", 64),
        ):
            log = Path(temporary) / "setup.log"
            log.write_bytes(b"active\n" * 20)
            for index in range(1, rotate_logs.BACKUPS + 1):
                log.with_name(f"{log.name}.{index}").write_bytes(
                    f"archive-{index}\n".encode()
                )
            before = {path.name: path.read_bytes() for path in log.parent.iterdir()}
            stderr = io.StringIO()
            with (
                patch.object(
                    Path, "open", side_effect=PermissionError("log is locked")
                ),
                redirect_stderr(stderr),
            ):
                rotate_logs.rotate(log)
            assert {
                path.name: path.read_bytes() for path in log.parent.iterdir()
            } == before
            assert "Skipping rotation of setup.log" in stderr.getvalue()
            assert "log is locked" in stderr.getvalue()

    def test_rotation_keeps_three_bounded_tails_and_preserves_active_inode(
        self,
    ) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(rotate_logs, "LIMIT", 64),
        ):
            log = Path(temporary) / "singbox.log"
            log.write_text("small\n")
            rotate_logs.rotate(log)
            assert log.read_text() == "small\n"
            assert not log.with_suffix(".log.1").exists()
            for index in range(5):
                log.write_text(f"old-{index}\n" * 20 + f"new-{index}\n")
                inode = log.stat().st_ino
                rotate_logs.rotate(log)
                assert log.stat().st_ino == inode
                assert log.read_bytes() == b""
                assert log.with_suffix(".log.1").read_text().endswith(f"new-{index}\n")
            archives = list(log.parent.glob("*.log.*"))
            assert len(archives) == 3
            assert all(path.stat().st_size <= 64 for path in archives)
