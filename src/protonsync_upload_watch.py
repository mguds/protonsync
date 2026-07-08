#!/usr/bin/env python3
"""Persistently queue and upload local Proton Drive changes."""

from __future__ import annotations

import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import logging
import os
import select
import struct
import subprocess
import sys
import time
from pathlib import Path

IN_CLOSE_WRITE = 0x00000008
IN_MOVED_FROM = 0x00000040
IN_MOVED_TO = 0x00000080
IN_CREATE = 0x00000100
IN_DELETE = 0x00000200
IN_DELETE_SELF = 0x00000400
IN_MOVE_SELF = 0x00000800
IN_Q_OVERFLOW = 0x00004000
IN_IGNORED = 0x00008000
IN_ISDIR = 0x40000000
IN_ONLYDIR = 0x01000000
IN_DONT_FOLLOW = 0x02000000
WATCH_MASK = (
    IN_CLOSE_WRITE
    | IN_MOVED_FROM
    | IN_MOVED_TO
    | IN_CREATE
    | IN_DELETE
    | IN_DELETE_SELF
    | IN_MOVE_SELF
    | IN_ONLYDIR
    | IN_DONT_FOLLOW
)
EVENT_HEADER = struct.Struct("iIII")


class Inotify:
    def __init__(self) -> None:
        libc = ctypes.CDLL(None, use_errno=True)
        self._add_watch = libc.inotify_add_watch
        self._add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
        self._add_watch.restype = ctypes.c_int
        self.fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))

    def add(self, path: Path) -> int:
        wd = self._add_watch(self.fd, os.fsencode(path), WATCH_MASK)
        if wd < 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), path)
        return wd

    def close(self) -> None:
        os.close(self.fd)


def ignored(relative_path: Path) -> bool:
    for part in relative_path.parts:
        if part in {".DS_Store", "Thumbs.db"}:
            return True
        if part.startswith(".~") and part.endswith(".insyncdl"):
            return True
        if part.startswith(".~lock.") and part.endswith("#"):
            return True
        if part.startswith("~$"):
            return True
        if part.endswith((".partial", ".tmp")):
            return True
    return False


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=True, indent=2, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


