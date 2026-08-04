#!/usr/bin/env bash
# One L3 drain, run inside the cage container. The sequence is the shipped
# faff-cron.sh sequence: gate first, then the drain, then disposition as the
# authoritative red or green exit. It clones the target repo fresh each time,
# because L3 is stateless between drains and branches are pushed at build-complete.
set -euo pipefail

: "${TARGET_REPO:?set TARGET_REPO, e.g. https://github.com/you/app}"
: "${CLAUDE_CODE_OAUTH_TOKEN:?set the long-lived seat token}"
: "${GH_TOKEN:?set a gh token with push access to the target repo}"

# 1. Admission gate. In this container it passes (contained via /.dockerenv, no host
#    socket). If it ever fails, refuse loudly rather than drain uncaged.
faff container-check --gate

# 2. Wire git push and clone auth from the gh token.
gh auth setup-git

# 3. Fresh checkout.
rm -rf /home/faff/app
git clone "$TARGET_REPO" /home/faff/app
cd /home/faff/app

# 4. The drain. One /faff-beep-boop run drains the ready queue (tidy, prep, build) and
#    parks anything it cannot decide. The timeout is a wall-clock ceiling so a wedged
#    run cannot hold the drain open forever.
FAFF_RUN_DIR="/home/faff/app/.faff/runs/run-$(date -u +%Y%m%d-%H%M%S)-fly-l3"
export FAFF_RUN_DIR
timeout "${FAFF_DRAIN_TIMEOUT:-290m}" claude -p "/faff-beep-boop" || true

# 5. Disposition is the red or green exit: non-zero if anything parked, errored, or
#    needs attention. The container exit carries it so the runner loop can log it.
exec faff disposition --run-dir "$FAFF_RUN_DIR"
