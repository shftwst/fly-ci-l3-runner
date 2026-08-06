# fly-ci-l3-runner: post-mortem of the 2026-08-04/05 unattended run

Reconstructed 2026-08-06 from the surviving evidence after the machine was shut down for
excessive subscription spend with no shipped code. Machine `2873567cd07d58`, app
`fly-ci-l3-runner`, region lhr.

## What we could and could not recover, and why

The machine kept almost no forensic trail, and that is itself the first finding. The image
that was actually deployed (`deployment-01KZ8FPWVT...`) predates the state-persistence fix,
so:

- `docker volume ls` on the machine is empty. The `faff-state` named volume (the durable
  home for `.faff/runs`, `.faff/resume`) was never created by the running image.
- every cage ran as `docker run --rm`, so each container, with its run-dir, was deleted the
  moment it exited. `docker ps -a` is empty.
- `.faff/runs` exists nowhere on the machine's own filesystem either, because the old
  drain wrote it inside the ephemeral cage, not to a mount.
- the fly log shipper only retains roughly the last five minutes (22:15 to 22:20), so the
  streamed output of every run before the last one is gone.

So there is no per-run artifact history for the roughly 13 hours of draining. What survives:

1. the fly log buffer, which happened to capture the final run in full (its two end-of-run
   report blocks summarise the whole run), saved under `scrubbed/`.
2. Linear, the durable record of what the runner actually changed: specs attached and
   refreshed, parks, status moves, all timestamped. Saved under `linear/`.
3. the machine's own metadata (created 2026-08-05T01:58:07Z, suspended 22:20:05Z, so it
   existed about 20.4 hours).

Everything below separates hard evidence from bounded estimate.

## The final run, fully characterised (hard evidence)

Run `run-20260805-220635-beepboop-list`, an explicit-list beep-boop over 43 issues.

- Wall clock: 22:06:35Z start to 22:18:51Z final report, about 12 minutes 16 seconds.
- Tokens: 5,619,191 (transcript basis). Cost 5.52 USD at map pricing; 12.55 USD on the
  cache-inclusive model-usage basis (cache reads dominate Opus: 5,590,503 cache-read tokens
  in this one run).
- Shipped: 0. Buckets: 6 parked, 34 routed-out to needs-human, 3 on hold.

Two environmental faults at preflight:

1. `GH_TOKEN` invalid for push. `git ls-remote` (read) succeeds, `git push` fails with
   `remote: Invalid username or token`. This is the push precondition graft pre-flights
   before every build.
2. branch-protection indeterminate, same auth cause, advisory only.

The runner behaved correctly on the fault. It confirmed the push failure once at the
orchestrator level and declined to launch the six otherwise-ready graft dispatches, since
each would only rediscover the same fault. So the auth fault wasted almost no build spend;
the six ready issues parked `retry-later: precondition:push`, keeping Todo and spec state to
auto-resume on the next run.

Six issues were genuinely build-ready and blocked only on push: FAFF-708, 707, 705, 699,
662, 616.

## Durable product actually delivered (hard evidence, from Linear)

The run window was not pure waste. The runner produced and refreshed real specs, which
persist on Linear:

- FAFF-616: full `confidence: high` spec attached 2026-08-05T06:33:40Z, then a re-validation
  refresh at 16:45:12Z (spec-review approve, structural anchors re-checked against HEAD).
- FAFF-708: spec refreshed 2026-08-05 with three spec-review lens objections (architecture,
  infosec, QA) folded in as closed decisions, returning approve.

Across 2026-08-05 there are roughly seven to eight distinct timestamp clusters where the
runner mutated Linear (spec refreshes plus parks), spanning about 10:30 to 21:30. These are
only the runs that wrote to the tracker; the many characterisation-only runs (like the final
22:06 run, which posted no per-issue comments by design) leave no Linear trace, so this
undercounts total runs.

## Spend, reconstructed (bounded estimate, not measured)

The exact run count and total token spend are unrecoverable (artifacts gone, no-write runs
invisible in Linear). What we can bound:

- the loop serialises runs under one lock, and a run holds it for its whole roughly
  12-minute duration. Before the pre-check fix, the cheap Linear query returned the full
  parked-inclusive set on every tick, so the tick after each run immediately fired another
  run. Effectively back-to-back, about five runs per hour.
