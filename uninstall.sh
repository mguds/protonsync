#!/usr/bin/env bash
set -euo pipefail

# Removes the protonsync program components and systemd units.
# It does NOT delete your local files, Proton configuration, sync state,
# upload queue, recovery copies or logs.

SERVICE="protonsync-bisync.service"
TIMER="protonsync-bisync.timer"
WATCHER_SERVICE="protonsync-upload-watch.service"
EVENT_SERVICE="protonsync-event-watch.service"
RECONCILE_SERVICE="protonsync-reconcile.service"
HEALTH_TIMER="protonsync-health.timer"

systemctl --user disable --now "$TIMER" 2>/dev/null || true
systemctl --user stop "$SERVICE" 2>/dev/null || true
systemctl --user disable --now "$WATCHER_SERVICE" 2>/dev/null || true
systemctl --user disable --now "$EVENT_SERVICE" 2>/dev/null || true
systemctl --user stop "$RECONCILE_SERVICE" 2>/dev/null || true
systemctl --user disable --now "$HEALTH_TIMER" 2>/dev/null || true
rm -f \
    "$HOME/.config/systemd/user/$SERVICE" \
    "$HOME/.config/systemd/user/$TIMER" \
    "$HOME/.config/systemd/user/$WATCHER_SERVICE" \
    "$HOME/.config/systemd/user/$EVENT_SERVICE" \
    "$HOME/.config/systemd/user/$RECONCILE_SERVICE" \
    "$HOME/.config/systemd/user/protonsync-health.service" \
    "$HOME/.config/systemd/user/$HEALTH_TIMER" \
    "$HOME/.local/bin/protonsync-rclone" \
    "$HOME/.local/bin/protonsync-bisync" \
    "$HOME/.local/bin/protonsync-upload-watch" \
    "$HOME/.local/bin/protonsync-event-watch" \
    "$HOME/.local/bin/protonsync-reconcile" \
    "$HOME/.local/bin/protonsync-status" \
    "$HOME/.local/bin/protonsync-health" \
    "$HOME/.local/lib/protonsync/protonsync-upload-watch.py" \
    "$HOME/.local/lib/protonsync/protonsync-audit.py" \
    "$HOME/.config/rclone/protonsync-bisync-filter.txt" \
    "$HOME/.config/rclone/protonsync-bisync-filter.txt.md5"
systemctl --user daemon-reload
systemctl --user reset-failed 2>/dev/null || true
echo "protonsync components were removed."
echo "Local files, sync state and Proton configuration were preserved."
