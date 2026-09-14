#!/usr/bin/env bash
#
# upgrade-driftpull.sh — add the "drift pull" safety net to an EXISTING
# protonsync installation WITHOUT running install.sh.
#
# Why: the event watcher can silently miss files (an event skipped after a
# transient download error, a gap while the PC was off, an expired event
# cursor rebuilt in place without re-fetching the gap). Full bisync used to
# be the safety net for this but is masked in event-only mode, so nothing
# otherwise ever notices those gaps. This upgrade adds a periodic, ONE-WAY,
# ADDITIVE-ONLY download pass ("rclone copy", never a delete) that runs at
# low CPU/IO priority and with a Proton API rate limit.
#
# It does NOT touch the binary, the Python uploader, the event state, the
# bisync filter, or anything else about the existing setup. Only new
# files/units are added.
#
# Usage:  ./upgrade-driftpull.sh          (as the normal user account, NOT sudo)
#
# Environment variables (optional):
#   PULL_CALENDAR    systemd OnCalendar for the daily run (default: *-*-* 05:00:00)
#   PULL_INTERVAL    interval between runs otherwise      (default: 12h)
#   PULL_TPSLIMIT    Proton API requests/sec during a run (default: 4)
#   PULL_TIME_BUDGET max run time per round in seconds     (default: 1200 = 20 min)
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
STATE_DIR="$HOME/.local/state"
RCLONE_DIR="$HOME/.config/rclone"
LOCK_FILE="$HOME/.cache/protonsync/proton-drive-api.lock"

PULL_CALENDAR="${PULL_CALENDAR:-*-*-* 05:00:00}"
PULL_INTERVAL="${PULL_INTERVAL:-12h}"
PULL_TPSLIMIT="${PULL_TPSLIMIT:-4}"
# Hard wall-clock cap per run - see the matching comment in install.sh. Without
# it, a stalled connection (seen live: a laptop resuming on a mobile hotspot
# left a dead pooled TCP connection that every read hung on) holds the shared
# API lock indefinitely, starving uploads and the event watcher for however
# long it happens to hang.
PULL_TIME_BUDGET="${PULL_TIME_BUDGET:-1200}"

RCLONE="$BIN_DIR/protonsync-rclone"
if [[ ! -x "$RCLONE" ]]; then
    echo "No protonsync installation found ($RCLONE is missing)." >&2
    echo "Use install.sh / NEW-INSTALL.txt for a fresh installation instead." >&2
    exit 1
fi

