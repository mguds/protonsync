#!/usr/bin/env bash
set -euo pipefail

# Removes the protonsync program components and systemd units — including any
# per-folder instances created by a sync-everything install (unit and script
# names carry a "-<folder>" suffix).
# It does NOT delete your local files, Proton configuration, sync state,
# upload queue, recovery copies or logs.

UNIT_DIR="$HOME/.config/systemd/user"

# Stop and disable every protonsync unit (also unmask, so masked bisync units
# from event-only installs are fully removed).
for unit_file in "$UNIT_DIR"/protonsync-*.timer "$UNIT_DIR"/protonsync-*.service; do
    [[ -e "$unit_file" || -L "$unit_file" ]] || continue
    unit="$(basename "$unit_file")"
    systemctl --user disable --now "$unit" 2>/dev/null || true
    systemctl --user stop "$unit" 2>/dev/null || true
    systemctl --user unmask "$unit" 2>/dev/null || true
    rm -f "$unit_file"
done

rm -f \
    "$HOME/.local/bin/protonsync-rclone" \
    "$HOME/.local/bin"/protonsync-bisync* \
    "$HOME/.local/bin"/protonsync-upload-watch* \
    "$HOME/.local/bin"/protonsync-event-watch* \
    "$HOME/.local/bin"/protonsync-reconcile* \
    "$HOME/.local/bin/protonsync-status" \
    "$HOME/.local/bin/protonsync-health" \
    "$HOME/.local/lib/protonsync/protonsync-upload-watch.py" \
    "$HOME/.local/lib/protonsync/protonsync-audit.py" \
    "$HOME/.config/rclone"/protonsync-bisync-filter*.txt \
    "$HOME/.config/rclone"/protonsync-bisync-filter*.txt.md5
systemctl --user daemon-reload
systemctl --user reset-failed 2>/dev/null || true
echo "protonsync components were removed."
echo "Local files, sync state and Proton configuration were preserved."
