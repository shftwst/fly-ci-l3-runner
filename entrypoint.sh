#!/usr/bin/env bash
# PID 1 on the fly Machine. Start the Machine's docker engine, build the cage image
# once, then TICK every minute: if a drain is already running, skip this tick; if not,
# start one. Each drain is a fresh cage container running /faff-beep-boop, which checks
# for eligible work and exits fast when there is none. So a ticket made eligible is
# picked up within about a tick, not after a long fixed gap, and two drains never overlap.
set -euo pipefail

: "${TARGET_REPO:?set TARGET_REPO as a fly secret, e.g. https://github.com/you/app}"
: "${CLAUDE_CODE_OAUTH_TOKEN:?set the seat token as a fly secret}"
: "${GH_TOKEN:?set a gh token as a fly secret}"

TICK_SECS="${FAFF_TICK_SECS:-60}"             # how often to check whether to start a drain
DRAIN_TIMEOUT="${FAFF_DRAIN_TIMEOUT:-290m}"   # wall-clock ceiling for a single drain
LOCK="/tmp/faff-drain.lock"

# 1. Start dockerd on the vfs storage driver. A Firecracker microVM has no kernel
#    overlay for a nested engine to mount, so vfs is the driver that works on fly.
echo "starting dockerd (vfs) ..."
dockerd --storage-driver vfs > /var/log/dockerd.log 2>&1 &
for i in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
if ! docker info >/dev/null 2>&1; then
  echo "dockerd did not come up"; tail -30 /var/log/dockerd.log; exit 1
fi
echo "dockerd up."

# 2. Build the cage image once.
echo "building the cage image ..."
docker build -t faff-cage /cage

# 3. The drain: one fresh cage container.
run_one_drain() {
  echo "=== $(date -u +%FT%TZ) drain start ==="
  if docker run --rm \
       -e TARGET_REPO="$TARGET_REPO" \
       -e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
       -e CLAUDE_CREDENTIALS_B64="${CLAUDE_CREDENTIALS_B64:-}" \
       -e GH_TOKEN="$GH_TOKEN" \
       -e FAFF_DRAIN_TIMEOUT="$DRAIN_TIMEOUT" \
       faff-cage; then
    echo "=== $(date -u +%FT%TZ) drain clean (disposition exit 0) ==="
  else
    echo "=== $(date -u +%FT%TZ) drain needs attention (disposition non-zero) ==="
  fi
}

# 4. Tick loop. flock is the concurrency guard: a running drain holds the lock for its
#    whole duration, so a tick that cannot take the lock means a drain is still going and
#    skips. The idle-check runs in the foreground (no backgrounded subshell), so skipped
#    ticks never pile up; only a real drain runs in the background, one at a time. A
#    plain subshell inherits run_one_drain, the env, and stdout (which is fly's log).
echo "runner ready. ticking every ${TICK_SECS}s; a tick starts a drain only if none is running."
while true; do
  if flock -n "$LOCK" -c true 2>/dev/null; then
    ( exec 9>"$LOCK"; flock -n 9 || exit 0; run_one_drain ) &
  fi
  sleep "$TICK_SECS"
done
