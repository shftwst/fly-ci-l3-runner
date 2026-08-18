#!/usr/bin/env bash
# PID 1 on the fly Machine. Start the Machine's docker engine, build the cage image
# once, then run two cadences under a single lock (only one drain runs at a time; a
# tick with one already running skips):
#
#   cheap pre-check (FAFF_TICK_SECS, default 3600): a cheap Linear query for eligible
#   tickets each tick. On a hit, run a drain over just those issues (`/faff-beep-boop
#   <IDs>`, which skips tidy). An idle tick costs one API call, no container/claude session.
#
#   full drain (daily at FAFF_FULL_HOUR in FAFF_FULL_TZ, default 5am Eastern): a full
#   `/faff-beep-boop` (tidy + discovery + build). This is the grooming pass AND the catch-all
#   for anything the pre-check missed, so a wrong or unavailable pre-check degrades to daily
#   work, never to silence.
set -euo pipefail

: "${TARGET_REPO:?set TARGET_REPO as a fly secret, e.g. https://github.com/you/app}"
: "${GH_TOKEN:?set a gh token as a fly secret}"
# Model auth: the long-lived seat token from `claude setup-token`, REQUIRED. CI must not
# use interactive credentials for the model (their rotating refresh token races the
# operator's sessions). CLAUDE_MCP_OAUTH_B64 is separate and for the Linear MCP only.
: "${CLAUDE_CODE_OAUTH_TOKEN:?set the long-lived seat token from 'claude setup-token'}"
# Operator identity for the DCO sign-off, REQUIRED and fail-closed: faff builds commit with
# `git commit -s`, a downstream dco check requires the Signed-off-by trailer, and policy
# requires the OPERATOR's identity (a machine ident cannot certify origin rights). Refuse to
# start rather than let a build commit under a git default. Forwarded into the cage below;
# the optional GIT_SSH_SIGNING_KEY_B64 (SSH signing) is forwarded there too.
: "${GIT_OPERATOR_NAME:?refusing to start: set GIT_OPERATOR_NAME as a fly secret (the DCO sign-off must carry the operator identity, never a machine ident)}"
: "${GIT_OPERATOR_EMAIL:?refusing to start: set GIT_OPERATOR_EMAIL as a fly secret (must be a verified email registered to the operator on GitHub)}"

TICK_SECS="${FAFF_TICK_SECS:-3600}"           # cheap pre-check cadence (hourly)
FULL_HOUR="${FAFF_FULL_HOUR:-5}"              # hour-of-day (0-23) for the once-daily full drain
FULL_TZ="${FAFF_FULL_TZ:-America/New_York}"   # zone FULL_HOUR is read in (IANA => DST-aware Eastern)
WINDOW_HOURS="${FAFF_WINDOW_HOURS:-5}"        # budget-window length (only meaningful with FAFF_WINDOW_TOKENS)
TEAM_KEY="${FAFF_TEAM_KEY:-FAFF}"             # tracker team key for the pre-check query
LOCK="/tmp/faff-drain.lock"
# Budget window is OPTIONAL: active only when FAFF_WINDOW_TOKENS is set (drain.sh writes it into
# the clone then); otherwise off and the drain leans on faff's own sentry poller + this timeout.
#
# The drain hard-timeout is a LAST-RESORT wall-clock SIGKILL so a wedged drain cannot hold the
# lock forever. It is NOT the primary wedge guard: faff-beep-boop spawns a sentry poller on every
# run that (with autonomous.sentry_acting, which drain.sh sets in the clone) resumably ABORTS a wedged run on a
# stale heartbeat (~900s) or its 4h run-elapsed ceiling. This SIGKILL only backstops the case
# where that poller never started. Its DEFAULT depends on the window, so a window-named var never
# governs wall-clock when the window is off:
#   window ON  -> WINDOW_HOURS + 1h, keeping the timeout ABOVE the window so the governor parks
#                 gracefully (park-until-window-reset + resume_at) before the SIGKILL culls it.
#   window OFF -> a coarse fixed ceiling well above faff's 4h sentry ceiling, with NO reference to
#                 WINDOW_HOURS. 24h WHILE WE TEST the sentry-owned wedge handling; tighten once the
#                 poller's resumable abort is confirmed doing the real work.
# An explicit FAFF_DRAIN_TIMEOUT overrides either default. Resolve both the window description
# and the timeout in one branch so the boot log is honest about what is actually in effect.
if [ -n "${FAFF_WINDOW_TOKENS:-}" ]; then
  WINDOW_DESC="${WINDOW_HOURS}h / ${FAFF_WINDOW_TOKENS} tokens"
  DRAIN_TIMEOUT="${FAFF_DRAIN_TIMEOUT:-$(( (WINDOW_HOURS + 1) * 60 ))m}"
