#!/usr/bin/env bash
# One L3 drain, run inside the cage container. The sequence is the shipped
# faff-cron.sh sequence: gate first, then the drain, then disposition as the
# authoritative red or green exit. It clones the target repo fresh each time,
# because L3 is stateless between drains and branches are pushed at build-complete.
set -euo pipefail

: "${TARGET_REPO:?set TARGET_REPO, e.g. https://github.com/you/app}"
: "${GH_TOKEN:?set a gh token with push access to the target repo}"
# Model auth: the seat token if provided, otherwise the carried credentials file (which
# holds the account auth too). Drop an empty seat-token env so it never shadows the file.
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || unset CLAUDE_CODE_OAUTH_TOKEN

# Resolve the faff CLI. faff is installed as a plugin, so its binary lives under the
# plugin dir, not on PATH. Resolve it the way faff's own skills do.
faff=$(command -v faff || true)
[ -x "$faff" ] || faff=$(find "$HOME/.claude" -path '*/skills/faff/bin/faff' -type f 2>/dev/null | head -1)
[ -x "$faff" ] || { echo "faff CLI not found after plugin install"; exit 1; }

# 0. Tracker auth. faff drives Linear through the hosted Linear MCP, which is OAuth,
#    so there is no browser here to authorize it. Carry the pre-authorized credentials
#    instead: CLAUDE_CREDENTIALS_B64 is base64 of your ~/.claude/.credentials.json,
#    produced after you have authorized Linear locally (see the README). Without it the
#    Linear MCP stays unauthenticated and faff falls back to git-only, which ignores
#    your Linear issues.
if [ -n "${CLAUDE_CREDENTIALS_B64:-}" ]; then
  mkdir -p "$HOME/.claude"
  printf '%s' "$CLAUDE_CREDENTIALS_B64" | base64 -d > "$HOME/.claude/.credentials.json"
  chmod 600 "$HOME/.claude/.credentials.json"
fi
if claude mcp list 2>/dev/null | grep -qiE "linear.*connected"; then
  echo "tracker: Linear MCP connected."
else
  echo "WARN: Linear MCP is not connected; faff will run git-only and ignore Linear issues."
fi

# 1. Admission gate. In this container it passes (contained via /.dockerenv, no host
#    socket). If it ever fails, refuse loudly rather than drain uncaged.
"$faff" container-check --gate

# 2. Wire git push and clone auth from the gh token.
gh auth setup-git

# 3. Fresh checkout.
rm -rf /home/faff/app
git clone "$TARGET_REPO" /home/faff/app
cd /home/faff/app

# 4. The drain. With FAFF_ISSUE_IDS set (the fast path), run beep-boop over just those
#    issues, which skips the tidy + discovery pass; without it, run the full pipeline
#    (tidy, prep, build). Either way beep-boop parks anything it cannot decide. Stream
#    the run turn-by-turn so it shows live in `fly logs` (stream-json needs --verbose;
#    each event is one line to stdout, which docker run passes up to the Machine and on
#    to fly). The timeout is a wall-clock ceiling so a wedged run cannot hold open forever.
PROMPT="/faff-beep-boop"
[ -n "${FAFF_ISSUE_IDS:-}" ] && PROMPT="/faff-beep-boop ${FAFF_ISSUE_IDS}"
FAFF_RUN_DIR="/home/faff/app/.faff/runs/run-$(date -u +%Y%m%d-%H%M%S)-fly-l3"
export FAFF_RUN_DIR
timeout "${FAFF_DRAIN_TIMEOUT:-290m}" \
  claude -p "$PROMPT" --output-format stream-json --verbose || true

# 5. Disposition is the red or green exit: non-zero if anything parked, errored, or
#    needs attention. The container exit carries it so the runner loop can log it.
exec "$faff" disposition --run-dir "$FAFF_RUN_DIR"
