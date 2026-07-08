#!/usr/bin/env bash
set -euo pipefail

# protonsync installer
# -------------------------------------------------------------------------
# Sets up fast, event-driven two-way sync of one Proton Drive "Shared with me"
# folder into a local directory on Linux.
#
# Required:
#   SHARE_NAME   Name of the shared item as it appears under Proton Drive
#                "Shared with me" (e.g. SHARE_NAME="Team Files").
#
# Owner mode (for the account that OWNS the folder):
#   OWNER_MODE=1 Sync a folder that lives under YOUR OWN "My files" in Proton
#                Drive instead of one shared with you. SHARE_NAME is then the
#                folder name under "My files" (e.g. the person who shared the
#                folder with everyone else runs: SHARE_NAME="Team Files"
#                OWNER_MODE=1 ./install.sh).
#
# Common optional settings (see README.md for the full list):
#   LOCAL_DIR              Local target folder (default: ~/Proton Drive/$SHARE_NAME)
#   REMOTE_NAME            rclone remote name (default: protondrive)
#   RCLONE_BINARY          Path to the protonsync-rclone binary
#   UPLOAD_DEBOUNCE        Seconds to wait before uploading a local change (default: 5)
#   EVENT_POLL_INTERVAL    Remote event poll interval (default: 15s)
#   AUDIT_MODE=1           Enable an OPT-IN scheduled full-sync audit (default: off)
#   AUDIT_CALENDAR         systemd OnCalendar for the audit (default: weekly, Sun 08:00)
# -------------------------------------------------------------------------

REMOTE_NAME="${REMOTE_NAME:-protondrive}"
SHARE_NAME="${SHARE_NAME:-}"
UPLOAD_DEBOUNCE="${UPLOAD_DEBOUNCE:-5}"
EVENT_POLL_INTERVAL="${EVENT_POLL_INTERVAL:-15s}"
AUDIT_MODE="${AUDIT_MODE:-0}"
AUDIT_CALENDAR="${AUDIT_CALENDAR:-Sun *-*-* 08:00:00}"
OWNER_MODE="${OWNER_MODE:-0}"

if [[ -z "$SHARE_NAME" ]]; then
    cat >&2 <<'MSG'
SHARE_NAME is required.

Set it to the name of the folder shared with your Proton account, exactly as it
appears under Proton Drive "Shared with me". For example:

    SHARE_NAME="Team Files" ./install.sh

MSG
    exit 1
fi

LOCAL_DIR="${LOCAL_DIR:-$HOME/Proton Drive/$SHARE_NAME}"
if [[ "$OWNER_MODE" == "1" ]]; then
    # The folder lives under this account's own "My files" root.
    REMOTE_DIR="${REMOTE_NAME}:${SHARE_NAME}"
else
    REMOTE_DIR="${REMOTE_NAME},shared_with_me=true:${SHARE_NAME}"
fi
PROTON_DIR="$HOME/Proton Drive"
PROTON_BOOKMARK="file://${PROTON_DIR// /%20} Proton Drive"

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Locate the custom rclone binary (shipped via GitHub Releases or built locally).
RCLONE_BINARY="${RCLONE_BINARY:-}"
if [[ -z "$RCLONE_BINARY" ]]; then
    for candidate in \
        "$KIT_DIR/protonsync-rclone" \
        "$KIT_DIR/rclone-build/protonsync-rclone"; do
        if [[ -x "$candidate" ]]; then
            RCLONE_BINARY="$candidate"
            break
        fi
    done
fi
if [[ -z "$RCLONE_BINARY" || ! -x "$RCLONE_BINARY" ]]; then
    cat >&2 <<'MSG'
Could not find the protonsync-rclone binary.

Do one of the following, then run ./install.sh again:
  * Download "protonsync-rclone" from the project's GitHub Releases page and put
    it next to install.sh, or
  * Build it with: ./rclone-build/build.sh
  * Or set RCLONE_BINARY=/path/to/protonsync-rclone

MSG
    exit 1
fi

WATCHER_SOURCE="$KIT_DIR/src/protonsync_upload_watch.py"
AUDIT_SOURCE="$KIT_DIR/src/protonsync_audit.py"

