import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from protonsync_upload_watch import UploadWatcher, ignored


class UploadWatcherTests(unittest.TestCase):
    def test_ignored_office_temporary_files(self):
        self.assertTrue(ignored(Path(".~lock.report.docx#")))
        self.assertTrue(ignored(Path("~$report.docx")))
        self.assertTrue(ignored(Path(".~partial.insyncdl")))
        self.assertFalse(ignored(Path("report.docx")))

    def test_suppression_requires_matching_operation(self):
        with tempfile.TemporaryDirectory() as directory:
            watcher = UploadWatcher.__new__(UploadWatcher)
            watcher.suppress_dir = Path(directory)
            relative = "folder/report.docx"
            marker = watcher.suppress_dir / (
                hashlib.sha256(relative.encode()).hexdigest() + ".json"
            )
            marker.write_text(json.dumps({"operation": "upload"}))

            self.assertFalse(watcher.suppressed(relative, "delete"))
            self.assertFalse(marker.exists())

    def test_heartbeat_preserves_retrying_state(self):
        watcher = UploadWatcher.__new__(UploadWatcher)
        watcher.reconcile_requested = False
        watcher.pending = {"report.docx": {"last_error": "network unavailable"}}
        watcher.write_health = mock.Mock()

        watcher.heartbeat()

        watcher.write_health.assert_called_once_with(
            "retrying",
            last_path="report.docx",
            error="network unavailable",
        )

    @mock.patch("protonsync_upload_watch.subprocess.run")
    def test_overflow_requests_reconciliation_once(self, run):
        run.return_value.returncode = 0
        watcher = UploadWatcher.__new__(UploadWatcher)
        watcher.reconcile_requested = False
        watcher.reconcile_service = "protonsync-reconcile.service"
        watcher.pending = {}
        watcher.write_health = mock.Mock()

        watcher.request_reconcile()
        watcher.request_reconcile()

        run.assert_called_once_with(
            [
                "systemctl",
                "--user",
                "start",
                "--no-block",
                "protonsync-reconcile.service",
            ],
            check=False,
        )
        watcher.write_health.assert_called_once_with(
            "degraded", error="inotify queue overflow"
        )


if __name__ == "__main__":
    unittest.main()
