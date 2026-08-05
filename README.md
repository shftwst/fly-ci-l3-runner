# fly-ci-l3-runner

An always-on faff L3 runner on a fly.io Machine, with no GitHub Actions. The Machine
wakes itself, drains the automation-eligible queue of a target repo with
`/faff-beep-boop`, opens PRs, and parks anything it cannot decide. Point it at your
repo, set its secrets, start one Machine, and leave. It checks the tracker for eligible
work every minute with a cheap query, so a ticket you make eligible is picked up in
about a minute, without spinning anything up when there is nothing to do.

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
  one drain at a time): a fast per-minute pre-check that, on a hit, builds just the
  eligible tickets, and a slower full `/faff-beep-boop` for grooming and as a catch-all.
- The **cage** (`cage/Dockerfile`, `drain.sh`) is the container each drain runs in. It
  carries the harness plus faff, runs `faff container-check --gate` first (passes),
  clones the target repo, runs `/faff-beep-boop` (over the whole queue, or over the
  specific issues the pre-check found), and exits through `faff disposition`.

## What you need first

- A fly.io account with `flyctl` logged in.
- A target repo whose issues you want drained, with the ones you want built labelled
  `faff-automate`. Nothing runs without that label. This can be the faff repo itself:
  faff draining faff at L3 is a supported case (the self-directed refusal is L4-only).
- A long-lived seat token: `claude setup-token` gives you a `CLAUDE_CODE_OAUTH_TOKEN`.
- A `gh` token with push access to the target repo (for branches and PRs).
- Linear tracker access carried in (see below). Without it, faff runs git-only and
  ignores your Linear issues.
- A Linear personal API key for the per-minute pre-check (`LINEAR_API_KEY`), from
  Linear's Settings > API > Personal API keys. This is separate from the MCP auth: the
  pre-check is a lightweight tracker query, the MCP is how faff itself reads and writes
  Linear. Optional; without it the fast pickup is off and the runner works on the
  full-drain cadence only.

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
  CLAUDE_CREDENTIALS_B64="$(base64 -w0 ~/.claude/.credentials.json)" \
  LINEAR_API_KEY="$(pass linear/api)"

# 3. Optional tuning (defaults: 60s fast tick, 3600s full drain, 290m ceiling, team FAFF).
fly secrets set FAFF_TICK_SECS=60 FAFF_FULL_SECS=3600 FAFF_DRAIN_TIMEOUT=290m FAFF_TEAM_KEY=FAFF

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
- `LINEAR_API_KEY` (enables the fast pre-check): a Linear personal API key.
- `FAFF_TEAM_KEY` (default `FAFF`): the tracker team the pre-check queries.
- `FAFF_TICK_SECS` (default 60): the fast pre-check cadence.
- `FAFF_FULL_SECS` (default 3600): the full-drain (grooming + catch-all) cadence.
- `FAFF_DRAIN_TIMEOUT` (default 290m): wall-clock ceiling for a single drain.

**Triggering.** Two cadences share one lock, so only one drain runs at a time:

- **Fast (every `FAFF_TICK_SECS`):** a cheap Linear query for `faff-automate` issues in
  Backlog or Todo. On a hit, it builds just those issues (`/faff-beep-boop <IDs>`, which
  skips tidy). A ticket you make eligible is picked up within about a tick. An idle tick
  is one API call, no container and no claude session, so leaving it running is cheap.
- **Full (every `FAFF_FULL_SECS`):** a full `/faff-beep-boop` (tidy, discovery, build).
  This grooms the backlog and catches anything the pre-check missed, so a wrong or
  unavailable pre-check degrades to work on this cadence, never to silence. The first
  tick runs one immediately, clearing any queued backlog at startup.

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
- Pre-check scope: the fast query matches `faff-automate` issues in Backlog or Todo for
  `FAFF_TEAM_KEY`. It is an optimisation, not the safety net; the full drain's own
  discovery is the authority, so a subtly-wrong query only delays work to the full
  cadence, it never drops it.
