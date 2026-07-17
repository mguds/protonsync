#!/usr/bin/env bash
set -euo pipefail

# protonsync installer
# -------------------------------------------------------------------------
# Sets up fast, event-driven two-way sync between Proton Drive and local
# directories on Linux.
#
# What to sync:
#   SHARE_NAME   Name of ONE item as it appears under Proton Drive
#                "Shared with me" (e.g. SHARE_NAME="Team Files"), or under
#                "My files" with OWNER_MODE=1.
#
#   If SHARE_NAME is EMPTY, EVERYTHING is synced:
#     * default:       every FOLDER under "Shared with me" gets its own sync
#                      instance under ~/Proton Drive/<folder name>. Items that
#                      are single files are skipped (with a note).
#     * OWNER_MODE=1:  the whole "My files" tree, into ~/Proton Drive.
#   Re-run ./install.sh later to pick up folders shared with you after the
#   first install.
#
# Owner mode (for the account that OWNS the folder):
#   OWNER_MODE=1 Sync a folder that lives under YOUR OWN "My files" in Proton
#                Drive instead of one shared with you. SHARE_NAME is then the
#                folder name under "My files" (e.g. the person who shared the
#                folder with everyone else runs: SHARE_NAME="Team Files"
#                OWNER_MODE=1 ./install.sh).
#
# Common optional settings (see README.md for the full list):
#   LOCAL_DIR              Local target folder (default: ~/Proton Drive/$SHARE_NAME;
#                          single-folder and owner-all installs only)
#   REMOTE_NAME            rclone remote name (default: protondrive)
#   RCLONE_BINARY          Path to the protonsync-rclone binary
#   UPLOAD_DEBOUNCE        Seconds to wait before uploading a local change (default: 5)
#   EVENT_POLL_INTERVAL    Remote event poll interval (default: 15s)
#   AUDIT_MODE=1           Enable an OPT-IN scheduled full-sync audit
#                          (default: off; single-folder installs only)
#   AUDIT_CALENDAR         systemd OnCalendar for the audit (default: weekly, Sun 08:00)
#   ALLOW_EXISTING=1       Skip the "local folder must be empty" first-install
#                          check. Only for conversions where the local files
#                          are ALREADY a copy of the Proton folder (bisync then
#                          just checksums them instead of re-downloading).
#   SKIP_INITIAL_SYNC=1    Do not run the initial bisync at all — enable the
#                          watchers directly. Only for conversions where the
#                          local files are known to be in sync already; the
#                          event stream is anchored at "now".
# -------------------------------------------------------------------------

REMOTE_NAME="${REMOTE_NAME:-protondrive}"
SHARE_NAME="${SHARE_NAME:-}"
UPLOAD_DEBOUNCE="${UPLOAD_DEBOUNCE:-5}"
EVENT_POLL_INTERVAL="${EVENT_POLL_INTERVAL:-15s}"
AUDIT_MODE="${AUDIT_MODE:-0}"
AUDIT_CALENDAR="${AUDIT_CALENDAR:-Sun *-*-* 08:00:00}"
OWNER_MODE="${OWNER_MODE:-0}"
LOCAL_DIR_OVERRIDE="${LOCAL_DIR:-}"

# MODE: single (one named folder), owner-all (all of "My files"),
# shared-all (every folder in "Shared with me", one instance per folder).
if [[ -n "$SHARE_NAME" ]]; then
    MODE="single"
elif [[ "$OWNER_MODE" == "1" ]]; then
    MODE="owner-all"
else
    MODE="shared-all"
fi

if [[ "$MODE" != "single" && "$AUDIT_MODE" == "1" ]]; then
    echo "Note: AUDIT_MODE is only supported for single-folder installs; ignoring it." >&2
    AUDIT_MODE="0"
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

