# fly-ci-l3-runner

An always-on faff L3 runner on a fly.io Machine, with no GitHub Actions. The Machine
wakes itself, drains the automation-eligible queue of a target repo with
`/faff-beep-boop`, opens PRs, and parks anything it cannot decide. Point it at your
repo, set its secrets, start one Machine, and leave. It checks the tracker for eligible
work once an hour with a cheap query, so a ticket you make eligible is picked up within
the hour, without spinning anything up when there is nothing to do.

## How it meets the gate

faff refuses to drain unless the run is contained (a container, with no host engine
socket reachable). A fly Machine is a Firecracker microVM, and a bare microVM presents
no container marker, so faff's gate fails on the Machine itself. So the Machine runs
its own docker engine and fires each drain inside a **cage container**, which does
present the marker. The gate passes inside the cage, not on the Machine. This is the
same nesting the earlier fly runner rig used, with dockerd on the vfs storage driver
because a microVM has no kernel overlay to mount.

Layers:

- The **Machine** (`Dockerfile`, `entrypoint.sh`) is the always-on host. It starts
  dockerd, builds the cage image once, then runs two cadences under one `flock` (only
  one drain at a time): a cheap hourly pre-check that, on a hit, builds just the eligible
  tickets, and a once-daily full `/faff-beep-boop` (5am Eastern) for grooming and catch-all.
- The **cage** (`cage/Dockerfile`, `drain.sh`) is the container each drain runs in. It
  carries the harness plus faff, runs `faff container-check --gate` first (passes),
  clones the target repo, runs `/faff-beep-boop` (over the whole queue, or over the
  specific issues the pre-check found), and exits through `faff disposition`.

## What you need first

- A fly.io account with `flyctl` logged in.
- A target repo whose issues you want drained, with the ones you want built labelled
  `faff-automate`. Nothing runs without that label. This can be the faff repo itself:
  faff draining faff at L3 is a supported case (the self-directed refusal is L4-only).
- A long-lived seat token for the model: run `claude setup-token` on your machine, which
  gives you a `CLAUDE_CODE_OAUTH_TOKEN`. Use this, not an interactive login, for CI. The
  interactive credentials carry a rotating refresh token, and a CI process refreshing it
  would race your own sessions and break auth on one side; the long-lived token does not
  rotate. The runner requires this and uses it for the model only.
- A `gh` token with push access to the target repo (for branches and PRs).
- Linear tracker access carried in (see below), which is separate from the seat token and
  used only for the Linear MCP. Without it, faff runs git-only and ignores Linear issues.
- A Linear personal API key for the per-minute pre-check (`LINEAR_API_KEY`), from
  Linear's Settings > API > Personal API keys. This is separate from the MCP auth: the
  pre-check is a lightweight tracker query, the MCP is how faff itself reads and writes
  Linear. Optional; without it the fast pickup is off and the runner works on the
  full-drain cadence only.
- The review-backend key(s) the target's `.faffrc` review slot names. The faff repo's own
  review slot is the adversarial reviewer, which uses `NVIDIA_API_KEY` (primary) with
  `GEMINI_API_KEY` and `OPENROUTER_API_KEY` as fallbacks. Missing keys are an auth fault,
  so every build would park at the review step (needs-human) instead of merging. Required
  when draining faff; not needed for a target whose review slot uses no external backend.

## Tracker (Linear)

faff drives Linear through the hosted Linear MCP at `https://mcp.linear.app/mcp`. faff's
skills call that server's tools by name, so the runner uses that exact server, not a
substitute. It is OAuth-authenticated, and there is no browser on a fly Machine to run
the authorization. So you authorize it once on your own machine, then carry the token.

```sh
# On your machine, once, authorize Linear for Claude Code (opens a browser):
claude mcp add --transport http linear https://mcp.linear.app/mcp
# use any faff command that reads Linear so the OAuth flow completes, then:
base64 < ~/.claude/.credentials.json | tr -d '\n'   # this is CLAUDE_MCP_OAUTH_B64 (macOS + Linux)
```

The cage writes back **only** the `mcpOAuth` (Linear) section of that file, never the
`claudeAiOauth` account section, so the account's rotating refresh token never lands in
CI and cannot race your sessions. Model auth stays entirely on the long-lived
`CLAUDE_CODE_OAUTH_TOKEN`. So Linear connects headlessly. This carried token is the one
fragile part of the runner: if
Linear's OAuth token expires and cannot refresh headlessly, the runner drops to git-only
until you refresh it. Watch the drain log for the `tracker: Linear MCP connected` line.

## Deploy

