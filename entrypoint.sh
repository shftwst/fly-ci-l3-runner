#!/usr/bin/env bash
# PID 1 on the fly Machine. Start the Machine's docker engine, build the cage image
# once, then run two cadences under a single lock (only one drain runs at a time; a
# tick with one already running skips):
#
#   fast (FAFF_TICK_SECS, default 60): a cheap Linear query for eligible tickets. On a
#   hit, run a drain over just those issues (`/faff-beep-boop <IDs>`, which skips tidy).
#   A newly-eligible ticket is picked up within about a tick; an idle tick costs one
#   API call, no container and no claude session.
#
#   full (FAFF_FULL_SECS, default 3600): a full `/faff-beep-boop` (tidy + discovery +
#   build). This is the grooming pass AND the catch-all for anything the fast pre-check
#   missed, so a wrong or unavailable pre-check degrades to hourly work, never to silence.
set -euo pipefail

: "${TARGET_REPO:?set TARGET_REPO as a fly secret, e.g. https://github.com/you/app}"
: "${GH_TOKEN:?set a gh token as a fly secret}"
# Model auth: the long-lived seat token from `claude setup-token`, REQUIRED. CI must not
# use interactive credentials for the model (their rotating refresh token races the
# operator's sessions). CLAUDE_CREDENTIALS_B64 is separate and for the Linear MCP only.
: "${CLAUDE_CODE_OAUTH_TOKEN:?set the long-lived seat token from 'claude setup-token'}"

TICK_SECS="${FAFF_TICK_SECS:-60}"             # fast pre-check cadence
FULL_SECS="${FAFF_FULL_SECS:-43200}"          # full drain (tidy + discovery) cadence (12h)
WINDOW_HOURS="${FAFF_WINDOW_HOURS:-5}"        # subscription budget-window length
# The wall-clock ceiling is a LAST-RESORT hang catch, deliberately ABOVE the budget
# window so the window governor parks gracefully (writing park-until-window-reset +
# resume_at at a between-units checkpoint) before this hard SIGKILL can cull the drain.
# Default = window + 1h; overridable, but a value <= the window would defeat the park.
DRAIN_TIMEOUT="${FAFF_DRAIN_TIMEOUT:-$(( (WINDOW_HOURS + 1) * 60 ))m}"
TEAM_KEY="${FAFF_TEAM_KEY:-FAFF}"             # tracker team key for the pre-check query
LOCK="/tmp/faff-drain.lock"
echo "budget window ${WINDOW_HOURS}h; drain hard-timeout ${DRAIN_TIMEOUT} (above the window, so the window parks before the timeout culls)."

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

# 3. Pre-check: the eligible faff-automate issues in Backlog/Todo for the team. Prints
#    their identifiers space-separated (empty = none). Exit 2 = unavailable (no
#    LINEAR_API_KEY, or the query failed); the caller then relies on the full cadence.
eligible_ids() {
  [ -n "${LINEAR_API_KEY:-}" ] || return 2
  local q resp
  q='{"query":"query($t:String!){issues(first:50,filter:{labels:{some:{name:{eq:\"faff-automate\"}}},team:{key:{eq:$t}},state:{type:{in:[\"backlog\",\"unstarted\"]}}}){nodes{identifier}}}","variables":{"t":"'"$TEAM_KEY"'"}}'
  resp=$(curl -sS --max-time 20 -X POST https://api.linear.app/graphql \
           -H "Authorization: $LINEAR_API_KEY" -H "Content-Type: application/json" \
           -d "$q") || return 2
  echo "$resp" | jq -e '.data.issues.nodes' >/dev/null 2>&1 || return 2
  echo "$resp" | jq -r '.data.issues.nodes[].identifier' | tr '\n' ' ' | sed 's/ *$//'
}

