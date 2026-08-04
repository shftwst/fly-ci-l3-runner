#!/usr/bin/env bash
# PID 1 on the fly Machine. Start the Machine's docker engine, build the cage image
# once, then loop: fire an L3 drain in a fresh cage container on a fixed cadence. The
# Machine stays up between drains, which is what makes this an always-on runner.
set -euo pipefail

: "${TARGET_REPO:?set TARGET_REPO as a fly secret, e.g. https://github.com/you/app}"
: "${CLAUDE_CODE_OAUTH_TOKEN:?set the seat token as a fly secret}"
: "${GH_TOKEN:?set a gh token as a fly secret}"

INTERVAL_SECS="${FAFF_INTERVAL_SECS:-3600}"   # gap between drains
DRAIN_TIMEOUT="${FAFF_DRAIN_TIMEOUT:-290m}"   # wall-clock ceiling per drain

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

# 3. Always-on loop.
echo "runner ready. draining every ${INTERVAL_SECS}s, ${DRAIN_TIMEOUT} ceiling per drain."
while true; do
  echo "=== $(date -u +%FT%TZ) L3 drain start ==="
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
  echo "sleeping ${INTERVAL_SECS}s ..."
  sleep "$INTERVAL_SECS"
done