# --- find every event-watch instance (suffixed and unsuffixed) -------------
mapfile -t EVENT_SCRIPTS < <(compgen -G "$BIN_DIR/protonsync-event-watch*" || true)
if [[ ${#EVENT_SCRIPTS[@]} -eq 0 ]]; then
    echo "No protonsync-event-watch* wrappers found in $BIN_DIR." >&2
    exit 1
fi

extract() { sed -nE "s/^$1=\"(.*)\"$/\1/p" "$2" | head -1; }

# --- pull fresh status/health scripts from install.sh in the same kit ------
# (Kept DRY: same heredoc body that install.sh generates.)
extract_heredoc() {
    awk -v marker="cat >\"\$$1\" <<'SCRIPT'" '
        $0 == marker { f = 1; next }
        f && $0 == "SCRIPT" { exit }
        f { print }
    ' "$KIT_DIR/install.sh"
}
if [[ -f "$KIT_DIR/install.sh" ]]; then
    for pair in "STATUS_SCRIPT:protonsync-status" "HEALTH_SCRIPT:protonsync-health"; do
        var="${pair%%:*}"; name="${pair##*:}"
        body="$(extract_heredoc "$var")"
        if [[ -n "$body" ]]; then
            [[ -f "$BIN_DIR/$name" ]] && cp -a "$BIN_DIR/$name" "$STATE_DIR/$name.bak-$(date +%Y%m%d-%H%M%S)"
            printf '%s\n' "$body" >"$BIN_DIR/$name"
            chmod 0755 "$BIN_DIR/$name"
            echo ">> Updated $name (now shows drift-pull status)"
        fi
    done
fi

write_pull_script() {  # $1=path $2=remote $3=local $4=filter $5=log $6=health
    # KEEP IN SYNC with the PULL_SCRIPT heredoc in install.sh.
    cat >"$1" <<SCRIPT
#!/usr/bin/env bash
# protonsync drift pull: download anything on Proton that is missing locally
# (or newer on Proton), as a safety net behind the event watcher. One-way and
# additive only - it never deletes or moves a local file. Runs at low CPU/IO
# priority and with a Proton API rate limit so it stays unobtrusive.
set -u

RCLONE="$RCLONE"
REMOTE_DIR="$2"
LOCAL_DIR="$3"
LOCK_FILE="$LOCK_FILE"
FILTER_FILE="$4"
LOG_FILE="$5"
HEALTH_FILE="$6"
TPSLIMIT="$PULL_TPSLIMIT"
TIME_BUDGET="$PULL_TIME_BUDGET"

mkdir -p "\$LOCAL_DIR" "\$(dirname "\$LOG_FILE")" "\$(dirname "\$LOCK_FILE")" \
    "\$(dirname "\$HEALTH_FILE")"

# Wait for DNS to actually work before starting. Persistent=true on the timer
# means a run can be triggered the instant a laptop resumes from suspend, but
# network-online.target does not reliably re-block a resume-triggered start
# (it was already "reached" before suspend) - so without this, a resume-
# triggered run fails immediately on a DNS lookup, before the network is
# really back. Up to 2 minutes of grace; if still down, this run just logs the
# failure and the next scheduled run (or the next resume) retries.
for _ in \$(seq 1 24); do
    getent hosts drive-api.proton.me >/dev/null 2>&1 && break
    sleep 5
done

started="\$(date --iso-8601=seconds)"
start_epoch="\$(date +%s)"
run_log="\$(mktemp)"

FILTER_ARGS=()
[[ -f "\$FILTER_FILE" ]] && FILTER_ARGS=(--filter-from "\$FILTER_FILE")

PRIO=(nice -n 19)
command -v ionice >/dev/null 2>&1 && PRIO+=(ionice -c 3)

# "timeout" bounds actual run time so a stalled connection can never hold the
# shared lock past this; "flock -w" only bounds how long we wait to ACQUIRE
# the lock in the first place, which is a different thing.
flock -w 7200 "\$LOCK_FILE" \
    timeout --kill-after=30s "\$TIME_BUDGET" \
    "\${PRIO[@]}" \
    "\$RCLONE" copy "\$REMOTE_DIR" "\$LOCAL_DIR" \
    "\${FILTER_ARGS[@]}" \
    --update \
    --use-server-modtime \
    --transfers 2 \
    --checkers 4 \
    --tpslimit "\$TPSLIMIT" \
    --tpslimit-burst 1 \
    --retries 1 \
    --low-level-retries 10 \
    --stats-one-line \
    --stats 5m \
    --log-file "\$run_log" \
    --log-level INFO
status=\$?
# --retries 1: avoid re-walking the whole tree for every persistently failing
# file (signature-fail files); the next scheduled run is the retry. A backlog
# bigger than one time budget just takes several scheduled runs to clear -
# --update makes that safe (already-copied files are skipped next time).

finished="\$(date --iso-8601=seconds)"
duration=\$(( \$(date +%s) - start_epoch ))
copied="\$(grep -c ': Copied (' "\$run_log" 2>/dev/null || true)"
errors="\$(grep -c ' ERROR *: ' "\$run_log" 2>/dev/null || true)"
copied="\${copied:-0}"; errors="\${errors:-0}"
if [[ "\$status" -eq 0 ]]; then
    state="ok"
elif [[ "\$status" -eq 124 || "\$status" -eq 137 ]]; then
    state="ok"; [[ "\$errors" -gt 0 ]] && state="degraded"
else
    state="degraded"
fi

tmp_health="\$HEALTH_FILE.tmp"
cat >"\$tmp_health" <<JSON
{
  "status": "\$state",
  "updated": "\$finished",
  "started": "\$started",
  "duration_seconds": \$duration,
  "copied": \$copied,
  "errors": \$errors,
  "exit_code": \$status
}
JSON
mv "\$tmp_health" "\$HEALTH_FILE"

{
    printf '=== drift pull %s -> %s (exit %s, copied %s, errors %s, %ss) ===\n' \
        "\$started" "\$finished" "\$status" "\$copied" "\$errors" "\$duration"
    cat "\$run_log"
} >>"\$LOG_FILE"
rm -f "\$run_log"
exit "\$status"
SCRIPT
    chmod 0755 "$1"
}

for ev in "${EVENT_SCRIPTS[@]}"; do
    base="$(basename "$ev")"                       # protonsync-event-watch[-slug]
    sfx="${base#protonsync-event-watch}"           # "" or "-slug"
    label="${sfx#-}"; label="${label:-default}"

    remote="$(extract REMOTE_DIR "$ev")"
    local_dir="$(extract LOCAL_DIR "$ev")"
    if [[ -z "$remote" || -z "$local_dir" ]]; then
        echo "!! Could not read REMOTE_DIR/LOCAL_DIR from $ev - skipping" >&2
        continue
    fi
    filter="$RCLONE_DIR/protonsync-bisync-filter$sfx.txt"
    log="$STATE_DIR/protonsync-pull$sfx.log"
    health="$STATE_DIR/protonsync-pull-health$sfx.json"
    pull_script="$BIN_DIR/protonsync-pull$sfx"
    service="$UNIT_DIR/protonsync-pull$sfx.service"
    timer="$UNIT_DIR/protonsync-pull$sfx.timer"

    echo ">> Instance '$label'"
    echo "   remote: $remote"
    echo "   local : $local_dir"

    write_pull_script "$pull_script" "$remote" "$local_dir" "$filter" "$log" "$health"

    cat >"$service" <<SERVICE
[Unit]
Description=Drift pull for Proton folder '$label' (download missing files)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=infinity
Nice=19
IOSchedulingClass=idle
CPUWeight=20
IOWeight=20
ExecStart=$pull_script
SERVICE

    cat >"$timer" <<TIMER
[Unit]
Description=Schedule drift pull for Proton folder '$label'

[Timer]
OnActiveSec=10min
OnUnitActiveSec=$PULL_INTERVAL
OnCalendar=$PULL_CALENDAR
RandomizedDelaySec=20min
Persistent=true

[Install]
WantedBy=timers.target
TIMER

    systemctl --user daemon-reload
    systemctl --user reset-failed "protonsync-pull$sfx.service" 2>/dev/null || true
    systemctl --user enable "protonsync-pull$sfx.timer"
    # restart (not just start) so a re-run picks up an edited timer definition
    systemctl --user restart "protonsync-pull$sfx.timer"
    echo "   timer enabled: protonsync-pull$sfx.timer"
done

echo
echo "Done. The safety net is scheduled (every $PULL_INTERVAL + daily $PULL_CALENDAR)."
echo "The next round runs automatically. Run one NOW with:"
for ev in "${EVENT_SCRIPTS[@]}"; do
    sfx="$(basename "$ev")"; sfx="${sfx#protonsync-event-watch}"
    echo "  systemctl --user start protonsync-pull$sfx.service"
done
echo
echo "Watch it:  protonsync-status        (see 'Last drift pull')"
echo "Log     :  $STATE_DIR/protonsync-pull*.log"
echo
echo "NOTE: for a large one-off backlog (hundreds of files) - stop the watchers first:"
echo "  systemctl --user stop 'protonsync-upload-watch*' 'protonsync-event-watch*'"
echo "  systemctl --user start protonsync-pull<suffix>.service   # wait for it to finish"
echo "  systemctl --user start 'protonsync-upload-watch*' 'protonsync-event-watch*'"