```sh
# 1. Create the app (no deploy yet).
fly launch --no-deploy --name fly-ci-l3-runner --region lhr

# 2. Set the secrets. These never enter the image or git.
#    CLAUDE_CODE_OAUTH_TOKEN is the long-lived seat (model) auth; CLAUDE_MCP_OAUTH_B64 is
#    the Linear MCP auth only. They are distinct jobs and both are needed to drain faff.
fly secrets set \
  TARGET_REPO="https://github.com/shftwst/faff" \
  GH_TOKEN="$(pass faff/gh)" \
  CLAUDE_CODE_OAUTH_TOKEN="$(pass faff/seat)" \
  CLAUDE_MCP_OAUTH_B64="$(base64 < ~/.claude/.credentials.json | tr -d '\n')" \
  LINEAR_API_KEY="$(pass linear/api)" \
  NVIDIA_API_KEY="$(pass faff/nvidia)" \
  GEMINI_API_KEY="$(pass faff/gemini)" \
  OPENROUTER_API_KEY="$(pass faff/openrouter)"

# 3. Optional: the subscription-window budget. Set FAFF_WINDOW_TOKENS to turn it on (the
#    drain then writes it into the clone); leave it unset to run without a window (the drain
#    wall-clock timeout and the subscription's own limit still apply). See the note below on
#    sizing, and why you may not need this at all if you never saturate the window.
fly secrets set FAFF_WINDOW_HOURS=5 FAFF_WINDOW_TOKENS=<your window token ceiling>

# 3b. Optional: andon push-alerting. Set ANDON_URL to a webhook to get a minimal push
#     notification (issue IDs + event class only) on parks, sentry trips, budget breaches,
#     and (if you add run-end) drain completion. Set ANDON_FORMAT to match the sink.
fly secrets set ANDON_URL="$(pass faff/andon-webhook)" ANDON_FORMAT=slack \
  ANDON_EVENTS=park,sentry-trip,budget-breach,run-end

# 4. Optional tuning (defaults: hourly cheap tick, daily full at 5am Eastern, hard-timeout =
#    window+1h, team FAFF, model claude-opus-4-8, effort high). Leave FAFF_DRAIN_TIMEOUT unset
#    to keep it derived above the window; only set it if you deliberately want a different
#    ceiling (and keep it > FAFF_WINDOW_HOURS, or the SIGKILL culls the drain before it parks).
fly secrets set FAFF_TICK_SECS=3600 FAFF_FULL_HOUR=5 FAFF_FULL_TZ=America/New_York \
  FAFF_TEAM_KEY=FAFF FAFF_MODEL=claude-opus-4-8 FAFF_EFFORT=high

# 4. Build the image on fly's remote builder and push it. This works from macOS with no
#    local Docker; fly builds it, not your machine.
fly deploy --build-only --push --app fly-ci-l3-runner
#    Note the image ref it prints, e.g. registry.fly.io/fly-ci-l3-runner:deployment-XXXX.

# 5. Start ONE standalone Machine from that image. Do not use `fly deploy` to run it: its
#    release monitor can restart-loop a slow first boot (dockerd + the cage build).
fly machine run <image-ref-from-step-4> --app fly-ci-l3-runner

# 6. Watch it come up: dockerd, then the cage build, then the first drain.
fly logs --app fly-ci-l3-runner
```

If you keep the values in a gitignored `.env` (one `KEY=value` per line), load them in
one shot with `fly secrets import < .env` instead of the `fly secrets set` above. The
`.env` stays on your machine; only the values go to fly's encrypted secret store, never
the file, and never the image. (`.env` is gitignored here so it cannot be committed.)

Stop it when you land: `fly machine list` then `fly machine destroy <id> --force`.

## Updating a running Machine

To roll out a code change (a new `entrypoint.sh`, `drain.sh`, or `Dockerfile`) onto the
Machine you already started, update its image in place. This keeps the same Machine and its
`faff_docker` volume (the docker image cache plus the built cage image), so you neither
re-pay the first-boot cage build nor lose any persisted `.faff` state on the volume. Do not
use `fly deploy` for this, for the same restart-loop reason as the first boot.

```sh
# 1. Build and push the new image (same as the first deploy).
fly deploy --build-only --push --app fly-ci-l3-runner
#    Note the image ref it prints, e.g. registry.fly.io/fly-ci-l3-runner:deployment-XXXX.

# 2. Find the Machine ID.
fly machine list --app fly-ci-l3-runner

# 3. Swap the image on that Machine, keeping its volume. The mount is preserved
#    automatically, so faff_docker stays attached. --skip-start leaves a stopped Machine
#    stopped; drop it to start the Machine as part of the update.
fly machine update <machine-id> --image <image-ref-from-step-1> --skip-start --yes

# 4. Start the Machine (if it was stopped, or you used --skip-start above).
fly machine start <machine-id>
```