class UploadWatcher:
    def __init__(self, args: argparse.Namespace) -> None:
        self.root = Path(args.local_dir).expanduser().resolve()
        self.remote = args.remote.rstrip("/")
        self.rclone = args.rclone
        self.lock_file = Path(args.lock_file).expanduser()
        self.queue_file = Path(args.queue_file).expanduser()
        self.dirty_dir = Path(args.dirty_dir).expanduser()
        self.suppress_dir = Path(args.suppress_dir).expanduser()
        self.health_file = Path(args.health_file).expanduser()
        self.reconcile_service = args.reconcile_service
        self.debounce = args.debounce
        self.inotify = Inotify()
        self.watch_paths: dict[int, Path] = {}
        self.pending: dict[str, dict[str, object]] = {}
        self.last_health = 0.0
        self.reconcile_requested = False
        self.load_queue()

    def load_queue(self) -> None:
        try:
            value = json.loads(self.queue_file.read_text(encoding="utf-8"))
            if isinstance(value, dict):
                self.pending = value
        except FileNotFoundError:
            pass
        except (OSError, json.JSONDecodeError):
            logging.exception("Queue is unreadable; preserving it and starting empty")
            if self.queue_file.exists():
                backup = self.queue_file.with_suffix(
                    self.queue_file.suffix + f".corrupt-{int(time.time())}"
                )
                self.queue_file.replace(backup)
        now = time.time()
        for item in self.pending.values():
            item["next_attempt"] = min(float(item.get("next_attempt", now)), now)
        self.persist_queue()
        self.refresh_dirty_markers()

    def persist_queue(self) -> None:
        atomic_json(self.queue_file, self.pending)

    def marker_path(self, relative: str) -> Path:
        digest = hashlib.sha256(relative.encode("utf-8")).hexdigest()
        return self.dirty_dir / f"{digest}.json"

    def suppressed(self, relative: str, operation: str) -> bool:
        digest = hashlib.sha256(relative.encode("utf-8")).hexdigest()
        marker = self.suppress_dir / f"{digest}.json"
        try:
            age = time.time() - marker.stat().st_mtime
            value = json.loads(marker.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return False
        except (OSError, json.JSONDecodeError):
            logging.exception("Suppression marker is unreadable: %s", marker)
            marker.unlink(missing_ok=True)
            return False
        marker.unlink(missing_ok=True)
        marker_operation = value.get("operation", "upload")
        if age <= 120 and marker_operation == operation:
            logging.info(
                "Suppressing remote-originated local %s: %s", operation, relative
            )
            return True
        return False

    def mark_dirty(self, relative: str) -> None:
        atomic_json(self.marker_path(relative), {"path": relative})

    def clear_dirty(self, relative: str) -> None:
        self.marker_path(relative).unlink(missing_ok=True)

    def refresh_dirty_markers(self) -> None:
        self.dirty_dir.mkdir(parents=True, exist_ok=True)
        expected = {self.marker_path(relative) for relative in self.pending}
        for marker in self.dirty_dir.glob("*.json"):
            if marker not in expected:
                marker.unlink(missing_ok=True)
        for relative in self.pending:
            self.mark_dirty(relative)

    def write_health(self, status: str, **extra: object) -> None:
        value = {
            "status": status,
            "updated": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "pending": len(self.pending),
            **extra,
        }
        atomic_json(self.health_file, value)
        self.last_health = time.monotonic()

    def heartbeat(self) -> None:
        if self.reconcile_requested:
            self.write_health("degraded", error="inotify queue overflow")
            return
        for relative, item in self.pending.items():
            if item.get("last_error"):
                self.write_health(
                    "retrying",
                    last_path=relative,
                    error=str(item["last_error"]),
                )
                return
        self.write_health("ok")

    def request_reconcile(self) -> None:
        if self.reconcile_requested:
            return
        self.reconcile_requested = True
        self.write_health("degraded", error="inotify queue overflow")
        result = subprocess.run(
            [
                "systemctl",
                "--user",
                "start",
                "--no-block",
                self.reconcile_service,
            ],
            check=False,
        )
        if result.returncode:
            logging.error(
                "Could not start reconciliation service %s (exit %s)",
                self.reconcile_service,
                result.returncode,
            )

    def add_tree(self, root: Path) -> None:
        if root.is_symlink() or not root.is_dir():
            return
        for current, directories, _files in os.walk(root, followlinks=False):
            current_path = Path(current)
            directories[:] = [
                name
                for name in directories
                if not (current_path / name).is_symlink()
                and not ignored((current_path / name).relative_to(self.root))
            ]
            self.add_watch(current_path)

    def add_watch(self, path: Path) -> None:
        try:
            self.watch_paths[self.inotify.add(path)] = path
        except OSError as error:
            if error.errno not in {errno.ENOENT, errno.ENOTDIR, errno.EACCES}:
                raise
            logging.warning("Could not watch %s: %s", path, error)

    def queue(self, path: Path, is_dir: bool, operation: str = "upload") -> None:
        try:
            relative_path = path.relative_to(self.root)
        except ValueError:
            return
        if relative_path == Path(".") or ignored(relative_path):
            return
        relative = relative_path.as_posix()
        if self.suppressed(relative, operation):
            return
        self.pending[relative] = {
            "is_dir": is_dir,
            "operation": operation,
            "next_attempt": time.time() + self.debounce,
            "attempts": 0,
        }
        if operation == "delete" and is_dir:
            prefix = relative.rstrip("/") + "/"
            for child in list(self.pending):
                if child.startswith(prefix):
                    self.pending.pop(child, None)
                    self.clear_dirty(child)
        self.mark_dirty(relative)
        self.persist_queue()
        self.write_health("queued", last_path=relative)

    def remote_path(self, relative: str) -> str:
        return f"{self.remote}/{relative}"

    @staticmethod
    def snapshot(path: Path) -> tuple[int, int] | None:
        try:
            stat = path.stat()
            return stat.st_size, stat.st_mtime_ns
        except FileNotFoundError:
            return None

    def run_rclone(
        self,
        command: list[str],
        relative: str,
        action: str = "Uploading",
        success_codes: tuple[int, ...] = (0,),
    ) -> int:
        self.lock_file.parent.mkdir(parents=True, exist_ok=True)
        with self.lock_file.open("a+") as lock:
            logging.info("Waiting for sync lock: %s", relative)
            fcntl.flock(lock, fcntl.LOCK_EX)
            logging.info("%s local change: %s", action, relative)
            result = subprocess.run(command, check=False)
            if result.returncode not in success_codes:
                raise RuntimeError(
                    f"rclone failed with exit code {result.returncode}: {relative}"
                )
            return result.returncode

    def upload(self, relative: str, is_dir: bool) -> bool:
        local_path = self.root / Path(relative)
        if local_path.is_symlink() or not local_path.exists():
            logging.info("Dropping deleted or symbolic queued path: %s", relative)
            return True
        before = self.snapshot(local_path)
        common = [
            "--retries",
            "3",
            "--low-level-retries",
            "10",
            "--retries-sleep",
            "5s",
            "--log-level",
            "INFO",
        ]
        if is_dir or local_path.is_dir():
            command = [self.rclone, "mkdir", self.remote_path(relative), *common]
        elif local_path.is_file():
            command = [
                self.rclone,
                "copyto",
                str(local_path),
                self.remote_path(relative),
                "--checksum",
                "--no-traverse",
                *common,
            ]
        else:
            return True
        self.run_rclone(command, relative)
        after = self.snapshot(local_path)
        if before != after:
            logging.info("Path changed during upload; keeping queued: %s", relative)
            return False
        if is_dir or local_path.is_dir():
            try:
                for child in local_path.iterdir():
                    self.queue(child, is_dir=child.is_dir())
            except OSError:
                logging.exception("Could not scan new directory: %s", relative)
        return True

    def delete(self, relative: str, is_dir: bool) -> bool:
        local_path = self.root / Path(relative)
        if local_path.exists() or local_path.is_symlink():
            logging.info("Deleted path was recreated; uploading instead: %s", relative)
            return self.upload(relative, local_path.is_dir())
        common = [
            "--retries",
            "3",
            "--low-level-retries",
            "10",
            "--retries-sleep",
            "5s",
            "--log-level",
            "INFO",
        ]
        command = [
            self.rclone,
            "purge" if is_dir else "deletefile",
            self.remote_path(relative),
            *common,
        ]
        # rclone exits 3 (directory not found) or 4 (file not found) when the
        # remote path is already gone. For a delete that is the desired end
        # state, not a failure to retry forever, so accept those codes.
        code = self.run_rclone(
            command, relative, action="Deleting", success_codes=(0, 3, 4)
        )
        if code:
            logging.info("Remote path already absent; delete satisfied: %s", relative)
        return True

    def process_pending(self) -> None:
        now = time.time()
        for relative, item in list(self.pending.items()):
            if float(item.get("next_attempt", 0)) > now:
                continue
            try:
                if item.get("operation", "upload") == "delete":
                    complete = self.delete(relative, bool(item.get("is_dir")))
                else:
                    complete = self.upload(relative, bool(item.get("is_dir")))
                if complete:
                    self.pending.pop(relative, None)
                    self.clear_dirty(relative)
                    self.persist_queue()
                    self.write_health("ok", last_path=relative)
                else:
                    item["next_attempt"] = time.time() + self.debounce
                    self.persist_queue()
            except Exception as error:
                logging.exception("Upload failed; retrying with backoff: %s", relative)
                attempts = int(item.get("attempts", 0)) + 1
                delay = min(900, 5 * (2 ** min(attempts, 8)))
                item["attempts"] = attempts
                item["next_attempt"] = time.time() + delay
                item["last_error"] = str(error)
                self.persist_queue()
                self.write_health(
                    "retrying",
                    last_path=relative,
                    retry_in_seconds=delay,
                    error=str(error),
                )

    def handle_events(self) -> None:
        try:
            data = os.read(self.inotify.fd, 1024 * 1024)
        except BlockingIOError:
            return
        offset = 0
        while offset + EVENT_HEADER.size <= len(data):
            wd, mask, _cookie, name_length = EVENT_HEADER.unpack_from(data, offset)
            offset += EVENT_HEADER.size
            raw_name = data[offset : offset + name_length]
            offset += name_length
            name = os.fsdecode(raw_name.split(b"\0", 1)[0])
            if mask & IN_Q_OVERFLOW:
                logging.error("inotify queue overflow; requesting full reconciliation")
                self.request_reconcile()
                continue
            if mask & IN_IGNORED:
                self.watch_paths.pop(wd, None)
                continue
            parent = self.watch_paths.get(wd)
            if parent is None:
                continue
            path = parent / name if name else parent
            is_dir = bool(mask & IN_ISDIR)
            if name and mask & (IN_DELETE | IN_MOVED_FROM):
                self.queue(path, is_dir=is_dir, operation="delete")
            elif is_dir and mask & (IN_CREATE | IN_MOVED_TO):
                self.add_tree(path)
                self.queue(path, is_dir=True)
            elif not is_dir and mask & (IN_CLOSE_WRITE | IN_MOVED_TO):
                self.queue(path, is_dir=False)
            if mask & (IN_DELETE_SELF | IN_MOVE_SELF):
                self.watch_paths.pop(wd, None)

    def run(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        self.add_tree(self.root)
        self.write_health("starting")
        logging.info(
            "Watching %s with %d persisted queue item(s)", self.root, len(self.pending)
        )
        poller = select.poll()
        poller.register(self.inotify.fd, select.POLLIN)
        try:
            while True:
                timeout_ms = 1000
                if self.pending:
                    next_attempt = min(
                        float(item.get("next_attempt", 0))
                        for item in self.pending.values()
                    )
                    timeout_ms = max(
                        0, min(1000, int((next_attempt - time.time()) * 1000))
                    )
                if poller.poll(timeout_ms):
                    self.handle_events()
                self.process_pending()
                if time.monotonic() - self.last_health >= 60:
                    self.heartbeat()
        finally:
            self.inotify.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--local-dir", required=True)
    parser.add_argument("--remote", required=True)
    parser.add_argument("--rclone", required=True)
    parser.add_argument("--lock-file", required=True)
    parser.add_argument("--queue-file", required=True)
    parser.add_argument("--dirty-dir", required=True)
    parser.add_argument("--suppress-dir", required=True)
    parser.add_argument("--health-file", required=True)
    parser.add_argument("--reconcile-service", required=True)
    parser.add_argument("--debounce", type=float, default=5.0)
    return parser.parse_args()


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    if sys.platform != "linux":
        logging.error("This watcher requires Linux inotify.")
        return 1
    UploadWatcher(parse_args()).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