else
  WINDOW_DESC="off (set FAFF_WINDOW_TOKENS to enable)"
  DRAIN_TIMEOUT="${FAFF_DRAIN_TIMEOUT:-1440m}"   # 24h backstop while testing sentry-owned wedge handling
fi
echo "budget window ${WINDOW_DESC}; drain hard-timeout ${DRAIN_TIMEOUT}."
# One consolidated config line up front (before the multi-minute dockerd + cage build), so a
# glance at the boot log shows every resolved cadence/target env var actually in effect.
echo "config: target ${TARGET_REPO} | cheap pre-check every ${TICK_SECS}s | full drain daily ${FULL_HOUR}:00 ${FULL_TZ} | budget window ${WINDOW_DESC} | drain ceiling ${DRAIN_TIMEOUT} | team ${TEAM_KEY}"
# Andon push-alerting config as resolved at boot. URL is printed with its query string
# stripped (${ANDON_URL%%\?*}), matching drain.sh's own logging; ANDON_TOKEN shows only its
# set/unset state, never its value. Unset ANDON_URL means andon is off (the whole channel is
# a no-op).
if [ -n "${ANDON_URL:-}" ]; then
  echo "andon: url ${ANDON_URL%%\?*} | format ${ANDON_FORMAT:-generic} | events ${ANDON_EVENTS:-<faff default>} | token $([ -n "${ANDON_TOKEN:-}" ] && echo '<set>' || echo '<unset>')"
else
  echo "andon: off (ANDON_URL unset)"
fi

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

# Each rebuild above retags faff-cage, dropping the previous image to dangling (<none>:<none>).
# The vfs storage driver has no copy-on-write, so every dangling image holds a full physical
# copy of its layers on the 30GB volume: left alone, one boot/redeploy = ~1GB of dead weight.
# Prune here so the volume doesn't creep toward full over months of restarts.
docker image prune -f

# 2b. Persistent state volume for faff's gitignored resume store + run-dirs. A named volume
#     lives under /var/lib/docker/volumes, which is on the mounted 30GB volume, so it
#     survives Machine restarts. Mounted into each cage so .faff/resume + .faff/runs persist
#     across the fresh-clone-per-drain, letting faff resume held builds exactly as it does
#     from a persistent local working dir. (Anchors are NOT here — they're committed to git.)
docker volume create faff-state >/dev/null

# 3. Pre-check: the eligible faff-automate issues in Backlog/Todo/In Progress/In Review for
#    the team. Prints their identifiers space-separated (empty = none). Exit 2 = unavailable (no
#    LINEAR_API_KEY, or the query failed); the caller then relies on the full cadence.
eligible_ids() {
  [ -n "${LINEAR_API_KEY:-}" ] || return 2
  local q resp
  # Genuinely-actionable = faff-automate present, NOT parked/held, and in a workable state.
  # state.type in [backlog, unstarted, started] means Backlog + Todo + In Progress + In Review
  # pass — done (completed), cancelled (canceled), and duplicate (duplicate) are excluded by
  # TYPE (Linear status names map onto these fixed types; "unstarted" is Todo, and "started"
  # covers both In Progress and In Review). Started is eligible so a held or orphaned build
  # left In Progress by an earlier drain is picked up and resumed; the drain lock serialises
  # firings, so the pre-check never collides with an issue a concurrent drain is building.
  # The label exclusion is the load-bearing fix: parking keeps faff-automate and leaves the
  # issue in Backlog/Todo, so without excluding faff-parked / faff-automation-hold a parked
  # issue keeps matching and the tick fires a full (expensive) drain every minute that
  # beep-boop's own gate then no-ops — a model session per tick for zero product. With both,
  # once nothing actionable remains the query returns empty and idle ticks cost one API call.
  # Also drop OPEN-BLOCKED issues: an issue blocked by an incomplete issue can't launch, so
  # firing on it is a near-no-op every tick until its blocker clears. Linear's filter can't
  # condition on the blocker's STATE, so fetch each candidate's blockers (inverseRelations of
  # type "blocks") and drop any candidate with a blocker not in a resolved state
  # (completed/canceled/duplicate) — client-side, in jq. A Done blocker means unblocked, so
  # it stays eligible; only genuinely-still-blocked issues are excluded.
  q='{"query":"query($t:String!){issues(first:50,filter:{and:[{labels:{some:{name:{eq:\"faff-automate\"}}}},{labels:{every:{name:{nin:[\"faff-parked\",\"faff-automation-hold\"]}}}}],team:{key:{eq:$t}},state:{type:{in:[\"backlog\",\"unstarted\",\"started\"]}}}){nodes{identifier inverseRelations{nodes{type issue{state{type}}}}}}}","variables":{"t":"'"$TEAM_KEY"'"}}'
  # Auth header via `-K -` (config on stdin), NOT `-H "Authorization: $LINEAR_API_KEY"`, so
  # the key never becomes a curl argv element visible in `ps`/`/proc` on the fly host. This
  # tick fires hourly, so an on-argv key would sit in host-visible argv far more often than
  # the drain secrets did. `printf` is a bash builtin (no forked process, no argv of its own),
  # and the config-file value is double-quoted; Linear keys are `[A-Za-z0-9_]`, so no escaping.
  # The query body stays on argv via -d (not secret); stdin is consumed only by -K.
  resp=$(printf 'header = "Authorization: %s"\n' "$LINEAR_API_KEY" \
           | curl -sS -K - --max-time 20 -X POST https://api.linear.app/graphql \
               -H "Content-Type: application/json" \
               -d "$q") || return 2
  echo "$resp" | jq -e '.data.issues.nodes' >/dev/null 2>&1 || return 2
  echo "$resp" | jq -r '[.data.issues.nodes[] | select(([.inverseRelations.nodes[]? | select(.type=="blocks") | .issue.state.type as $s | select((["completed","canceled","duplicate"]|index($s))==null)] | length)==0) | .identifier] | join(" ")'
}

