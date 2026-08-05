#!/usr/bin/env bash
# One L3 drain, run inside the cage container. The sequence is the shipped
# faff-cron.sh sequence: gate first, then the drain, then disposition as the
# authoritative red or green exit. It clones the target repo fresh each time,
# because L3 is stateless between drains and branches are pushed at build-complete.
set -euo pipefail

: "${TARGET_REPO:?set TARGET_REPO, e.g. https://github.com/you/app}"
: "${GH_TOKEN:?set a gh token with push access to the target repo}"
# Model auth is the long-lived seat token (from `claude setup-token`), REQUIRED. CI must
# never authenticate the model from the interactive credentials file: that file's account
# section carries a ROTATING refresh token, and a CI process refreshing it would race the
# operator's own sessions and break auth on one side. The long-lived token does not rotate.
: "${CLAUDE_CODE_OAUTH_TOKEN:?set the long-lived seat token from 'claude setup-token' (CI must not use interactive credentials for model auth)}"

# Resolve the faff CLI. faff is installed as a plugin, so its binary lives under the
# plugin dir, not on PATH. Resolve it the way faff's own skills do.
faff=$(command -v faff || true)
[ -x "$faff" ] || faff=$(find "$HOME/.claude" -path '*/skills/faff/bin/faff' -type f 2>/dev/null | head -1)
[ -x "$faff" ] || { echo "faff CLI not found after plugin install"; exit 1; }

# 0. Tracker auth ONLY. faff drives Linear through the hosted Linear MCP (OAuth), and
#    there is no browser here to authorize it, so carry the pre-authorized token:
#    CLAUDE_CREDENTIALS_B64 is base64 of your ~/.claude/.credentials.json. Write back
#    ONLY its mcpOAuth (tracker) section, never the claudeAiOauth account section, so the
#    rotating account refresh token never lands in CI and cannot race your sessions. Model
#    auth stays entirely on CLAUDE_CODE_OAUTH_TOKEN above. Without this the Linear MCP is
#    unauthenticated and faff falls back to git-only, ignoring your Linear issues.
if [ -n "${CLAUDE_CREDENTIALS_B64:-}" ]; then
  mkdir -p "$HOME/.claude"
  printf '%s' "$CLAUDE_CREDENTIALS_B64" | base64 -d > /tmp/creds.full.json
  node -e 'const fs=require("fs");let j={};try{j=JSON.parse(fs.readFileSync("/tmp/creds.full.json","utf8"))}catch(e){};const out=j.mcpOAuth?{mcpOAuth:j.mcpOAuth}:{};fs.writeFileSync(process.env.HOME+"/.claude/.credentials.json",JSON.stringify(out));if(!j.mcpOAuth)process.exit(3);' \
    || echo "WARN: credentials blob had no mcpOAuth section; Linear MCP will be unauthenticated (git-only)."
  rm -f /tmp/creds.full.json
  chmod 600 "$HOME/.claude/.credentials.json" 2>/dev/null || true
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

# 3b. Budget: a rolling window governor aligned to the subscription 5h usage window. Both
#     an hours figure and a token ceiling are required, or the window is inert. at_ceiling
#     park-until-window-reset makes an unattended run PARK when the window's token ceiling
#     is hit and resume when the window resets, instead of burning into overage. Written
#     into this ephemeral clone only, never committed to the target.
"$faff" config set budget.window.hours "${FAFF_WINDOW_HOURS:-5}" >/dev/null
"$faff" config set budget.window.tokens "${FAFF_WINDOW_TOKENS:?set FAFF_WINDOW_TOKENS: the 5h window token ceiling}" >/dev/null
"$faff" config set budget.at_ceiling park-until-window-reset >/dev/null

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
  claude -p "$PROMPT" \
    --model "${FAFF_MODEL:-claude-opus-4-8}" --effort "${FAFF_EFFORT:-high}" \
    --output-format stream-json --verbose || true

# 5. Disposition is the red or green exit: non-zero if anything parked, errored, or
#    needs attention. The container exit carries it so the runner loop can log it.
exec "$faff" disposition --run-dir "$FAFF_RUN_DIR"