Right after the push, step 3 can fail with a 404 `manifest unknown` for the image digest:
that is registry replication lag, not a bad image. Wait a few seconds and retry the same
`fly machine update`; it succeeds once the manifest propagates.

## The controls

Set as fly secrets or env:

- `TARGET_REPO` (required): the repo to drain.
- `GH_TOKEN` (required): a git token with push access, for branches and PRs.
- `CLAUDE_CODE_OAUTH_TOKEN` (required): the long-lived seat token (`claude setup-token`),
  used for the model only. Not the interactive credentials (those rotate and would race).
- `CLAUDE_MCP_OAUTH_B64` (required for Linear): base64 of `~/.claude/.credentials.json`;
  the cage uses only its `mcpOAuth` section, to connect the Linear MCP.
- `LINEAR_API_KEY` (enables the fast pre-check): a Linear personal API key.
- `NVIDIA_API_KEY` / `GEMINI_API_KEY` / `OPENROUTER_API_KEY`: review-backend keys the
  target's review slot needs (required for faff; builds park at review without them).
- `FAFF_WINDOW_TOKENS` (optional; unset = window off): the token ceiling for the subscription
  window. When set, the drain writes `budget.window.{hours,tokens}` and `at_ceiling:
  park-until-window-reset` into the clone, so an unattended run parks when the window's tokens
  are spent and resumes when the window resets, instead of running the model session into the
  raw subscription rate limit mid-build. When unset, the drain writes no budget config (the
  clone's committed config stands) and relies on `FAFF_DRAIN_TIMEOUT` plus the subscription's
  own limit. On a subscription seat there is no overage billing, so the window's only job is a
  clean pre-emptive park; skip it unless you actually saturate the window and want that.
- `FAFF_WINDOW_HOURS` (default 5): the window length; match your subscription usage window.
  Only takes effect when `FAFF_WINDOW_TOKENS` is set. It also derives the default
  `FAFF_DRAIN_TIMEOUT` (window + 1h) even when the window itself is off.
- `FAFF_MODEL` (default `claude-opus-4-8`) / `FAFF_EFFORT` (default `high`): the model and
  effort the drain's `claude -p` runs on.
- `FAFF_TEAM_KEY` (default `FAFF`): the tracker team the pre-check queries.
- `FAFF_TICK_SECS` (default 3600 = hourly): the cheap pre-check cadence.
- `FAFF_FULL_HOUR` (default 5): hour-of-day (0-23) for the once-daily full drain.
- `FAFF_FULL_TZ` (default `America/New_York`): the zone `FAFF_FULL_HOUR` is read in. An IANA
  name keeps it correct across DST (so 5 stays 5am Eastern year-round).
- `FAFF_DRAIN_TIMEOUT` (default: window + 1h when the window is on, else 24h): last-resort
  wall-clock SIGKILL for a single drain, and only a BACKSTOP. faff's sentry poller (spawned by
  beep-boop on every run, resumably aborting on a ~900s stale heartbeat or its 4h run-elapsed
  ceiling, since `drain.sh` sets `autonomous.sentry_acting` in the clone) is the real wedge guard; this timeout
  only covers the case where that poller never started. When the window is on, the default sits
  above it so the window parks gracefully before this SIGKILL fires; keep any explicit value
  above `FAFF_WINDOW_HOURS`. When the window is off, the default is a coarse 24h ceiling well
  above faff's 4h sentry ceiling (deliberately high WHILE the sentry-owned wedge handling is
  being tested; tighten once confirmed). If you use the window, note it counts all token classes
  including cache reads, which dominate on Opus, so size `FAFF_WINDOW_TOKENS` in hundreds of
  millions, not single millions (faff's own all-run backstop is 3000M for comparison).
- `ANDON_URL` (optional; unset = andon off): a webhook the drain points faff's andon channel
  at, so it POSTs a minimal push notification (issue IDs + event class only, never spec, diff,
  or transcript content) on run-critical events. Unset is a complete no-op; setting it is the
  only thing that turns andon on. Treat it as a secret (a Slack/Discord webhook URL is itself
  the credential), so it is passed into the cage name-only, never on the `docker run` argv.
- `ANDON_FORMAT` (optional; default faff's own `generic`): the payload shape for the sink —
  `generic`, `ntfy`, `slack`, or `discord`. A Slack or Discord webhook rejects the generic
  payload, so set this to match the sink (e.g. `slack` for a Slack incoming webhook).
- `ANDON_TOKEN` (optional): a bearer/auth token for sinks that need one (e.g. ntfy). Also a
  secret, so passed name-only. Slack/Discord incoming webhooks carry their auth in the URL and
  need no token.
- `ANDON_EVENTS` (optional; default `park,sentry-trip,budget-breach`): a comma-separated
  subset of the andon event classes — `park`, `sentry-trip`, `budget-breach`, `run-end` — to
  notify on. Unset uses faff's default set, which omits `run-end`; add it here to be pinged on
  every drain's completion.
- `TS_AUTHKEY` (optional; unset = tailnet off): a tailscale OAuth **client secret**
  (`tskey-client-...`) that joins the always-on Machine to your tailnet, so a drain can reach
  tailnet-only hosts. An OAuth client secret is used rather than a plain auth key because it
  does not expire (a 90-day auth key would silently fail to rejoin on a reboot past its expiry,
  on an unattended box) and mints an ephemeral, tag-scoped node key each boot. The entrypoint
  appends `?ephemeral=true&preauthorized=true` unless the value already carries query params.
  Tailnet bring-up is best-effort: any failure warns and continues, it never fails the runner.
  The bridged cage reaches tailnet IPs via the host route plus docker's bridge MASQUERADE, so
  no cage change is needed. Treat it as a secret; pass it as a fly secret.
- `TS_TAG` (default `tag:ci`): the ACL tag the node advertises. It must be a tag the OAuth
  client is granted in the tailnet policy, or `tailscale up` is rejected.
- `TS_HOSTNAME` (default `fly-ci-l3-runner`): the node name shown in the tailscale admin
  console.

**Triggering.** Two cadences share one lock, so only one drain runs at a time:

- **Cheap (on startup, then every `FAFF_TICK_SECS`):** a cheap Linear query for
  `faff-automate` issues in Backlog, Todo, In Progress, or In Review. On a hit, it builds just those issues
  (`/faff-beep-boop <IDs>`, which skips tidy). Startup runs one immediately so ready work
  starts without waiting; an idle tick is one API call, no container and no claude session,
  so leaving it running is cheap.
- **Full (once a day at `FAFF_FULL_HOUR` in `FAFF_FULL_TZ`, default 5am Eastern):** a full
  `/faff-beep-boop` (tidy, discovery, build). This grooms the backlog and catches anything
  the cheap pre-check missed. It does **not** run on startup (startup is the cheap pass), so
  a same-day start still waits for the next 5am; the cheap hourly pass carries build work in
  the meantime. Tidy's autonomous mutations (dead-link strip, stale-park clear, repeat-park
  demote, container status advance, chain-gap ticket creation at `appetite: high`) happen
  only in this daily full, never in the cheap passes.

A fresh clone per drain suits L3, which keeps no state between firings and pushes each
branch at build-complete. Without `LINEAR_API_KEY` the fast cadence is off and only the
full cadence runs (higher pickup latency, still correct).

## Notes

- Budget: cap the spend from the target repo's own `.faffrc` (`budget.window`, or a
  token or cost ceiling). `FAFF_DRAIN_TIMEOUT` only bounds wall-clock, not spend.