# 4. Run one drain in a fresh cage container. $1 = explicit issue IDs (empty = full).
run_drain() {
  local ids="$1" label
  if [ -n "$ids" ]; then label="build [$ids]"; else label="full drain (tidy + discovery + build)"; fi
  echo "=== $(date -u +%FT%TZ) $label ==="
  # Secrets are passed NAME-ONLY (`-e KEY`, no `=value`): docker then inherits each value
  # from this process's env (fly injects the secrets into PID 1's env, which we inherit), so
  # the literal token never becomes a `docker run` argv element. `-e KEY=value` would expand
  # the value onto the command line, where any process that can read `ps`/`/proc/<pid>/cmdline`
  # on the fly host sees it for the drain's lifetime. Name-only closes that argv exposure while
  # staying behaviour-equivalent (drain.sh reads every optional one as `${KEY:-}`, so an unset
  # var docker simply omits is the same as the empty string it used to receive). Non-secret,
  # derived, or defaulted vars below stay `KEY=value` — nothing sensitive, and some are computed
  # here rather than inherited, so name-only would not carry them.
  if docker run --rm \
       -v faff-state:/home/faff/state \
       -e TARGET_REPO="$TARGET_REPO" \
       -e CLAUDE_CODE_OAUTH_TOKEN \
       -e CLAUDE_MCP_OAUTH_B64 \
       -e GH_TOKEN \
       -e GIT_OPERATOR_NAME \
       -e GIT_OPERATOR_EMAIL \
       -e GIT_SSH_SIGNING_KEY_B64 \
       -e FAFF_DRAIN_TIMEOUT="$DRAIN_TIMEOUT" \
       -e FAFF_ISSUE_IDS="$ids" \
       -e NVIDIA_API_KEY \
       -e GEMINI_API_KEY \
       -e GEMINI_API_KEY_FAFF_PAID \
       -e OPENROUTER_API_KEY \
       -e ANDON_URL \
       -e ANDON_TOKEN \
       -e FAFF_MODEL="${FAFF_MODEL:-claude-opus-4-8}" \
       -e FAFF_EFFORT="${FAFF_EFFORT:-high}" \
       -e FAFF_WINDOW_HOURS="${FAFF_WINDOW_HOURS:-5}" \
       -e FAFF_WINDOW_TOKENS="${FAFF_WINDOW_TOKENS:-}" \
       -e FAFF_REVIEW_SLOT="${FAFF_REVIEW_SLOT:-}" \
       -e FAFF_SPEC_REVIEW_SLOT="${FAFF_SPEC_REVIEW_SLOT:-}" \
       -e FAFF_DROP_BACKENDS="${FAFF_DROP_BACKENDS:-}" \
       -e ANDON_FORMAT="${ANDON_FORMAT:-}" \
       -e ANDON_EVENTS="${ANDON_EVENTS:-}" \
       faff-cage; then
    echo "=== $(date -u +%FT%TZ) drain clean (disposition exit 0) ==="
  else
    echo "=== $(date -u +%FT%TZ) drain needs attention (disposition non-zero) ==="
  fi
}