# Shared (mode-independent) locations.
RCLONE="$HOME/.local/bin/protonsync-rclone"
AUDIT_SCRIPT="$HOME/.local/lib/protonsync/protonsync-audit.py"
WATCHER="$HOME/.local/lib/protonsync/protonsync-upload-watch.py"
LOCK_FILE="$HOME/.cache/protonsync/proton-drive-api.lock"
STATUS_SCRIPT="$HOME/.local/bin/protonsync-status"
HEALTH_SCRIPT="$HOME/.local/bin/protonsync-health"
HEALTH_SERVICE_FILE="$HOME/.config/systemd/user/protonsync-health.service"
HEALTH_TIMER_FILE="$HOME/.config/systemd/user/protonsync-health.timer"
UNIT_DIR="$HOME/.config/systemd/user"
STATE_DIR="$HOME/.local/state"


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
    "$HOME/.config/rclone" "$UNIT_DIR" \
    "$HOME/.cache/protonsync" "$STATE_DIR" \
    "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"
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

if ! "$RCLONE" protonwatch --help >/dev/null; then
    echo "This rclone build does not contain the Proton event watcher." >&2
    exit 5
fi

# ---------------------------------------------------------------------------
# Build the list of sync instances: parallel arrays of share names and slugs.
# The empty slug uses the historical unsuffixed file/unit names, so existing
# single-folder installs keep exactly the same layout when re-run.
# ---------------------------------------------------------------------------
SHARE_NAMES=()
SHARE_SLUGS=()

slugify() {
    # systemd unit names must be ASCII, so transliterate the Norwegian letters
    # and replace anything else non-alphanumeric with '-'.
    # Literal (non-bracket) substitutions match the UTF-8 byte sequences and
    # therefore work in any locale, including plain C.
    local s
    s=$(printf '%s' "$1" | sed 's/Æ/ae/g; s/æ/ae/g; s/Ø/o/g; s/ø/o/g; s/Å/a/g; s/å/a/g')
    s=$(printf '%s' "$s" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
        | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
    [[ -z "$s" ]] && s="share"
    printf '%s' "$s"
}

add_share() {
    local name="$1" slug="$2" candidate n=2
    candidate="$slug"
    if [[ -n "$slug" ]]; then
        while printf '%s\n' "${SHARE_SLUGS[@]:-}" | grep -qx "$candidate"; do
            candidate="$slug-$n"
            n=$(( n + 1 ))
        done
    fi
    SHARE_NAMES+=("$name")
    SHARE_SLUGS+=("$candidate")
}

case "$MODE" in
single)
    add_share "$SHARE_NAME" ""
    ;;
owner-all)
    # Owner-all defaults to ~/Proton Drive as its local root. If per-share
    # sync-everything instances already live under that folder, require a
    # separate LOCAL_DIR so the two installs never watch the same files.
    OWNER_TARGET="${LOCAL_DIR_OVERRIDE:-$PROTON_DIR}"
    if compgen -G "$UNIT_DIR/protonsync-upload-watch-*.service" >/dev/null && \
        { [[ "$OWNER_TARGET" == "$PROTON_DIR" || "$OWNER_TARGET" == "$PROTON_DIR/"* || "$PROTON_DIR" == "$OWNER_TARGET/"* ]]; }; then
        cat >&2 <<MSG
This machine already syncs shared folders into "$PROTON_DIR". An owner-all
install must then use its own separate local folder, for example:

  OWNER_MODE=1 LOCAL_DIR="\$HOME/Proton Drive - My files" ./install.sh
MSG
        exit 7
    fi
    if [[ -f "$HOME/.local/bin/protonsync-upload-watch" ]] && \
        ! grep -qF -- "--remote \"${REMOTE_NAME}:\"" "$HOME/.local/bin/protonsync-upload-watch"; then
        cat >&2 <<MSG
An existing protonsync installation that syncs a DIFFERENT Proton folder was
found on this machine. Switching it to sync everything under "My files" in
place is not safe.

Run ./uninstall.sh first (your local files, sync state and Proton login are
preserved), move the old local folder out of "$PROTON_DIR", then run
OWNER_MODE=1 ./install.sh again.
MSG
        exit 7
    fi
    add_share "" ""
    ;;