# 4. Run one drain in a fresh cage container. $1 = explicit issue IDs (empty = full).
run_drain() {
  local ids="$1" label
  if [ -n "$ids" ]; then label="build [$ids]"; else label="full drain (tidy + discovery + build)"; fi
  echo "=== $(date -u +%FT%TZ) $label ==="
  if docker run --rm \
       -e TARGET_REPO="$TARGET_REPO" \
       -e CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
       -e CLAUDE_CREDENTIALS_B64="${CLAUDE_CREDENTIALS_B64:-}" \
       -e GH_TOKEN="$GH_TOKEN" \
       -e FAFF_DRAIN_TIMEOUT="$DRAIN_TIMEOUT" \
       -e FAFF_ISSUE_IDS="$ids" \
       -e NVIDIA_API_KEY="${NVIDIA_API_KEY:-}" \
       -e GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
       -e OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
       -e FAFF_MODEL="${FAFF_MODEL:-claude-opus-4-8}" \
       -e FAFF_EFFORT="${FAFF_EFFORT:-high}" \
       -e FAFF_WINDOW_HOURS="${FAFF_WINDOW_HOURS:-5}" \
       -e FAFF_WINDOW_TOKENS="${FAFF_WINDOW_TOKENS:?set FAFF_WINDOW_TOKENS: the 5h window token ceiling}" \
       -e FAFF_REVIEW_SLOT="${FAFF_REVIEW_SLOT:-}" \
       -e FAFF_SPEC_REVIEW_SLOT="${FAFF_SPEC_REVIEW_SLOT:-}" \
       -e FAFF_DROP_BACKENDS="${FAFF_DROP_BACKENDS:-}" \
       faff-cage; then
    echo "=== $(date -u +%FT%TZ) drain clean (disposition exit 0) ==="
  else
    echo "=== $(date -u +%FT%TZ) drain needs attention (disposition non-zero) ==="
  fi
}

# 5. One startup report on whether the fast pre-check is available.
if ids=$(eligible_ids); then
  echo "pre-check: available. ${ids:+eligible now: $ids}${ids:-nothing eligible right now}"
else
  echo "pre-check: UNAVAILABLE (no LINEAR_API_KEY or query error). Fast pickup is off; the full drain every ${FULL_SECS}s is the only trigger. Set LINEAR_API_KEY (and FAFF_TEAM_KEY if not '${TEAM_KEY}') to enable 60s pickup."
fi

# 5b. Warn if the review-backend keys are absent. faff's configured review slot may run an
#     adversarial second opinion (the faff repo's own .faffrc does, via nvidia/gemini/
#     openrouter). Missing keys are an AUTH fault, which surfaces needs-human, so every
#     build would park at the review step rather than merge. Not fatal to start (a target
#     repo may not use adversarial review), but loud so it is not discovered via parks.
if [ -z "${NVIDIA_API_KEY:-}" ] && [ -z "${GEMINI_API_KEY:-}" ] && [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "WARN: no NVIDIA_API_KEY / GEMINI_API_KEY / OPENROUTER_API_KEY set. If the target's review slot uses an adversarial backend (the faff repo does), builds will PARK at review (auth fault -> needs-human), not merge. Set the review-backend key(s) the target's .faffrc names."
fi

# 6. The loop. flock is the concurrency guard: a running drain holds the lock for its
#    whole duration, so a tick that cannot take it means a drain is still going and
#    skips. The idle-check is foreground (no backgrounded subshell), so skips never pile
#    up; only a real drain runs in the background, one at a time. last_full starts at 0
#    so the first free tick runs a full drain immediately (clearing any queued backlog).
echo "runner ready. fast tick every ${TICK_SECS}s; full drain every ${FULL_SECS}s."
last_full=0
while true; do
  if flock -n "$LOCK" -c true 2>/dev/null; then
    now=$(date +%s)
    if [ $(( now - last_full )) -ge "$FULL_SECS" ]; then
      last_full=$now
      ( exec 9>"$LOCK"; flock -n 9 || exit 0; run_drain "" ) &
    elif hits=$(eligible_ids) && [ -n "$hits" ]; then
      ( exec 9>"$LOCK"; flock -n 9 || exit 0; run_drain "$hits" ) &
    fi
    # no full due + no eligible tickets (or pre-check unavailable) -> skip this tick
  fi
  sleep "$TICK_SECS"
done
