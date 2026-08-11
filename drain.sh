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

# Refresh the faff plugin to the latest marketplace release on every drain. The
# Dockerfile's `claude plugin install` is a cached layer that pinned us at 0.13.0;
# this runtime update runs fresh each `docker run`, so published releases go live.
# Warn-and-continue on failure (a marketplace hiccup shouldn't kill a drain; the
# cached version is still usable).
echo "refreshing faff plugin to the latest marketplace release ..."
claude plugin update faff@faff 2>&1 || claude plugin install faff@faff --force 2>&1 || echo "WARN: plugin refresh failed; using cached version"

# Resolve the faff CLI. faff is installed as a plugin, so its binary lives under the
# plugin dir, not on PATH. The refresh above adds a new versioned cache dir
# (…/cache/faff/faff/<ver>/…) beside the image's baked-in 0.13.0 WITHOUT pruning it, so
# resolve the HIGHEST version — an unsorted `find | head -1` could otherwise pick the
# stale one (filesystem order is arbitrary). sort -V orders by semver.
faff=$(command -v faff || true)
[ -x "$faff" ] || faff=$(find "$HOME/.claude" -path '*/cache/faff/faff/*/skills/faff/bin/faff' -type f 2>/dev/null | sort -V | tail -1)
[ -x "$faff" ] || faff=$(find "$HOME/.claude" -path '*/skills/faff/bin/faff' -type f 2>/dev/null | head -1)
[ -x "$faff" ] || { echo "faff CLI not found after plugin install"; exit 1; }
echo "faff CLI resolved: $faff"

# 0. Tracker auth ONLY. faff drives Linear through the hosted Linear MCP (OAuth), and
#    there is no browser here to authorize it, so carry the pre-authorized token:
#    CLAUDE_MCP_OAUTH_B64 is base64 of your ~/.claude/.credentials.json. Write back
#    ONLY its mcpOAuth (tracker) section, never the claudeAiOauth account section, so the
#    rotating account refresh token never lands in CI and cannot race your sessions. Model
#    auth stays entirely on CLAUDE_CODE_OAUTH_TOKEN above. Without this the Linear MCP is
#    unauthenticated and faff falls back to git-only, ignoring your Linear issues.
if [ -n "${CLAUDE_MCP_OAUTH_B64:-}" ]; then
  mkdir -p "$HOME/.claude"
  printf '%s' "$CLAUDE_MCP_OAUTH_B64" | base64 -d > /tmp/creds.full.json
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

# 2. Wire git auth the gh-native way. gh reads GH_TOKEN from the env (passed into the cage),
#    so `gh auth setup-git` points git at gh's credential helper for both clone and push, and
#    `gh pr create` uses the same token. One token, one env var — the path this token already
#    uses everywhere else.
gh auth setup-git
git config --global user.email "faff-runner@local"
git config --global user.name "faff-runner"

# 2a. Auth preflight — FAIL LOUD AT BOOT, never mid-build. The whole point of a cage is that
#     a build agent can't tell "the repo won't let me push" (infra) from "this work can't be
#     done" (state), and on the last run something logged `push skipped — remote auth
#     unavailable` and issues parked as if unworkable. So assert push access to the TARGET
#     before any model session: derive owner/repo from TARGET_REPO and check the token's
#     permissions. A false/again-unavailable verdict refuses the drain outright — an honest
#     red exit the operator can see, not a session's worth of spend ending in a bogus park.
slug=$(printf '%s' "$TARGET_REPO" | sed -E 's#^https?://[^/]+/##; s/\.git$//')
if ! gh auth status >/dev/null 2>&1; then
  echo "FATAL: gh is not authenticated in the cage (GH_TOKEN missing/invalid). Refusing to drain."; exit 1
fi
canpush=$(gh api "repos/$slug" --jq '.permissions.push' 2>/dev/null || echo "error")
if [ "$canpush" != "true" ]; then
  echo "FATAL: the token cannot push to $slug (permissions.push=$canpush). This is an INFRA"
  echo "       fault, not a backlog one — refusing to drain so issues are not parked as"
  echo "       unworkable. Check the GH_TOKEN secret delivered into the cage is the real token."
  exit 1
fi
echo "auth preflight: token can push to $slug."

# 3. Fresh checkout.
rm -rf /home/faff/app
git clone "$TARGET_REPO" /home/faff/app
cd /home/faff/app

