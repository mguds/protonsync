# Architecture

protonsync is an event-driven desktop sync client for a single Proton Drive
"Shared with me" folder on Linux. It combines a patched rclone build (Go) with
Python `inotify` monitoring and systemd user services.

## Components

### Local → Proton (upload)

`protonsync_upload_watch.py` uses Linux `inotify` to detect create, save
(`IN_CLOSE_WRITE`), move and delete events. Changes are written to a persistent
JSON queue and uploaded with the custom rclone binary. The queue and per-path
"dirty" markers survive restarts and network failures, so nothing is lost if the
machine reboots mid-upload.

### Proton → Local (download)

The new rclone command `protonwatch` (Go) reads Proton Drive's change-event
stream and downloads only the items that changed. The last event ID and an index
of remote items are stored on disk, so a machine can catch up on changes that
happened while it was offline.

### Conflict and deletion handling

All sync operations on one machine take a shared file lock, so they never write
concurrently. A remote event that overlaps a pending local change aborts and
triggers a conservative full-sync repair. Files deleted via a remote event are
first moved to a dated recovery folder. Simultaneous edits of the same file
across machines still cannot be merged automatically — see
[CONCURRENT-EDITING.md](CONCURRENT-EDITING.md).

### Safety net (full bisync)

A full two-way `rclone bisync` runs in exactly two situations:

1. **Initial download** on first install (`--resync --resync-mode path2`).
2. **Automatic repair** on a concrete failure: conflicting change, expired event
   stream, or `inotify` queue overflow / lost events. The event watcher and the
   reconcile service stop the watchers, run one bisync, and restart the watchers.

bisync uses `--compare size,checksum`, `--conflict-resolve none` and
`--conflict-loser num` so conflicts keep both versions rather than overwriting.

There is **no** periodic full sync by default. An opt-in scheduled audit
(`AUDIT_MODE=1`) can run a full bisync on a chosen `OnCalendar` and write a
human-readable audit report; it is disabled by default.

## systemd units

Always-on services:

- `protonsync-upload-watch.service` — local → Proton
- `protonsync-event-watch.service` — Proton → local

On-demand / triggered:

- `protonsync-bisync.service` — initial download and repair bisync
- `protonsync-reconcile.service` — recovery after lost local events

Timers:

- `protonsync-health.timer` — health check every 5 minutes
- `protonsync-bisync.timer` — **only** created when `AUDIT_MODE=1`

## On-disk locations

| Purpose | Path |
|---|---|
| Binaries / wrappers | `~/.local/bin/` |
| Python components | `~/.local/lib/protonsync/` |
| rclone config | `~/.config/rclone/` |
| systemd units | `~/.config/systemd/user/` |
| State, queue, logs | `~/.local/state/protonsync-*` |
| bisync work dir | `~/.cache/protonsync/bisync` |
| Recovery copies | `~/.local/state/protonsync-recovery/` |

## Health monitoring

`protonsync-health` checks that both watchers are active, that the repair
services have not failed, that there is at least 5 GiB free, and that the health
heartbeat files are fresh and report a healthy status. Logs larger than 10 MiB
are rotated. Failures are recorded in the systemd journal and health files;
there is no central alerting — for a fleet of machines you should add your own
(email, dashboard, etc.).

## Known limitations

- Symbolic links are ignored.
- Event polling is not server push; latency is roughly the poll interval plus
  transfer time.
- The first event index requires one full Proton listing and can take minutes.
- Large files must finish transferring before the next operation gets the lock.
- This is an unofficial Proton Drive integration; Proton API changes may require
  rebuilding the binary.
