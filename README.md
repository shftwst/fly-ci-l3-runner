# fly-ci-l3-runner

An always-on faff L3 runner on a fly.io Machine, with no GitHub Actions. The Machine
wakes itself, drains the automation-eligible queue of a target repo with
`/faff-beep-boop`, opens PRs, and parks anything it cannot decide. Point it at your
repo, set its secrets, start one Machine, and leave. It checks for work every minute,
so a ticket you make eligible is picked up in about a minute, not on a long fixed cycle.

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
  dockerd, builds the cage image once, then ticks every minute, starting a drain only
  when one is not already running (a `flock` is the guard).
- The **cage** (`cage/Dockerfile`, `drain.sh`) is the container each drain runs in. It
  carries the harness plus faff, runs `faff container-check --gate` first (passes),
  clones the target repo, runs `/faff-beep-boop`, and exits through `faff disposition`.

## What you need first

- A fly.io account with `flyctl` logged in.
- A target repo whose issues you want drained, with the ones you want built labelled
  `faff-automate`. Nothing runs without that label. This can be the faff repo itself:
  faff draining faff at L3 is a supported case (the self-directed refusal is L4-only).
- A long-lived seat token: `claude setup-token` gives you a `CLAUDE_CODE_OAUTH_TOKEN`.
- A `gh` token with push access to the target repo (for branches and PRs).
- Linear tracker access carried in (see below). Without it, faff runs git-only and
  ignores your Linear issues.

## Tracker (Linear)

faff drives Linear through the hosted Linear MCP at `https://mcp.linear.app/mcp`. faff's
skills call that server's tools by name, so the runner uses that exact server, not a
substitute. It is OAuth-authenticated, and there is no browser on a fly Machine to run
the authorization. So you authorize it once on your own machine, then carry the token.

```sh
# On your machine, once, authorize Linear for Claude Code (opens a browser):
claude mcp add --transport http linear https://mcp.linear.app/mcp
# use any faff command that reads Linear so the OAuth flow completes, then:
base64 -w0 ~/.claude/.credentials.json     # this is CLAUDE_CREDENTIALS_B64
```

The cage writes that back to `~/.claude/.credentials.json` at drain time, so Linear
connects headlessly. This carried token is the one fragile part of the runner: if
Linear's OAuth token expires and cannot refresh headlessly, the runner drops to git-only
until you refresh it. Watch the drain log for the `tracker: Linear MCP connected` line.

## Deploy

```sh
# 1. Create the app (no deploy yet).
fly launch --no-deploy --name fly-ci-l3-runner --region lhr

# 2. Set the secrets. These never enter the image or git.
fly secrets set \
  TARGET_REPO="https://github.com/shftwst/faff" \
  CLAUDE_CODE_OAUTH_TOKEN="$(pass faff/seat)" \
  GH_TOKEN="$(pass faff/gh)" \
  CLAUDE_CREDENTIALS_B64="$(base64 -w0 ~/.claude/.credentials.json)"

# 3. Optional tuning (defaults: 60s tick, 290m ceiling per drain).
fly secrets set FAFF_TICK_SECS=60 FAFF_DRAIN_TIMEOUT=290m

# 4. Start ONE standalone Machine. Not `fly deploy` (its release-health wait can
#    restart-loop a slow first boot).
fly machine run . --app fly-ci-l3-runner

# 5. Watch it come up: dockerd, then the cage build, then the first drain.
fly logs --app fly-ci-l3-runner
```

If you keep the values in a gitignored `.env` (one `KEY=value` per line), load them in
one shot with `fly secrets import < .env` instead of the `fly secrets set` above. The
`.env` stays on your machine; only the values go to fly's encrypted secret store, never
the file, and never the image. (`.env` is gitignored here so it cannot be committed.)

Stop it when you land: `fly machine list` then `fly machine destroy <id> --force`.

## The controls

Set as fly secrets or env:

- `TARGET_REPO` (required): the repo to drain.
- `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN` (required): the seat token and the git token.
- `CLAUDE_CREDENTIALS_B64` (required for Linear): the carried tracker credentials.
- `FAFF_TICK_SECS` (default 60): seconds between ticks. A tick starts a drain only if
  none is running.
- `FAFF_DRAIN_TIMEOUT` (default 290m): wall-clock ceiling for a single drain.

**Triggering.** Every `FAFF_TICK_SECS` the Machine checks whether a drain is running. If
one is, the tick skips; if not, it starts a fresh `/faff-beep-boop`, which re-checks
eligibility and exits fast when there is nothing to do. So a ticket you make eligible is
picked up within about a tick, and two drains never overlap. Each drain is one beep-boop
over the ready queue (tidy, prep, build, park the rest); a fresh clone per drain suits
L3, which keeps no state between firings and pushes each branch at build-complete.

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
- Idle cost of the 60s tick: when there is no work, a short beep-boop still spins up each
  idle minute to check, which spends some seat/token and tracker calls continuously. For
  a bounded away-from-keyboard window that is fine. For a permanent runner, a cheaper
  pre-check (query the tracker for eligible tickets and only launch beep-boop on a hit)
  would cut the idle churn; it is a sensible follow-up, not built here.