# 5. One startup report on whether the fast pre-check is available.
if ids=$(eligible_ids); then
  if [ -n "$ids" ]; then
    echo "pre-check: available. eligible now: $ids"
  else
    echo "pre-check: available. nothing eligible right now"
  fi
else
  echo "pre-check: UNAVAILABLE (no LINEAR_API_KEY or query error). Fast pickup is off; only the daily full drain at ${FULL_HOUR}:00 ${FULL_TZ} will trigger. Set LINEAR_API_KEY (and FAFF_TEAM_KEY if not '${TEAM_KEY}') to enable the ${TICK_SECS}s pre-check."
fi

# 5b. Warn if the review-backend keys are absent. faff's configured review slot may run an
#     adversarial second opinion (the faff repo's own .faffrc does, via nvidia/gemini/
#     openrouter). Missing keys are an AUTH fault, which surfaces needs-human, so every
#     build would park at the review step rather than merge. Not fatal to start (a target
#     repo may not use adversarial review), but loud so it is not discovered via parks.
if [ -z "${NVIDIA_API_KEY:-}" ] && [ -z "${GEMINI_API_KEY:-}" ] && [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "WARN: no NVIDIA_API_KEY / GEMINI_API_KEY / OPENROUTER_API_KEY set. If the target's review slot uses an adversarial backend (the faff repo does), builds will PARK at review (auth fault -> needs-human), not merge. Set the review-backend key(s) the target's .faffrc names."
fi

# 6. The loop. Cadence:
#    - CHEAP targeted pass (fast pre-check -> explicit-list drain of just the eligible issues,
#      which SKIPS tidy + discovery) on startup, then every TICK_SECS (FAFF_TICK_SECS, default 1h).
#    - one FULL drain (tidy + discovery + build) per day at FULL_HOUR in FULL_TZ (5am Eastern
#      default; the IANA zone tracks DST so it stays 5am local year-round).
#    flock serialises: a tick that cannot take the lock means a drain is still running and skips.
#    The last-full day is tracked in a marker file so the full fires at most once per calendar day.
FULL_MARK="/tmp/faff-last-full-day"
eastern_day()  { TZ="$FULL_TZ" date +%Y%m%d; }
eastern_hour() { echo $(( 10#$(TZ="$FULL_TZ" date +%H) )); }   # 10# forces base-10 (no octal 08/09 trap)

# Startup is CHEAP: seed the marker to today so the first full is tomorrow at FULL_HOUR (never on
# boot), then run one cheap targeted pass immediately so ready work starts without waiting an hour.
eastern_day > "$FULL_MARK"
echo "runner ready. cheap pre-check on startup + every ${TICK_SECS}s; full drain daily at ${FULL_HOUR}:00 ${FULL_TZ}."
if flock -n "$LOCK" -c true 2>/dev/null; then
  if hits=$(eligible_ids) && [ -n "$hits" ]; then
    echo "startup: eligible now [$hits] -> cheap targeted drain."
    ( exec 9>"$LOCK"; flock -n 9 || exit 0; run_drain "$hits" ) &
  else
    echo "startup: nothing eligible -> no drain (cheap)."
  fi
fi

while true; do
  sleep "$TICK_SECS"
  flock -n "$LOCK" -c true 2>/dev/null || continue   # a drain is still running -> skip this tick
  if [ "$(eastern_day)" != "$(cat "$FULL_MARK" 2>/dev/null)" ] && [ "$(eastern_hour)" -ge "$FULL_HOUR" ]; then
    # Daily full is due (new Eastern day, at/after FULL_HOUR, not yet run today). The marker is
    # written INSIDE the lock so a full skipped because another drain holds the lock is retried
    # next tick, and >= FULL_HOUR (not == ) means a full missed at 5am (drain still running) is
    # picked up by the 6am/7am tick rather than lost for the day.
    ( exec 9>"$LOCK"; flock -n 9 || exit 0; eastern_day > "$FULL_MARK"; run_drain "" ) &
  else
    # Cheap pre-check. Always log its outcome (error / eligible / nothing) so each
    # tick is itself the liveness signal -- no separate heartbeat. Only the eligible case
    # starts a drain; the flock guard above already prevents a parallel one.
    hits=$(eligible_ids); rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "$(date -u +%FT%TZ) pre-check: query error, fast pickup degraded (daily full still runs)"
    elif [ -n "$hits" ]; then
      echo "$(date -u +%FT%TZ) pre-check: eligible -> $hits"
      ( exec 9>"$LOCK"; flock -n 9 || exit 0; run_drain "$hits" ) &
    else
      echo "$(date -u +%FT%TZ) pre-check: nothing eligible"
    fi
  fi
done