# 3a. Persist faff's gitignored state across the fresh-clone-per-drain. The clone brings
#     .faff/anchors (committed to git) but not .faff/resume / .faff/runs (gitignored), so
#     point those at the mounted state volume — the run-agnostic resume store (FAFF-403)
#     and the run-dirs then survive across drains, and a held build resumes next drain
#     exactly as it would from a persistent local working dir. Anchors stay real committed
#     files (untouched). If the volume isn't mounted, fall back to plain local dirs (no
#     cross-drain persistence, unchanged behaviour) rather than failing the drain.
if [ -d /home/faff/state ]; then
  mkdir -p /home/faff/state/resume /home/faff/state/runs
  mkdir -p /home/faff/app/.faff
  rm -rf /home/faff/app/.faff/resume /home/faff/app/.faff/runs 2>/dev/null || true
  ln -sfn /home/faff/state/resume /home/faff/app/.faff/resume
  ln -sfn /home/faff/state/runs   /home/faff/app/.faff/runs
  echo "resume state persisted on the mounted volume (.faff/resume, .faff/runs)."
fi

# 3b. Budget: an OPTIONAL rolling window governor aligned to the subscription usage window.
#     OFF unless FAFF_WINDOW_TOKENS is set. With it, write the window (hours + token ceiling)
#     and at_ceiling park-until-window-reset, so an unattended run PARKS when the window's
#     tokens are spent and resumes when it resets, instead of running the model session into
#     the raw subscription rate limit mid-build. Without it, leave the target's committed
#     budget config untouched and rely on the drain wall-clock timeout (below) plus the
#     subscription's own limit. A token ceiling with no hours (or vice versa) is inert, so
#     both are gated on FAFF_WINDOW_TOKENS. Written into this ephemeral clone only, never
#     committed to the target.
# --force: the target's committed .faffrc may already set these (faff's own sets
# at_ceiling: escalate), and config set refuses to overwrite an existing value without it.
if [ -n "${FAFF_WINDOW_TOKENS:-}" ]; then
  "$faff" config set --force budget.window.hours "${FAFF_WINDOW_HOURS:-5}" >/dev/null
  "$faff" config set --force budget.window.tokens "$FAFF_WINDOW_TOKENS" >/dev/null
  "$faff" config set --force budget.at_ceiling park-until-window-reset >/dev/null
  echo "budget window: ${FAFF_WINDOW_HOURS:-5}h / ${FAFF_WINDOW_TOKENS} tokens (park-until-window-reset at ceiling)."
else
  echo "budget window: off (FAFF_WINDOW_TOKENS unset). Relying on the drain wall-clock timeout and the subscription's own limit; the clone's committed budget config is left as-is."
fi

# 3c. Sentry acting. This runner is UNATTENDED by construction — a self-directed
#     faff-on-faff drain with no human on the loop — and it structurally CANNOT be L4
#     (run-outward refuses a self-referential target, ADR-0069), so the L4-minted sentry
#     kill-switch is off the table. Turn the FAFF-717 abort kill-switch on explicitly so a
#     runaway (wall-clock / budget / repeated-identical-failure) aborts the run GRACEFULLY
#     (resumable, at a checkpoint) instead of being SIGKILLed by the drain wall-clock
#     timeout below — which orphans an In Progress claim (the run-20260809-105834 incident).
#     Written into this ephemeral clone only, never committed to the target. See FAFF-763
#     (sentry acting keys on attendedness, not the mint) for the reframe this anticipates.
"$faff" config set --force autonomous.sentry_acting true >/dev/null

# Optional review-slot overrides. The target's committed spec_review (prep) and review
# (graft) slots may both be heavy adversarial reviewers whose free-tier backends exhaust
# their daily quota under a sustained runner's back-to-back reviews (fine for sporadic
# local use, not for a full drain). Overriding only one leaves the other phase to hit the
# same wall, so both are overridable. Set to the lighter in-session faffter-noon variants;
# unset -> the committed slot is used unchanged.
[ -n "${FAFF_REVIEW_SLOT:-}" ]      && "$faff" config set --force slots.review "$FAFF_REVIEW_SLOT" >/dev/null
[ -n "${FAFF_SPEC_REVIEW_SLOT:-}" ] && "$faff" config set --force slots.spec_review "$FAFF_SPEC_REVIEW_SLOT" >/dev/null

# Drop named adversarial-review backends whose COMPLETIONS hang or fail from this
# environment (config set can't rewrite the refs list, so patch the cloned .faffrc). The
# nvidia backend's /models check passes but its chat completions time out from fly, and
# it sits first in the chain, so every review waits out its full deadline slice before
# falling through to the working backends. FAFF_DROP_BACKENDS is a comma-separated list of
# backend ref names to remove; unset -> the committed chain is used unchanged.
if [ -n "${FAFF_DROP_BACKENDS:-}" ]; then
  rc=$("$faff" config path 2>/dev/null | head -1)
  [ -f "$rc" ] || rc=.faffrc.yaml
  IFS=','; for b in $FAFF_DROP_BACKENDS; do
    b=$(printf '%s' "$b" | tr -d '[:space:]')
    [ -n "$b" ] && sed -i "/^[[:space:]]*-[[:space:]]*${b}[[:space:]]*$/d" "$rc"
  done; unset IFS
  echo "review backends dropped for this environment: $FAFF_DROP_BACKENDS"
