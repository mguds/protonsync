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
concurrently. A single remote event that cannot be applied (for example a file
whose PGP signature cannot be verified, or a delete for an item this machine
never had) is skipped and logged, and the event cursor still advances — one bad
event never wedges the stream. Files deleted via a remote event are first moved
to a dated recovery folder. Simultaneous edits of the same file across machines
still cannot be merged automatically — see
[CONCURRENT-EDITING.md](CONCURRENT-EDITING.md).

### Self-healing (no automatic bisync)

A full two-way `rclone bisync` runs exactly once: the **initial download** on
first install (`--resync --resync-mode path2`). After that the installer masks
the bisync and reconcile services, and recovery is event-based:

- **Unapplicable event** → skipped and logged; the stream continues.
- **Genuine Proton `Refresh` event** (server asks clients to resync) → the
  remote index is rebuilt in-process; no bisync.
- **Broken/expired event state** → the event-watch wrapper re-anchors the
  stream in place (deletes the state file and re-indexes from "now") with
  60 s → 900 s backoff.

A manual repair bisync is still possible: unmask `protonsync-bisync.service`
and start it. bisync uses `--compare size,checksum`, `--conflict-resolve none`
and `--conflict-loser num` so conflicts keep both versions rather than
overwriting.

There is **no** periodic full sync. An opt-in scheduled audit (`AUDIT_MODE=1`)
can run a full bisync on a chosen `OnCalendar` and write a human-readable audit
report; it is disabled by default (and when off, the bisync units stay masked).

## systemd units

Always-on services:

- `protonsync-upload-watch.service` — local → Proton
- `protonsync-event-watch.service` — Proton → local

On-demand / triggered:

- `protonsync-bisync.service` — initial download; **masked after install**
  (unmask to run a manual repair)
- `protonsync-reconcile.service` — legacy recovery path; **masked after install**

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
