#!/usr/bin/env bash
set -euo pipefail

# convert-to-sync-all.sh — convert an EXISTING single-folder protonsync
# installation (SHARE_NAME="Some Folder") to the sync-everything setup:
#
#   * account has the folders under "Shared with me"  -> EVERYTHING under
#     Shared with me is synced, one folder = one local folder under
#     ~/Proton Drive/<folder name>
#   * account OWNS the folders (OWNER_MODE)           -> the WHOLE "My files"
#     tree is synced to ~/Proton Drive
#
# The script detects which of the two variants the old installation used and
# picks the matching sync-everything variant.
#
# Local files are NOT re-downloaded: the folder that is already in sync is
# reused where it is (moved into place under ~/Proton Drive if needed), and
# the first bisync only checksums it against Proton.
#
# Run from the protonsync kit (same folder as install.sh):
#   ./convert-to-sync-all.sh
#
# Before running:
#   * The upload queue must be empty (protonsync-status shows "0 pending").
#     The script refuses to run otherwise, so no local change is ever lost.

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HOME/.local/state"
UNIT_DIR="$HOME/.config/systemd/user"
OLD_WRAPPER="$HOME/.local/bin/protonsync-upload-watch"

if [[ ! -x "$KIT_DIR/install.sh" ]]; then
    echo "install.sh was not found next to this script." >&2
    exit 1
fi

if [[ ! -f "$OLD_WRAPPER" ]]; then
    echo "No existing protonsync installation found (missing $OLD_WRAPPER)." >&2
    echo "On a fresh machine, use ./install.sh directly (without SHARE_NAME for sync-everything)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Read the old configuration out of the generated wrapper.
# ---------------------------------------------------------------------------
old_remote="$(sed -nE 's/^[[:space:]]*--remote "(.*)" \\$/\1/p' "$OLD_WRAPPER" | head -1)"
old_local="$(sed -nE 's/^[[:space:]]*--local-dir "(.*)" \\$/\1/p' "$OLD_WRAPPER" | head -1)"
if [[ -z "$old_remote" || -z "$old_local" ]]; then
    echo "Could not read the old configuration from $OLD_WRAPPER." >&2
    exit 1
fi

if [[ "$old_remote" == *",shared_with_me=true:"* ]]; then
    OLD_MODE="shared"
    old_share="${old_remote#*,shared_with_me=true:}"
else
    OLD_MODE="owner"
    old_share="${old_remote#*:}"
fi

echo "Found existing installation:"
echo "  Proton folder: $old_share ($([[ $OLD_MODE == owner ]] && echo 'owner / My files' || echo 'shared / Shared with me'))"
echo "  Local folder:  $old_local"
echo
if [[ "$OLD_MODE" == "owner" ]]; then
    echo "Converting to: EVERYTHING under 'My files' -> ~/Proton Drive"
else
    echo "Converting to: EVERYTHING under 'Shared with me' -> ~/Proton Drive/<folder name>"
fi
echo

# ---------------------------------------------------------------------------
# Safety: no pending local uploads.
# ---------------------------------------------------------------------------
queue_pending=$(python3 - "$STATE_DIR/protonsync-upload-queue.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
try:
    print(len(json.loads(p.read_text())))
except Exception:
    print(0)
PY
)
dirty_pending=$( (find "$STATE_DIR/protonsync-dirty" -type f 2>/dev/null || true) | wc -l)
if [[ "$queue_pending" -gt 0 || "$dirty_pending" -gt 0 ]]; then
    echo "There are local changes that have not been uploaded yet" >&2
    echo "(queue: $queue_pending, markers: $dirty_pending)." >&2
    echo "Let the services run until protonsync-status shows '0 pending', then retry." >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Stop and remove the old installation (files are kept).
# ---------------------------------------------------------------------------
echo "Stopping and removing the old installation (local files are kept)..."
"$KIT_DIR/uninstall.sh"

# The old event/queue state belongs to the old remote pair and is cleared so
# the new setup builds fresh state. Recovery copies and logs are kept.
rm -f "$STATE_DIR"/protonsync-events*.json \
    "$STATE_DIR"/protonsync-upload-queue*.json \
    "$STATE_DIR"/protonsync-event-refresh-required* \
    "$STATE_DIR"/protonsync-upload-health*.json \
    "$STATE_DIR"/protonsync-event-health*.json
rm -rf "$STATE_DIR"/protonsync-dirty* "$STATE_DIR"/protonsync-suppress* \
    "$HOME/.cache/protonsync"/bisync*

# ---------------------------------------------------------------------------
# Make sure the old local folder sits where the sync-everything layout
# expects it.
# ---------------------------------------------------------------------------
PROTON_DIR="$HOME/Proton Drive"
target="$PROTON_DIR/$old_share"
if [[ "$old_local" != "$target" && -d "$old_local" ]]; then
    if [[ -e "$target" ]]; then
        echo "Both '$old_local' and '$target' exist — clean up manually and retry." >&2
        exit 3
    fi
    echo "Moving '$old_local' -> '$target'..."
    mkdir -p "$PROTON_DIR"
    mv "$old_local" "$target"
fi

# ---------------------------------------------------------------------------
# Install the sync-everything setup. ALLOW_EXISTING=1 because the files are
# already local — the first bisync checksums them instead of re-downloading.
# ---------------------------------------------------------------------------
echo
echo "Installing the sync-everything setup..."
if [[ "$OLD_MODE" == "owner" ]]; then
    SHARE_NAME="" OWNER_MODE=1 ALLOW_EXISTING=1 "$KIT_DIR/install.sh"
else
    SHARE_NAME="" ALLOW_EXISTING=1 "$KIT_DIR/install.sh"
fi

echo
echo "Conversion complete. Check with: protonsync-status"