fi

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
# Hard-timeout: entrypoint always passes an explicit value, so this fallback only fires if
# drain.sh runs standalone. It is a coarse BACKSTOP, not the wedge guard (faff's sentry poller
# is). Mirror entrypoint's split: window on -> WINDOW_HOURS + 1h (park-before-kill); window off
# -> a 24h ceiling above faff's 4h sentry ceiling, while we test sentry-owned wedge handling.
if [ -n "${FAFF_WINDOW_TOKENS:-}" ]; then
  DRAIN_TIMEOUT="${FAFF_DRAIN_TIMEOUT:-$(( (${FAFF_WINDOW_HOURS:-5} + 1) * 60 ))m}"
else
  DRAIN_TIMEOUT="${FAFF_DRAIN_TIMEOUT:-1440m}"
fi
run_claude() {
  timeout "$DRAIN_TIMEOUT" \
    claude -p "$PROMPT" \
      --model "${FAFF_MODEL:-claude-opus-4-8}" --effort "${FAFF_EFFORT:-high}" \
      --dangerously-skip-permissions \
      --output-format stream-json --verbose
}
# Persist the raw model stream, not just faff's run-dir. faff's .faff/runs artifacts
# (summary.md, events.jsonl, disposition, park.md) survive on the state volume and record
# OUTCOMES, but not the turn-by-turn trace. That trace otherwise only reaches stdout -> fly
# logs, which retain ~5 minutes. So when the state volume is mounted, `tee` the stream to a
# per-run file (stdout stays live for `fly logs`) and gzip it after.
#
# CORRELATION: beep-boop mints its OWN run-dir (run-<ts>-beepboop-<mode>) and re-exports
# FAFF_RUN_DIR to it inside the claude child, so the name we set above is only a placeholder.
# Stream to a temp file, then — drains are serialised, one at a time — resolve the run-dir
# actually created during THIS drain (the newest dir touched since the start marker) and name
# the stream after it, so streams/<run-id>.jsonl.gz sits beside runs/<run-id>/ and disposition
# runs against the same real dir.
DRAIN_START="/tmp/faff-drain-start.$$"; : > "$DRAIN_START"
if [ -d /home/faff/state ]; then
  mkdir -p /home/faff/state/streams
  STREAM_TMP="/home/faff/state/streams/.pending.$$.jsonl"
  run_claude | tee "$STREAM_TMP" || true
else
  run_claude || true
fi

# Resolve the run-dir beep-boop actually minted this drain; fall back to the placeholder if
# none was created (e.g. an early gate stop before mint).
RUN_DIR=$(find /home/faff/app/.faff/runs -mindepth 1 -maxdepth 1 -type d -newer "$DRAIN_START" 2>/dev/null | sort | tail -1)
[ -n "$RUN_DIR" ] || RUN_DIR="$FAFF_RUN_DIR"
rm -f "$DRAIN_START"

if [ -d /home/faff/state ] && [ -f "$STREAM_TMP" ]; then
  STREAM_RAW="/home/faff/state/streams/$(basename "$RUN_DIR").jsonl"
  mv -f "$STREAM_TMP" "$STREAM_RAW"
  gzip -f "$STREAM_RAW" 2>/dev/null && echo "stream persisted: ${STREAM_RAW}.gz (run $(basename "$RUN_DIR"))"
  # Retention: keep as much history as the volume comfortably holds (streams are a few MB
  # gzipped, the volume is 30GB); offload to long-term storage out of band. Prune ONLY to
  # protect the docker engine: this volume also backs /var/lib/docker (vfs), so if it fills,
  # dockerd breaks and the runner dies. Delete the OLDEST streams one at a time, only while
  # free space is under FAFF_STREAM_MIN_FREE_GB (default 8), leaving the engine headroom.
  min_free_kb=$(( ${FAFF_STREAM_MIN_FREE_GB:-8} * 1024 * 1024 ))
  while [ "$(df -P /home/faff/state | awk 'NR==2{print $4}')" -lt "$min_free_kb" ]; do
    oldest=$(ls -1tr /home/faff/state/streams/*.jsonl.gz 2>/dev/null | head -1)
    [ -n "$oldest" ] || break   # nothing left to prune (engine itself is the consumer) -> stop
    rm -f "$oldest" && echo "pruned oldest stream for engine headroom: $oldest"
  done
fi

# 5. Disposition is the red or green exit: non-zero if anything parked, errored, or needs
#    attention. Point it at the run-dir beep-boop actually wrote (resolved above), not the
#    placeholder. The container exit carries it so the runner loop can log it.
exec "$faff" disposition --run-dir "$RUN_DIR"
