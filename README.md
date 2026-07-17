# protonsync

Fast, event-driven two-way sync of a **Proton Drive "Shared with me" folder**
into a local directory on Linux.

protonsync gives you an Insync-like experience for a single shared Proton Drive
folder: save a file locally and it appears for everyone else within seconds;
someone else's change shows up on your machine within seconds. It is built on a
patched [rclone](https://github.com/rclone/rclone) build plus a small set of
Python and systemd components.

> **Unofficial integration.** protonsync is a community project. It is not
> affiliated with, endorsed by, or supported by Proton AG or the rclone project.
> It talks to Proton Drive through rclone and the (unofficial) Proton API
> libraries. Proton API changes may require updates. Use it at your own risk and
> keep Proton's own version history as a safety net.

## How it works

protonsync runs two lightweight, always-on services per user:

1. **Upload watcher** (`protonsync-upload-watch`) — a Python process that uses
   Linux `inotify` to detect local creates, saves, moves and deletes, queues
   them on disk, and uploads them (default: ~5 seconds after a change).
2. **Event watcher** (`protonsync-event-watch`) — the new `protonwatch` rclone
   command reads Proton Drive's change-event stream and downloads only the items
   that actually changed (default poll: every 15 seconds).

A full two-way `bisync` is used **only** for the **initial download** of the
whole shared folder on first install; the installer then masks the bisync
services. After that recovery is event-based and self-healing: a single event
that cannot be applied is skipped and logged, and a broken or expired event
stream is re-anchored in place (fresh index from "now") with backoff — no full
sync is ever run automatically again.

There is **no** periodic full sync. A scheduled audit sync is available as an
opt-in (`AUDIT_MODE=1`), disabled by default.

## ⚠️ Concurrent editing

protonsync is **not** real-time co-editing. There is no distributed lock and no
automatic merge.

- Multiple people editing **different** files at the same time: fine.
- Two people editing the **same** Word/Excel/CAD/binary file at the same time:
  **not safe** — you can get conflict copies or one revision winning over
  another.

Coordinate who edits a shared file. See
[docs/CONCURRENT-EDITING.md](docs/CONCURRENT-EDITING.md) for details. For true
co-editing, use a document/PDM system designed for it.

## Requirements

- 64-bit Linux (x86_64) with `systemd` user services
- Python 3
- A Proton account that can see the shared folder under **Shared with me**
- The `protonsync-rclone` binary — download it from
  [Releases](../../releases) or build it yourself (see below)

## Install

1. Get the custom rclone binary (`protonsync-rclone`) from the Releases page and
   place it next to `install.sh` (or build it with `./rclone-build/build.sh`).

2. Configure your Proton remote (once):

   ```bash
   ./protonsync-rclone config
   ```

   Create a remote named `protondrive`, log in with **your own** Proton account,
   answer `n` to advanced config and `y` to keep the remote.

3. Run the installer, naming the shared folder you want to sync:

   ```bash
   SHARE_NAME="Team Files" ./install.sh
   ```

   The first run requires an **empty** local target folder and performs a full
   download before the fast watchers start. Existing files are never silently
   overwritten — the installer stops if the target is non-empty.

   **Sync everything instead of one folder?** Leave `SHARE_NAME` out:

   ```bash
   ./install.sh                # every folder under "Shared with me"
   OWNER_MODE=1 ./install.sh   # your whole "My files" (owner account)
   ```

   Each shared folder gets its own local folder under `~/Proton Drive/` and its
   own set of background services; single shared *files* are skipped. Folders
   shared with you later are picked up by re-running `./install.sh`. An
   existing one-folder install is converted — without re-downloading — with
   `./convert-to-sync-all.sh`.

Full walkthrough: [docs/INSTALL.md](docs/INSTALL.md).

## Configuration

Set these as environment variables before `./install.sh`:

| Variable | Default | Description |
|---|---|---|
| `SHARE_NAME` | _(empty = sync everything)_ | Name of ONE shared item under "Shared with me"; leave empty to sync every shared folder (or all of "My files" with `OWNER_MODE=1`) |
| `LOCAL_DIR` | `~/Proton Drive/$SHARE_NAME` | Local target folder (single-folder and owner-everything installs) |
| `ALLOW_EXISTING` | `0` | `1` skips the empty-folder check (conversions; see `convert-to-sync-all.sh`) |
| `SKIP_INITIAL_SYNC` | `0` | `1` skips the initial bisync and starts the watchers directly (conversions where files are already in sync) |
| `REMOTE_NAME` | `protondrive` | rclone remote name |
| `RCLONE_BINARY` | auto-detected | Path to `protonsync-rclone` |
| `UPLOAD_DEBOUNCE` | `5` | Seconds before uploading a local change |
| `EVENT_POLL_INTERVAL` | `15s` | Remote event poll interval |
| `AUDIT_MODE` | `0` | `1` enables an opt-in scheduled audit sync |
| `AUDIT_CALENDAR` | `Sun *-*-* 08:00:00` | `OnCalendar` for the audit (if enabled) |

## Status, logs and recovery

```bash
protonsync-status                 # services, queue, health, last sync
tail -f ~/.local/state/protonsync-upload-watch.log
tail -f ~/.local/state/protonsync-event-watch.log
```

Files deleted via a remote event are first moved to a dated recovery folder at
`~/.local/state/protonsync-recovery/` rather than being removed immediately.

Trigger a manual full sync / repair (the bisync service is masked by default):

```bash
u=~/.config/systemd/user/protonsync-bisync.service   # manual full sync / repair
rm "$u" && mv "$u.locked" "$u" && systemctl --user daemon-reload \
  && systemctl --user start protonsync-bisync.service  # (masked by default; add -<folder> suffix on sync-everything installs)
```

## Build from source

The binary is a patched rclone that adds Proton "Shared with me" support and the
`protonwatch` command. To build it reproducibly:

```bash
cd rclone-build
./build.sh        # clones 3 upstreams at pinned commits, applies patches, builds
```

Requires `git` and Go ≥ 1.25. See [rclone-build/](rclone-build/) and
[pinned-commits.txt](rclone-build/pinned-commits.txt).

## Uninstall

```bash
./uninstall.sh
```

Removes the services and programs. **Local files, sync state and your Proton
configuration are preserved.**

## License

MIT — see [LICENSE](LICENSE). protonsync builds on rclone, Proton-API-Bridge and
go-proton-api, all MIT licensed; see [NOTICE](NOTICE) for attribution.