shared-all)
    # An unsuffixed install (single folder, or owner-all) may already exist.
    # That is fine as long as its local folder does not overlap ~/Proton Drive,
    # where the per-share instances live — e.g. an owner-all install with
    # LOCAL_DIR="$HOME/Proton Drive - My files" can coexist with shared-all.
    if [[ -f "$UNIT_DIR/protonsync-upload-watch.service" ]]; then
        existing_local="$(grep -oE -- '--local-dir "[^"]+"' "$HOME/.local/bin/protonsync-upload-watch" 2>/dev/null \
            | head -1 | sed -E 's/^--local-dir "//; s/"$//')"
        if [[ -z "$existing_local" || "$existing_local" == "$PROTON_DIR" || "$existing_local" == "$PROTON_DIR/"* ]]; then
            cat >&2 <<MSG
An existing protonsync installation on this machine syncs
  ${existing_local:-<unknown>}
which overlaps the folders a sync-everything install would create under
"$PROTON_DIR". Watching the same files twice is not safe.

Either convert it with ./convert-to-sync-all.sh, or run ./uninstall.sh first
(your local files, sync state and Proton login are preserved).

Tip: to combine "everything I own" AND "everything shared with me" on one
machine, give the owner install its own separate folder first:
  OWNER_MODE=1 LOCAL_DIR="\$HOME/Proton Drive - My files" ./install.sh
then run ./install.sh (no SHARE_NAME) for the shared folders.
MSG
            exit 7
        fi
        echo "Existing install at '$existing_local' does not overlap — keeping it alongside."
    fi
    if ! "$RCLONE" protonshares --help >/dev/null 2>&1; then
        echo "This rclone build does not contain the protonshares command." >&2
        echo "Update protonsync-rclone to the latest release, then retry." >&2
        exit 5
    fi
    echo "Listing everything under Proton Drive 'Shared with me'..."
    SHARES_RAW="$("$RCLONE" protonshares "${REMOTE_NAME}:")"
    while IFS=$'\t' read -r kind name; do
        [[ -z "${name:-}" ]] && continue
        if [[ "$kind" != "d" ]]; then
            echo "Skipping shared item '$name' (single files are not synced; only folders)."
            continue
        fi
        add_share "$name" "$(slugify "$name")"
    done <<<"$SHARES_RAW"
    if [[ ${#SHARE_NAMES[@]} -eq 0 ]]; then
        echo "No shared folders were found under 'Shared with me' for this account." >&2
        echo "Accept the shares in Proton Drive first, then run ./install.sh again." >&2
        exit 3
    fi
    echo "Found ${#SHARE_NAMES[@]} shared folder(s):"
    printf '  %s\n' "${SHARE_NAMES[@]}"
    ;;
esac

# ---------------------------------------------------------------------------
# Per-share variables. set_share_vars <index> populates the SHARE/SFX/... set
# used by all the generators below.
# ---------------------------------------------------------------------------
set_share_vars() {
    local idx="$1"
    SHARE="${SHARE_NAMES[$idx]}"
    local slug="${SHARE_SLUGS[$idx]}"
    SFX=""
    [[ -n "$slug" ]] && SFX="-$slug"

    case "$MODE" in
    single)
        if [[ -n "$LOCAL_DIR_OVERRIDE" ]]; then
            LOCAL_DIR="$LOCAL_DIR_OVERRIDE"
        else
            LOCAL_DIR="$PROTON_DIR/$SHARE"
        fi
        if [[ "$OWNER_MODE" == "1" ]]; then
            REMOTE_DIR="${REMOTE_NAME}:${SHARE}"
        else
            REMOTE_DIR="${REMOTE_NAME},shared_with_me=true:${SHARE}"
        fi
        SHARE_LABEL="$SHARE"
        ;;
    owner-all)
        LOCAL_DIR="${LOCAL_DIR_OVERRIDE:-$PROTON_DIR}"
        REMOTE_DIR="${REMOTE_NAME}:"
        SHARE_LABEL="My files (everything)"
        ;;
    shared-all)
        LOCAL_DIR="$PROTON_DIR/$SHARE"
        REMOTE_DIR="${REMOTE_NAME},shared_with_me=true:${SHARE}"
        SHARE_LABEL="$SHARE"
        ;;
    esac

    SYNC_SCRIPT="$HOME/.local/bin/protonsync-bisync$SFX"
    WATCHER_SCRIPT="$HOME/.local/bin/protonsync-upload-watch$SFX"
    EVENT_SCRIPT="$HOME/.local/bin/protonsync-event-watch$SFX"
    RECONCILE_SCRIPT="$HOME/.local/bin/protonsync-reconcile$SFX"
    FILTER_FILE="$HOME/.config/rclone/protonsync-bisync-filter$SFX.txt"
    SERVICE_FILE="$UNIT_DIR/protonsync-bisync$SFX.service"
    TIMER_FILE="$UNIT_DIR/protonsync-bisync$SFX.timer"
    WATCHER_SERVICE_FILE="$UNIT_DIR/protonsync-upload-watch$SFX.service"
    EVENT_SERVICE_FILE="$UNIT_DIR/protonsync-event-watch$SFX.service"
    RECONCILE_SERVICE_FILE="$UNIT_DIR/protonsync-reconcile$SFX.service"
    WORK_DIR="$HOME/.cache/protonsync/bisync$SFX"
    LOG_FILE="$STATE_DIR/protonsync-bisync$SFX.log"
    AUDIT_LOG_FILE="$STATE_DIR/protonsync-bisync-audit$SFX.log"
    RUN_LOG_DIR="$STATE_DIR/protonsync-bisync-runs$SFX"
    WATCHER_LOG_FILE="$STATE_DIR/protonsync-upload-watch$SFX.log"
    EVENT_LOG_FILE="$STATE_DIR/protonsync-event-watch$SFX.log"
    EVENT_STATE_FILE="$STATE_DIR/protonsync-events$SFX.json"
    UPLOAD_QUEUE_FILE="$STATE_DIR/protonsync-upload-queue$SFX.json"
    DIRTY_DIR="$STATE_DIR/protonsync-dirty$SFX"
    SUPPRESS_DIR="$STATE_DIR/protonsync-suppress$SFX"
    RECOVERY_DIR="$STATE_DIR/protonsync-recovery$SFX"
    UPLOAD_HEALTH_FILE="$STATE_DIR/protonsync-upload-health$SFX.json"
    EVENT_HEALTH_FILE="$STATE_DIR/protonsync-event-health$SFX.json"
    FALLBACK_MARKER="$STATE_DIR/protonsync-event-refresh-required$SFX"
}

# ---------------------------------------------------------------------------
# Validate every instance before anything is generated or started.
# ---------------------------------------------------------------------------
for i in "${!SHARE_NAMES[@]}"; do
    set_share_vars "$i"
    mkdir -p "$LOCAL_DIR" "$DIRTY_DIR" "$SUPPRESS_DIR" "$RECOVERY_DIR"

    if [[ "${ALLOW_EXISTING:-0}" != "1" ]] && [[ ! -e "$WORK_DIR" ]] && \
        find "$LOCAL_DIR" -mindepth 1 -print -quit | grep -q .; then
        echo "First installation requires an empty local folder:" >&2
        echo "  $LOCAL_DIR" >&2
        echo "Move existing files elsewhere, then run the installer again." >&2
        echo "(This protects any files already in that folder from being overwritten.)" >&2
        echo "(Converting from an existing install? Use ./convert-to-sync-all.sh," >&2
        echo " or set ALLOW_EXISTING=1 if you know the files match the Proton folder.)" >&2
        exit 4
    fi

    if [[ "$MODE" != "shared-all" ]]; then
        echo "Checking access to the Proton folder '${SHARE_LABEL}'..."
        if ! "$RCLONE" lsf "$REMOTE_DIR" --max-depth 1 >/dev/null; then
            echo "Could not access: $REMOTE_DIR" >&2
            if [[ "$OWNER_MODE" == "1" ]]; then
                echo "Make sure the folder exists under 'My files' in your Proton Drive." >&2
            else
                echo "Make sure '$SHARE' is visible under your Proton 'Shared with me'." >&2
            fi
            exit 3
        fi
    fi
done

# ---------------------------------------------------------------------------
# Generators (use the variables set by set_share_vars).
# ---------------------------------------------------------------------------
write_share_filter() {
    # Only (re)write the filter before the first bisync, so manual additions
    # (e.g. files excluded after signature errors) survive re-runs.
    if [[ -f "$FILTER_FILE" ]] && \
        compgen -G "$WORK_DIR/*.path1.lst" >/dev/null && \
        compgen -G "$WORK_DIR/*.path2.lst" >/dev/null; then
        return 0
    fi
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
}

generate_share_scripts() {
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
    --reconcile-service "protonsync-reconcile$SFX.service" \
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

systemctl --user stop protonsync-upload-watch$SFX.service protonsync-event-watch$SFX.service || status=\$?
if systemctl --user start protonsync-bisync$SFX.service; then
    rm -f "\$STATE_FILE" "\$FALLBACK_MARKER"
    rm -f "\$SUPPRESS_DIR"/*.json 2>/dev/null || true
else
    status=\$?
fi
systemctl --user start protonsync-upload-watch$SFX.service protonsync-event-watch$SFX.service || status=\$?
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
}

generate_share_units() {
    # A previous event-only install leaves the bisync/reconcile unit names as
    # /dev/null symlinks (masked) with the real files parked as *.locked.
    # Remove both first, so the fresh units below become real files instead of
    # being written through the symlink into /dev/null.
    rm -f "$SERVICE_FILE" "$SERVICE_FILE.locked" \
        "$RECONCILE_SERVICE_FILE" "$RECONCILE_SERVICE_FILE.locked" \
        "$WATCHER_SERVICE_FILE" "$EVENT_SERVICE_FILE"

    cat >"$SERVICE_FILE" <<SERVICE
[Unit]
Description=Full bisync of Proton folder '${SHARE_LABEL}' (initial sync and repair)
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
Description=Upload local changes to Proton folder '${SHARE_LABEL}'
After=network-online.target protonsync-bisync$SFX.service
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
Description=Download changes from Proton folder '${SHARE_LABEL}' via events
After=network-online.target protonsync-bisync$SFX.service
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
Description=Reconcile '${SHARE_LABEL}' after lost local filesystem events
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=$RECONCILE_SCRIPT
SERVICE

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
}

for i in "${!SHARE_NAMES[@]}"; do
    set_share_vars "$i"
    write_share_filter
    generate_share_scripts
    generate_share_units
done

# ---------------------------------------------------------------------------
# Shared status/health tooling. Both discover every instance dynamically from
# the generated unit files, so they work for single and sync-everything
# installs alike.
# ---------------------------------------------------------------------------
cat >"$STATUS_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
set -u

STATE="$HOME/.local/state"
UNITS="$HOME/.config/systemd/user"
printf 'protonsync status\n\n'
for unit_file in \
    "$UNITS"/protonsync-upload-watch*.service \
    "$UNITS"/protonsync-event-watch*.service \
    "$UNITS"/protonsync-bisync*.timer \
    "$UNITS"/protonsync-health.timer; do
    [[ -f "$unit_file" ]] || continue
    unit="$(basename "$unit_file")"
    printf '%-55s %s\n' "$unit" "$(systemctl --user is-active "$unit" 2>/dev/null || true)"
done

printf '\nQueues:\n'
found_queue=0
for queue in "$STATE"/protonsync-upload-queue*.json; do
    [[ -f "$queue" ]] || continue
    found_queue=1
    printf '%-55s ' "$(basename "$queue")"
    python3 - "$queue" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
try:
    print(f"{len(json.loads(p.read_text()))} pending")
except FileNotFoundError:
    print("0 pending")
except Exception as error:
    print(f"ERROR: {error}")
PY
done
[[ "$found_queue" == 0 ]] && printf '0 pending\n'

for health in "$STATE"/protonsync-upload-health*.json "$STATE"/protonsync-event-health*.json; do
    [[ -f "$health" ]] || continue
    printf '\n%s:\n' "$(basename "$health")"
    cat "$health"
    printf '\n'
done

printf '\nRecovery copies: '
find "$STATE"/protonsync-recovery* -type f 2>/dev/null | wc -l
printf 'Last full sync:\n'
for log in "$STATE"/protonsync-bisync*.log; do
    [[ -f "$log" ]] || continue
    [[ "$log" == *-audit*.log ]] && continue
    printf '--- %s ---\n' "$(basename "$log")"
    tail -n 3 "$log" 2>/dev/null || true
done
printf '\nLast audit:\n'
shown_audit=0
for log in "$STATE"/protonsync-bisync-audit*.log; do
    [[ -f "$log" ]] || continue
    shown_audit=1
    printf '--- %s ---\n' "$(basename "$log")"
    tail -n 18 "$log" 2>/dev/null || true
done
[[ "$shown_audit" == 0 ]] && printf 'not available\n'
SCRIPT
chmod 0755 "$STATUS_SCRIPT"

cat >"$HEALTH_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

STATE="$HOME/.local/state"
UNITS="$HOME/.config/systemd/user"
LOCAL_DIR="${PROTONSYNC_LOCAL_DIR:-$HOME/Proton Drive}"
failed=0

for unit_file in "$UNITS"/protonsync-upload-watch*.service "$UNITS"/protonsync-event-watch*.service; do
    [[ -f "$unit_file" ]] || continue
    unit="$(basename "$unit_file")"
    if ! systemctl --user is-active --quiet "$unit"; then
        printf 'ERROR: %s is not active\n' "$unit"
        failed=1
    fi
done

for unit_file in "$UNITS"/protonsync-bisync*.service "$UNITS"/protonsync-reconcile*.service; do
    [[ -f "$unit_file" ]] || continue
    unit="$(basename "$unit_file")"
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
found_health=0
for file in "$STATE"/protonsync-upload-health*.json "$STATE"/protonsync-event-health*.json; do
    [[ -f "$file" ]] || continue
    found_health=1
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
if [[ "$found_health" == 0 ]]; then
    printf 'ERROR: no protonsync health files found\n'
    failed=1
fi

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

if [[ "$MODE" == "single" ]]; then
    HEALTH_DF_DIR="$LOCAL_DIR"
else
    HEALTH_DF_DIR="$PROTON_DIR"
fi

cat >"$HEALTH_SERVICE_FILE" <<SERVICE
[Unit]
Description=Check protonsync health

[Service]
Type=oneshot
Environment="PROTONSYNC_LOCAL_DIR=$HEALTH_DF_DIR"
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

systemctl --user daemon-reload
for i in "${!SHARE_NAMES[@]}"; do
    set_share_vars "$i"
    for unit in \
        "protonsync-bisync$SFX.service" \
        "protonsync-upload-watch$SFX.service" \
        "protonsync-event-watch$SFX.service" \
        "protonsync-reconcile$SFX.service"; do
        systemctl --user reset-failed "$unit" 2>/dev/null || true
    done
done
systemctl --user reset-failed protonsync-health.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# One instance at a time: initial full download, then enable the watchers.
# ---------------------------------------------------------------------------
FAILED_SHARES=()
for i in "${!SHARE_NAMES[@]}"; do
    set_share_vars "$i"

    systemctl --user disable --now "protonsync-upload-watch$SFX.service" 2>/dev/null || true
    systemctl --user disable --now "protonsync-event-watch$SFX.service" 2>/dev/null || true
    # The unit files were rewritten as real files above; make sure systemd
    # forgets any old mask state before they are used.
    systemctl --user unmask "protonsync-bisync$SFX.service" "protonsync-reconcile$SFX.service" >/dev/null 2>&1 || true
    systemctl --user daemon-reload
    if [[ "${SKIP_INITIAL_SYNC:-0}" == "1" ]]; then
        echo "Skipping the initial sync of '${SHARE_LABEL}' (SKIP_INITIAL_SYNC=1; local files assumed in sync)."
    else
        echo "Performing the initial full download of '${SHARE_LABEL}' before enabling monitoring..."
        if ! systemctl --user start "protonsync-bisync$SFX.service"; then
            echo "Initial sync of '${SHARE_LABEL}' FAILED — see $LOG_FILE" >&2
            FAILED_SHARES+=("${SHARE_LABEL}")
            continue
        fi
    fi
    systemctl --user enable --now "protonsync-upload-watch$SFX.service"
    systemctl --user enable --now "protonsync-event-watch$SFX.service"
    if [[ "$AUDIT_MODE" == "1" ]]; then
        systemctl --user enable --now "protonsync-bisync$SFX.timer"
    else
        systemctl --user disable --now "protonsync-bisync$SFX.timer" 2>/dev/null || true
    fi

    # The one-time initial download above is done. From here the sync is purely
    # event-driven: the event watcher recovers by re-anchoring the event stream
    # (never a full bisync), so the reconcile-via-bisync path is redundant. Mask
    # both bisync units so nothing — reconcile trigger, timer, or manual start —
    # can launch a full bisync again. Plain "systemctl mask" refuses when the
    # real unit file lives in ~/.config/systemd/user, so park the real file as
    # *.locked and point the unit name at /dev/null. To run a full repair later:
    #   u=~/.config/systemd/user/protonsync-bisync<suffix>.service
    #   rm "$u" && mv "$u.locked" "$u" && systemctl --user daemon-reload \
    #       && systemctl --user start protonsync-bisync<suffix>.service
    if [[ "$AUDIT_MODE" != "1" ]]; then
        for unit_file in "$SERVICE_FILE" "$RECONCILE_SERVICE_FILE"; do
            if [[ -f "$unit_file" && ! -L "$unit_file" ]]; then
                mv "$unit_file" "$unit_file.locked"
                ln -sfn /dev/null "$unit_file"
            fi
        done
        systemctl --user daemon-reload
    fi
done
systemctl --user enable --now protonsync-health.timer

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
case "$MODE" in
single)
    if [[ "$OWNER_MODE" == "1" ]]; then
        echo "Folder (My files):    $SHARE_NAME  (owner mode)"
    else
        echo "Shared folder:        $SHARE_NAME"
    fi
    echo "Local folder:         $LOCAL_DIR"
    ;;
owner-all)
    echo "Syncing:              everything under 'My files' (owner mode)"
    echo "Local folder:         $LOCAL_DIR"
    ;;
shared-all)
    echo "Syncing:              every folder under 'Shared with me' (${#SHARE_NAMES[@]} folder(s))"
    printf '  %s\n' "${SHARE_NAMES[@]}"
    echo "Local folders:        $PROTON_DIR/<folder name>"
    echo "New shares later:     re-run ./install.sh to add them"
    ;;
esac
echo "Local upload delay:   about $UPLOAD_DEBOUNCE seconds"
echo "Event poll interval:  $EVENT_POLL_INTERVAL"
if [[ "$AUDIT_MODE" == "1" ]]; then
    echo "Scheduled audit:      enabled ($AUDIT_CALENDAR)"
else
    echo "Scheduled audit:      disabled (event-driven sync only; full bisync masked)"
fi
echo "Status command:       $STATUS_SCRIPT"
echo "Recovery copies:      $STATE_DIR/protonsync-recovery*"

if [[ ${#FAILED_SHARES[@]} -gt 0 ]]; then
    echo
    echo "WARNING: the initial sync failed for:" >&2
    printf '  %s\n' "${FAILED_SHARES[@]}" >&2
    echo "Fix the cause (see the log referenced above), then re-run ./install.sh." >&2
    exit 6
fi