- over about 13 hours of active draining that is on the order of 60 runs.
- at about 5.6 million tokens and 5.52 to 12.55 USD per run, that is on the order of 300 to
  800 USD and several hundred million tokens, essentially all of it producing zero PRs and,
  after the first prep of each issue, zero incremental product.

Treat these as order-of-magnitude. The load-bearing fact is qualitative: dozens of full,
expensive beep-boop runs fired back-to-back, re-doing the same discovery and re-refreshing
the same specs, and none could ship because push was down.

## Root findings

1. Pre-check re-fire (the spend driver). The cheap eligibility query filtered only on
   `faff-automate` plus Backlog/Todo. Parking keeps both, so once everything had been picked
   up and parked, the query still returned a full set and fired a fresh, expensive run every
   cycle for a no-op. This is what turned a quiet overnight watcher into a back-to-back
   spend loop.

2. Push auth in the cage (the no-PR driver). The cage's `git push` failed with `Invalid
   username or token` while `git ls-remote` (read) succeeded. This is not a token-capability
   problem: the operator uses one long-standing token with full push and admin, and there
   was no second or new token. The only reconciliation is that the value which reached the
   fly `GH_TOKEN` secret was not that working token intact and usable headlessly, most
   likely a capture error when the secret was set (wrong source variable, or a
   truncated/whitespace value). It cannot be proven after the fact: fly secrets are
   write-only, so the stored value cannot be read back, and the image that ran is superseded.
   Every build-ready issue hit the same shared-credential fault, so nothing could merge. The
   boot preflight added in the fix makes this self-diagnosing on the next deploy.

3. No state persistence (the compounding waste, and why this post-mortem is thin). The
   deployed image never created the state volume and ran every cage with `--rm`. So no build
   could resume, every run re-did discovery from cold, and every run's evidence was deleted
   on exit. The persistence gap both inflated the spend and destroyed the trail.

## Fixes, mapped to each finding

- Finding 1: the pre-check now excludes `faff-parked`, `faff-automation-hold`, done,
  cancelled, duplicate, and open-blocked issues. On the same board the eligible set drops
  from 43 to 15, and once nothing is genuinely actionable it returns empty, so an idle tick
  costs one Linear API call, no cage and no model session.

- Finding 2: two-part. The drain now uses gh-native auth (`gh auth setup-git`) plus a
  boot-time push preflight that asserts the token can push the target before any model
  session and refuses loudly otherwise. That converts a silent per-run push-park into a
  single red exit at startup. The other part is on the operator: set the fly `GH_TOKEN`
  secret to a push-capable token, not the flagged short-lived one.

- Finding 3: the runner now creates a `faff-state` named volume and mounts it into each
  cage, symlinking `.faff/resume` and `.faff/runs` onto it, so held builds resume and run
  artifacts survive the fresh-clone-per-drain. Committed anchors stay in git. This also
  means the next run like this one will leave a full artifact trail to mine.

## Redeploy-and-verify sequence (for when a push-capable token is in hand)

1. set the token secret: `fly secrets set GH_TOKEN=<push-capable-token> --app fly-ci-l3-runner --stage`
2. deploy staged secrets and the new image, then start one Machine per the runner README
   (not `fly deploy`, whose release-health wait can restart-loop a slow boot).
3. confirm the preflight line `auth preflight: token can push to shftwst/faff` appears in
   `fly logs` before trusting the drain. If it prints the FATAL push line instead, the token
   is still wrong and no spend has been incurred.

## Evidence index

- `scrubbed/fly-logs-buffer-capture2.jsonl` — the fly log buffer, 22:15 to 22:20, containing
  the final run's full end-of-run report and economics. Credential-shaped strings redacted.
- `scrubbed/fly-logs-buffer-capture1.jsonl` — an earlier, shorter capture of the same window.
- `scrubbed/dockerd-log-current.txt` — dockerd log after the inspection restart (this-session
  boot only; the earlier history was truncated by the restart).
- `linear/FAFF-708-comments.json` — the FAFF-708 comment thread, including the refreshed spec,
  as durable-product evidence.
- `raw/` — the unredacted originals, kept local only, not for sharing.