RCLONE="$HOME/.local/bin/protonsync-rclone"
SYNC_SCRIPT="$HOME/.local/bin/protonsync-bisync"
AUDIT_SCRIPT="$HOME/.local/lib/protonsync/protonsync-audit.py"
WATCHER="$HOME/.local/lib/protonsync/protonsync-upload-watch.py"
WATCHER_SCRIPT="$HOME/.local/bin/protonsync-upload-watch"
EVENT_SCRIPT="$HOME/.local/bin/protonsync-event-watch"
RECONCILE_SCRIPT="$HOME/.local/bin/protonsync-reconcile"
FILTER_FILE="$HOME/.config/rclone/protonsync-bisync-filter.txt"
SERVICE_FILE="$HOME/.config/systemd/user/protonsync-bisync.service"
TIMER_FILE="$HOME/.config/systemd/user/protonsync-bisync.timer"
WATCHER_SERVICE_FILE="$HOME/.config/systemd/user/protonsync-upload-watch.service"
EVENT_SERVICE_FILE="$HOME/.config/systemd/user/protonsync-event-watch.service"
RECONCILE_SERVICE_FILE="$HOME/.config/systemd/user/protonsync-reconcile.service"
WORK_DIR="$HOME/.cache/protonsync/bisync"
LOG_FILE="$HOME/.local/state/protonsync-bisync.log"
AUDIT_LOG_FILE="$HOME/.local/state/protonsync-bisync-audit.log"
RUN_LOG_DIR="$HOME/.local/state/protonsync-bisync-runs"
WATCHER_LOG_FILE="$HOME/.local/state/protonsync-upload-watch.log"
EVENT_LOG_FILE="$HOME/.local/state/protonsync-event-watch.log"
EVENT_STATE_FILE="$HOME/.local/state/protonsync-events.json"
UPLOAD_QUEUE_FILE="$HOME/.local/state/protonsync-upload-queue.json"
DIRTY_DIR="$HOME/.local/state/protonsync-dirty"
SUPPRESS_DIR="$HOME/.local/state/protonsync-suppress"
RECOVERY_DIR="$HOME/.local/state/protonsync-recovery"
UPLOAD_HEALTH_FILE="$HOME/.local/state/protonsync-upload-health.json"
EVENT_HEALTH_FILE="$HOME/.local/state/protonsync-event-health.json"
FALLBACK_MARKER="$HOME/.local/state/protonsync-event-refresh-required"
LOCK_FILE="$HOME/.cache/protonsync/proton-drive-api.lock"
STATUS_SCRIPT="$HOME/.local/bin/protonsync-status"
HEALTH_SCRIPT="$HOME/.local/bin/protonsync-health"
HEALTH_SERVICE_FILE="$HOME/.config/systemd/user/protonsync-health.service"
HEALTH_TIMER_FILE="$HOME/.config/systemd/user/protonsync-health.timer"

if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
    echo "This package requires 64-bit Linux (x86_64/amd64)." >&2
    exit 1
fi

if [[ ! -f "$WATCHER_SOURCE" ]]; then
    echo "Missing watcher: $WATCHER_SOURCE" >&2
    exit 1
fi

if [[ ! -f "$AUDIT_SOURCE" ]]; then
    echo "Missing audit script: $AUDIT_SOURCE" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Python 3 is required for local change monitoring." >&2
    exit 1
fi

mkdir -p "$HOME/.local/bin" "$HOME/.local/lib/protonsync" \
    "$HOME/.config/rclone" "$HOME/.config/systemd/user" \
    "$HOME/.cache/protonsync" "$HOME/.local/state" \
    "$DIRTY_DIR" "$SUPPRESS_DIR" "$RECOVERY_DIR" \
    "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0" "$LOCAL_DIR"
install -m 0755 "$RCLONE_BINARY" "$RCLONE"
install -m 0755 "$WATCHER_SOURCE" "$WATCHER"
install -m 0755 "$AUDIT_SOURCE" "$AUDIT_SCRIPT"

if ! "$RCLONE" listremotes | grep -qx "${REMOTE_NAME}:"; then
    echo
    echo "Proton remote '${REMOTE_NAME}:' is not configured."
    echo "Run: $RCLONE config"
    echo "Create a Proton Drive remote named '${REMOTE_NAME}', log in with your own"
    echo "Proton account, then run ./install.sh again."
    exit 2
fi

if [[ ! -e "$WORK_DIR" ]] && find "$LOCAL_DIR" -mindepth 1 -print -quit | grep -q .; then
    echo "First installation requires an empty local folder:" >&2
    echo "  $LOCAL_DIR" >&2
    echo "Move existing files elsewhere, then run the installer again." >&2
    echo "(This protects any files already in that folder from being overwritten.)" >&2
    exit 4
