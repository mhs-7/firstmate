# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.
Done retention moves closed items from the live backlog into `data/done-archive.md` without changing their serialized form, so `verify` and `complete` accept a kind `captain` archived item carrying the resolution marker as the same durably resolved hold.
A later `verify` of an origin whose volatile state records an earlier cleanup already removed proves the completed lifecycle from the durable backlog store alone.
Every `<origin-id>-decision-<key>` identity found in the live backlog or the archive must be durably held or durably resolved, and every structured decision still open in surviving status must be one of them.
An origin with neither completion metadata nor any archived resolution still fails.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked captain hold as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Resolved-hold Done-retention and reaped-metadata regression verification date: 2026-08-21.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.
The Done-retention regression drives real `tasks-axi prune` mechanics so a resolved hold leaves the live backlog for the archive, then requires `verify` and scout teardown to pass, requires a reaped-metadata origin to verify from the archive alone while a never-reviewed origin keeps refusing, and requires an inventoried key with no durable hold anywhere to keep refusing with both searched locations named.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - a resolved hold verifies and tears down after Done-retention pruning
ok - archived lifecycles verify without metadata while never-existed origins still refuse
ok - inventoried keys without any durable hold still refuse verification

$ bin/fm-test-run.sh --changed --base origin/main
FM_TEST_SUMMARY total=29 failed=0 skipped_gate=2 duration_ms=219466

$ bash tests/fm-fleet-snapshot-view.test.sh && bash tests/fm-bearings-snapshot.test.sh \
  && bash tests/fm-brief.test.sh && bash tests/fm-teardown.test.sh
(no output; all four suites exit 0)

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)
```

The sibling snapshot, bearings, brief, and teardown suites pass on the same date with exit 0.