- Disk: vfs duplicates image layers. If the cage build runs out of space, give the
  Machine a bigger size or mount a fly volume at `/var/lib/docker`.
- Target repo: the faff repo is a valid target. Faff draining its own backlog at L3 is
  the self-directed watcher case that the sentry-acting knob was added for. Only L4
  (`faff lights-out`) refuses a self-directed run; this runner is L3.
- Install: faff goes in via its plugin marketplace (`claude plugin marketplace add
  shftwst/faff` then `claude plugin install faff@faff`), the supported consumer path,
  not the repo's dev-only `link-skills.sh`. To move the runner to a newer faff, rebuild
  the image or add `claude plugin update faff@faff`.
- Live output: the drain runs `claude -p` with `--output-format stream-json --verbose`,
  so `fly logs` shows the run turn-by-turn as it happens (line-delimited JSON events).
  The durable record is still the run-ledger plus the disposition exit, not the stream.
- Idle cost: with `LINEAR_API_KEY` set, an idle minute is one Linear API call, so this is
  cheap to leave running. The tidy grooming that a full drain does runs on the
  `FAFF_FULL_SECS` cadence (hourly by default), not every minute.
- Pre-check scope: the fast query matches `faff-automate` issues in Backlog, Todo, In Progress,
  or In Review for `FAFF_TEAM_KEY`. In Progress and In Review (both Linear's `started` type) are
  eligible so a held or orphaned build is resumed, not stranded until the daily full. It is an
  optimisation, not the safety net; the full drain's own
  discovery is the authority, so a subtly-wrong query only delays work to the full
  cadence, it never drops it.