fi

echo "Checking access to the Proton folder '$SHARE_NAME'..."
if ! "$RCLONE" lsf "$REMOTE_DIR" --max-depth 1 >/dev/null; then
    echo "Could not access: $REMOTE_DIR" >&2
    if [[ "$OWNER_MODE" == "1" ]]; then
        echo "Make sure the folder '$SHARE_NAME' exists under 'My files' in your Proton Drive." >&2
    else
        echo "Make sure '$SHARE_NAME' is visible under your Proton 'Shared with me'." >&2
    fi
    exit 3
fi

if ! "$RCLONE" protonwatch --help >/dev/null; then
    echo "This rclone build does not contain the Proton event watcher." >&2
    exit 5
fi

if [[ ! -f "$FILTER_FILE" ]] || \
    ! compgen -G "$WORK_DIR/*.path1.lst" >/dev/null || \
    ! compgen -G "$WORK_DIR/*.path2.lst" >/dev/null; then
    cat >"$FILTER_FILE" <<'FILTER'
- **/.~*.insyncdl
- **/.~lock.*#
- **/~$*
- **/.DS_Store
- **/Thumbs.db
# If a file in the shared folder fails Proton PGP signature verification
# ("signature made by unknown entity", typically uploaded by another member)
# and aborts the initial bisync, exclude it here ("- /path/to/file") and
# restart the bisync. The event watchers skip such files on their own.
FILTER
fi

cat >"$SYNC_SCRIPT" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

RCLONE="$RCLONE"
LOCAL_DIR="$LOCAL_DIR"
REMOTE_DIR="$REMOTE_DIR"
WORK_DIR="$WORK_DIR"
LOG_FILE="$LOG_FILE"
AUDIT_LOG_FILE="$AUDIT_LOG_FILE"
RUN_LOG_DIR="$RUN_LOG_DIR"
AUDIT_SCRIPT="$AUDIT_SCRIPT"
FILTER_FILE="$FILTER_FILE"
LOCK_FILE="$LOCK_FILE"

mkdir -p "\$LOCAL_DIR" "\$WORK_DIR" "\$RUN_LOG_DIR" \
    "\$(dirname "\$LOG_FILE")" "\$(dirname "\$LOCK_FILE")"

EXTRA_ARGS=()
if ! compgen -G "\$WORK_DIR/*.path1.lst" >/dev/null || ! compgen -G "\$WORK_DIR/*.path2.lst" >/dev/null; then
    EXTRA_ARGS=(--resync --resync-mode path2)
fi

RUN_ID="\$(date +%Y%m%d-%H%M%S)"
RUN_LOG="\$RUN_LOG_DIR/bisync-\$RUN_ID.log"
STARTED="\$(date --iso-8601=seconds)"

set +e
flock "\$LOCK_FILE" "\$RCLONE" bisync "\$LOCAL_DIR" "\$REMOTE_DIR" \
    "\${EXTRA_ARGS[@]}" \
    --filters-file "\$FILTER_FILE" \
    --compare size,checksum \
    --create-empty-src-dirs \
    --resilient \
    --recover \
    --conflict-resolve none \
    --conflict-loser num \
    --conflict-suffix protonsync-conflict \
    --workdir "\$WORK_DIR" \
    --log-file "\$RUN_LOG" \
    --log-level INFO
status=\$?
set -e

FINISHED="\$(date --iso-8601=seconds)"
[[ -f "\$RUN_LOG" ]] && cat "\$RUN_LOG" >>"\$LOG_FILE"
if ! /usr/bin/python3 "\$AUDIT_SCRIPT" \
    --run-log "\$RUN_LOG" \
    --audit-log "\$AUDIT_LOG_FILE" \
    --started "\$STARTED" \
    --finished "\$FINISHED" \
    --status "\$status"; then
    printf '%s Audit report generation failed for %s\n' "\$FINISHED" "\$RUN_LOG" >>"\$AUDIT_LOG_FILE"
fi
exit "\$status"
SCRIPT
chmod 0755 "$SYNC_SCRIPT"

cat >"$WATCHER_SCRIPT" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

