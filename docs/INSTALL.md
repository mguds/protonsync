# Installation guide

This guide installs protonsync for a single Linux user. Repeat it on each
machine and for each person who needs the shared folder. Every user signs in
with their **own** Proton account.

## 1. Prerequisites

- 64-bit Linux (x86_64) with systemd user services enabled
- Python 3 (`python3 --version`)
- A Proton account that can see the target folder under **Shared with me**

## 2. Get the binary

Download `protonsync-rclone` from the project's **Releases** page and place it
in the repository folder next to `install.sh`:

```bash
chmod +x protonsync-rclone install.sh uninstall.sh
```

Or build it from source (requires `git` and Go ≥ 1.25):

```bash
./rclone-build/build.sh
cp rclone-build/protonsync-rclone .
```

## 3. Configure your Proton remote (once)

```bash
./protonsync-rclone config
```

- Choose **n** for a new remote, name it `protondrive`.
- Pick the **Proton Drive** backend.
- Enter your own Proton email and password (and 2FA / mailbox password if you
  use them).
- Answer **n** to advanced configuration and **y** to keep the remote.

Verify the remote can see the shared folder (replace the name with yours):

```bash
./protonsync-rclone lsf "protondrive,shared_with_me=true:Team Files" --max-depth 1
```

If that lists the folder's contents, you're ready.

## 4. Run the installer

```bash
SHARE_NAME="Team Files" ./install.sh
```

What happens:

1. The installer checks that the local target folder
   (`~/Proton Drive/Team Files` by default) is **empty**. If it already contains
   files, the installer stops so nothing is overwritten — move those files
   elsewhere first.
2. It performs a **full initial download** of the shared folder.
3. It enables the two fast watchers and a 5-minute health check.

After this, only the fast event sync runs. There is no periodic full sync.

### Useful options

```bash
# Custom local folder
SHARE_NAME="Team Files" LOCAL_DIR="$HOME/work/team" ./install.sh

# Slower/faster reactions
SHARE_NAME="Team Files" UPLOAD_DEBOUNCE=10 EVENT_POLL_INTERVAL=30s ./install.sh

# Opt-in weekly safety audit (disabled by default)
SHARE_NAME="Team Files" AUDIT_MODE=1 AUDIT_CALENDAR="Sun *-*-* 08:00:00" ./install.sh
```

## 5. Verify

```bash
protonsync-status
systemctl --user status protonsync-upload-watch.service
systemctl --user status protonsync-event-watch.service
```

Both watchers should be **active** and the queue should drain to `0 pending`.

## 6. Day-to-day

- Work in the local folder as usual.
- Saved files reach other machines within seconds.
- Files removed remotely are first copied to
  `~/.local/state/protonsync-recovery/` before being deleted locally.

## Troubleshooting

```bash
# Health and recent activity
protonsync-status
journalctl --user -u protonsync-health.service --since today

# Force a full sync / repair
systemctl --user start protonsync-bisync.service
journalctl --user -fu protonsync-bisync.service
```

If the event stream expires or local events are lost, protonsync automatically
runs a one-off repair bisync — you do not need to schedule one.

## Uninstall

```bash
./uninstall.sh
```

Local files, sync state and your Proton configuration are kept.