exec /usr/bin/python3 "$WATCHER" \
    --local-dir "$LOCAL_DIR" \
    --remote "$REMOTE_DIR" \
    --rclone "$RCLONE" \
    --lock-file "$LOCK_FILE" \
    --queue-file "$UPLOAD_QUEUE_FILE" \
    --dirty-dir "$DIRTY_DIR" \
    --suppress-dir "$SUPPRESS_DIR" \
    --health-file "$UPLOAD_HEALTH_FILE" \
    --reconcile-service "protonsync-reconcile.service" \
    --debounce "$UPLOAD_DEBOUNCE"
SCRIPT
chmod 0755 "$WATCHER_SCRIPT"

cat >"$RECONCILE_SCRIPT" <<SCRIPT
#!/usr/bin/env bash
set -u

STATE_FILE="$EVENT_STATE_FILE"
FALLBACK_MARKER="$FALLBACK_MARKER"
SUPPRESS_DIR="$SUPPRESS_DIR"
status=0

systemctl --user stop protonsync-upload-watch.service protonsync-event-watch.service || status=\$?
if systemctl --user start protonsync-bisync.service; then
    rm -f "\$STATE_FILE" "\$FALLBACK_MARKER"
    rm -f "\$SUPPRESS_DIR"/*.json 2>/dev/null || true
else
    status=\$?
fi
systemctl --user start protonsync-upload-watch.service protonsync-event-watch.service || status=\$?
exit "\$status"
SCRIPT
chmod 0755 "$RECONCILE_SCRIPT"

cat >"$EVENT_SCRIPT" <<SCRIPT
#!/usr/bin/env bash
set -u

RCLONE="$RCLONE"
REMOTE_DIR="$REMOTE_DIR"
LOCAL_DIR="$LOCAL_DIR"
STATE_FILE="$EVENT_STATE_FILE"
LOCK_FILE="$LOCK_FILE"
FALLBACK_MARKER="$FALLBACK_MARKER"
DIRTY_DIR="$DIRTY_DIR"
SUPPRESS_DIR="$SUPPRESS_DIR"
RECOVERY_DIR="$RECOVERY_DIR"
HEALTH_FILE="$EVENT_HEALTH_FILE"
UPLOAD_QUEUE_FILE="$UPLOAD_QUEUE_FILE"
POLL_INTERVAL="$EVENT_POLL_INTERVAL"
LOG_FILE="$EVENT_LOG_FILE"

mkdir -p "\$(dirname "\$STATE_FILE")" "\$(dirname "\$LOCK_FILE")" "\$(dirname "\$LOG_FILE")"

FALLBACK_COUNT=0
LAST_FALLBACK=0

while true; do
    rm -f "\$FALLBACK_MARKER"
    "\$RCLONE" protonwatch "\$REMOTE_DIR" "\$LOCAL_DIR" \
        --state-file "\$STATE_FILE" \
        --lock-file "\$LOCK_FILE" \
        --fallback-marker "\$FALLBACK_MARKER" \
        --dirty-dir "\$DIRTY_DIR" \
        --suppress-dir "\$SUPPRESS_DIR" \
        --recovery-dir "\$RECOVERY_DIR" \
        --health-file "\$HEALTH_FILE" \
        --poll-interval "\$POLL_INTERVAL" \
        --log-level INFO >>"\$LOG_FILE" 2>&1
    status=\$?

    if [[ -e "\$FALLBACK_MARKER" ]]; then
        # Recover WITHOUT a full bisync: drop the event anchor so the next run
        # rebuilds the index from the current latest event, skipping whatever
        # event could not be applied. The upload queue and dirty/suppress
        # markers are left intact so pending local changes are never lost.
        printf '%s Event watcher could not continue (status %s); re-anchoring event stream without bisync.\\n' \
            "\$(date --iso-8601=seconds)" "\$status" >>"\$LOG_FILE"
        rm -f "\$STATE_FILE" "\$FALLBACK_MARKER"
        now=\$(date +%s)
        if (( now - LAST_FALLBACK < 1800 )); then
            FALLBACK_COUNT=\$(( FALLBACK_COUNT + 1 ))
        else
            FALLBACK_COUNT=1
        fi
        LAST_FALLBACK=\$now
        # Back off if re-anchoring keeps happening, so a persistently broken
        # event can never pin the CPU with back-to-back re-indexes.
        backoff=\$(( FALLBACK_COUNT * 60 ))
        (( backoff > 900 )) && backoff=900
        sleep "\$backoff"
    else
        printf '%s Event watcher stopped unexpectedly (status %s).\\n' \
            "\$(date --iso-8601=seconds)" "\$status" >>"\$LOG_FILE"
        sleep 10
    fi
done
SCRIPT
chmod 0755 "$EVENT_SCRIPT"

cat >"$STATUS_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
set -u

STATE="$HOME/.local/state"
printf 'protonsync status\n\n'
for unit in \
    protonsync-upload-watch.service \
    protonsync-event-watch.service \
    protonsync-bisync.timer \
    protonsync-health.timer; do
    printf '%-40s %s\n' "$unit" "$(systemctl --user is-active "$unit" 2>/dev/null || true)"
done

printf '\nQueue: '
python3 - "$STATE/protonsync-upload-queue.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
try:
    print(f"{len(json.loads(p.read_text()))} pending")
except FileNotFoundError:
    print("0 pending")
except Exception as error:
    print(f"ERROR: {error}")
PY

for health in upload event; do
    file="$STATE/protonsync-${health}-health.json"
    printf '\n%s health:\n' "$health"
    if [[ -f "$file" ]]; then
        cat "$file"
        printf '\n'
    else
        printf 'not available\n'
    fi
done

printf '\nRecovery copies: '
find "$STATE/protonsync-recovery" -type f 2>/dev/null | wc -l
printf 'Last full sync:\n'
tail -n 3 "$STATE/protonsync-bisync.log" 2>/dev/null || true
printf '\nLast audit:\n'
tail -n 18 "$STATE/protonsync-bisync-audit.log" 2>/dev/null || printf 'not available\n'
SCRIPT
chmod 0755 "$STATUS_SCRIPT"

cat >"$HEALTH_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

STATE="$HOME/.local/state"
LOCAL_DIR="${PROTONSYNC_LOCAL_DIR:-$HOME/Proton Drive}"
failed=0

for unit in protonsync-upload-watch.service protonsync-event-watch.service; do
    if ! systemctl --user is-active --quiet "$unit"; then
        printf 'ERROR: %s is not active\n' "$unit"
        failed=1
    fi
done

for unit in protonsync-bisync.service protonsync-reconcile.service; do
    if systemctl --user is-failed --quiet "$unit"; then
        printf 'ERROR: %s is failed\n' "$unit"
        failed=1
    fi
done

free_kb=$(df -Pk "$LOCAL_DIR" | awk 'NR==2 {print $4}')
if [[ "${free_kb:-0}" -lt 5242880 ]]; then
    printf 'ERROR: less than 5 GiB free on local filesystem\n'
    failed=1
fi

now=$(date +%s)
for file in "$STATE/protonsync-upload-health.json" "$STATE/protonsync-event-health.json"; do
    if [[ ! -f "$file" ]]; then
        printf 'ERROR: missing health file %s\n' "$file"
        failed=1
        continue
    fi
    modified=$(stat -c %Y "$file")
    if (( now - modified > 600 )); then
        printf 'ERROR: stale health file %s\n' "$file"
        failed=1
    fi
    status=$(python3 - "$file" <<'PY'
import json
import pathlib
import sys

try:
    print(json.loads(pathlib.Path(sys.argv[1]).read_text())["status"])
except Exception:
    print("invalid")
PY
)
    case "$status" in
        ok|starting|queued) ;;
        *)
            printf 'ERROR: unhealthy status %s in %s\n' "$status" "$file"
            failed=1
            ;;
    esac
done

for log in "$STATE"/protonsync-*.log; do
    [[ -f "$log" ]] || continue
    size=$(stat -c %s "$log")
    if (( size > 10485760 )); then
        cp -f "$log" "$log.1"
        : >"$log"
    fi
done

exit "$failed"
SCRIPT
chmod 0755 "$HEALTH_SCRIPT"

cat >"$SERVICE_FILE" <<SERVICE
[Unit]
Description=Full bisync of the shared Proton Drive folder (initial sync and repair)
Documentation=https://rclone.org/bisync/
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=$SYNC_SCRIPT
SERVICE

cat >"$WATCHER_SERVICE_FILE" <<SERVICE
[Unit]
Description=Upload local changes to the shared Proton Drive folder
After=network-online.target protonsync-bisync.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$WATCHER_SCRIPT
Restart=on-failure
RestartSec=10s
StandardOutput=append:$WATCHER_LOG_FILE
StandardError=append:$WATCHER_LOG_FILE

[Install]
WantedBy=default.target
SERVICE

cat >"$EVENT_SERVICE_FILE" <<SERVICE
[Unit]
Description=Download changes from the shared Proton Drive folder via events
After=network-online.target protonsync-bisync.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$EVENT_SCRIPT
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=default.target
SERVICE

cat >"$RECONCILE_SERVICE_FILE" <<SERVICE
[Unit]
Description=Reconcile after lost local filesystem events
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=$RECONCILE_SCRIPT
SERVICE

cat >"$HEALTH_SERVICE_FILE" <<SERVICE
[Unit]
Description=Check protonsync health

[Service]
Type=oneshot
Environment="PROTONSYNC_LOCAL_DIR=$LOCAL_DIR"
ExecStart=$HEALTH_SCRIPT
SERVICE

cat >"$HEALTH_TIMER_FILE" <<TIMER
[Unit]
Description=Check protonsync health every five minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
TIMER

# Optional, opt-in scheduled full-sync audit. Disabled by default; the fast
# event sync plus on-demand repair is enough for normal operation.
if [[ "$AUDIT_MODE" == "1" ]]; then
    cat >"$TIMER_FILE" <<TIMER
[Unit]
Description=Scheduled protonsync safety audit (opt-in)

[Timer]
OnCalendar=$AUDIT_CALENDAR
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
TIMER
else
    rm -f "$TIMER_FILE"
fi

systemctl --user daemon-reload
for unit in \
    protonsync-bisync.service \
    protonsync-upload-watch.service \
    protonsync-event-watch.service \
    protonsync-reconcile.service \
    protonsync-health.service; do
    systemctl --user reset-failed "$unit" 2>/dev/null || true
done

systemctl --user disable --now protonsync-upload-watch.service 2>/dev/null || true
systemctl --user disable --now protonsync-event-watch.service 2>/dev/null || true
echo "Performing the initial full download of '$SHARE_NAME' before enabling monitoring..."
# Unmask first in case a previous run masked these (see below), so the one-time
# initial bisync can still run when install.sh is re-run.
systemctl --user unmask protonsync-bisync.service protonsync-reconcile.service >/dev/null 2>&1 || true
systemctl --user daemon-reload
systemctl --user start protonsync-bisync.service
systemctl --user enable --now protonsync-upload-watch.service
systemctl --user enable --now protonsync-event-watch.service
systemctl --user enable --now protonsync-health.timer
if [[ "$AUDIT_MODE" == "1" ]]; then
    systemctl --user enable --now protonsync-bisync.timer
else
    systemctl --user disable --now protonsync-bisync.timer 2>/dev/null || true
fi

# The one-time initial download above is done. From here the sync is purely
# event-driven: the event watcher recovers by re-anchoring the event stream
# (never a full bisync), so the reconcile-via-bisync path is redundant. Mask
# both bisync units so nothing — reconcile trigger, timer, or manual start —
# can launch a full bisync again. To run a full repair later, unmask first:
#   systemctl --user unmask protonsync-bisync.service && \
#       systemctl --user start protonsync-bisync.service
if [[ "$AUDIT_MODE" != "1" ]]; then
    systemctl --user mask protonsync-bisync.service protonsync-reconcile.service >/dev/null 2>&1 || true
fi

for bookmarks_file in \
    "$HOME/.config/gtk-3.0/bookmarks" \
    "$HOME/.config/gtk-4.0/bookmarks"; do
    touch "$bookmarks_file"
    if ! grep -Fqx "$PROTON_BOOKMARK" "$bookmarks_file"; then
        printf '%s\n' "$PROTON_BOOKMARK" >>"$bookmarks_file"
    fi
done

echo
echo "Installation complete."
if [[ "$OWNER_MODE" == "1" ]]; then
    echo "Folder (My files):    $SHARE_NAME  (owner mode)"
else
    echo "Shared folder:        $SHARE_NAME"
fi
echo "Local folder:         $LOCAL_DIR"
echo "Local upload delay:   about $UPLOAD_DEBOUNCE seconds"
echo "Event poll interval:  $EVENT_POLL_INTERVAL"
if [[ "$AUDIT_MODE" == "1" ]]; then
    echo "Scheduled audit:      enabled ($AUDIT_CALENDAR)"
else
    echo "Scheduled audit:      disabled (event-driven sync only; full bisync masked)"
fi
echo "Status command:       $STATUS_SCRIPT"
echo "Recovery copies:      $RECOVERY_DIR"
