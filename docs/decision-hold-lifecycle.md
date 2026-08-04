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

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It enumerates the active home's blocked work through `tasks-axi list --blocked` and refuses while any task it finds still carries a `blocked-by` edge to the hold without being named by `--routed-to`, so the caller's list can no longer under-report dependent work.
It requires the canonical regular `data/decisions/<hold-id>.md` record and verifies that every routed task's durable body or brief points to that exact path before any mutation.
It requires ownership of the home session lock because direct concurrent backlog mutation is unsupported.
It enumerates blocked dependents again before the first write and refuses if that inventory changed.
It re-reads the captain's current reply through `bin/fm-captain-ruling-check.sh --answer` and refuses when that reply differs from the prepared decision record.
Reply ingestion and resolution serialize through one scoped ruling-resolution lock.
The resolver compares the locked ruling revision again immediately after the initial hold-body write and rolls back that uncommitted write before refusing if a lock-bypassing writer changed the ruling at the update boundary.
These checks only refuse and never supply decision text.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
Such a retry skips the captain re-read, because the hold body already carries that exact decision and the retry only finishes committing it; a reply revised after the commit therefore cannot strand a half-routed hold, and a genuinely different decision is still rejected by the retry identity record.
A failed intermediate step leaves the hold open.

## Accepted local ruling threat model

The file-backed reply channel is not trusted or authenticated.
This is an accepted weakness for a single-user machine where every agent already runs as the captain's UID and can modify `bin/` directly.
A compromised local process can fabricate a ruling, and no signing key, shared secret, or separate authenticated channel is added because that would defend one door in an already-open house.
The detection boundary is human detection: a fabricated record in `data/decisions/` does not match any ruling the captain remembers making.
Captain rulings normally arrive in chat or Linear.
The queue file is only a fallback and does not become the primary ruling path.

`bin/fm-captain-ruling-check.sh` emits only privacy-safe hold identities from its watcher path.
It reads replies from the same `<!-- BEGIN/END APPEND-ONLY: captain-replies -->` region that `bin/fm-pending-decisions-generate.sh` appends reply prefixes to, so the captain can rename, move, or rewrite the surrounding headings and prose without silencing detection, and a missing or malformed marker pair yields no candidates instead of a partial scan.
Its explicit `--answer <hold-id>` read returns the latest complete answer only while that captain hold is still open and leaves `data/pending-decisions.md` unchanged.
On that wake, the lifecycle skill owns the semantic agent turn: it reads the origin and key from the hold body, writes the exact answer to `data/decisions/<hold-id>.md`, authors dependent backlog work behind the hold, and delegates closure to `resolve`.
The resolver remains the only close path, so a status-only change, missing work item, or missing dependency edge cannot close the captain decision.

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
Captain-ruling round-trip verification date: 2026-08-03.
Review-finding regression verification date: 2026-08-04.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.
The undisclosed-dependent and superseded-ruling regressions each carry an anti-tautology proof: the same fixture is replayed against a copy of `bin/fm-decision-hold.sh` whose single refusal has been turned into a no-op, and the proof asserts that the falsified copy closes the hold.
Two further regressions drive a resolve that commits its decision and then fails midway through clearing edges, and prove both retry directions from that state: an exact retry finishes routing even after the captain revised the reply, and a retry carrying a different decision is still refused.
Each of those directions carries its own anti-tautology proof, one falsifying the committed-decision skip and one falsifying the retry identity record's decision comparison.

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
ok - a detected ruling becomes durable dependent work before its hold closes
ok - re-hold rejects malformed identity collisions and preserves canonical idempotence
ok - resolve requires the canonical record and exact routed-work pointer
ok - resolve requires its session lock and refuses a changed dependent set
ok - resolve discovers every still-blocked dependent and refuses an undisclosed one
ok - resolve re-reads the captain ruling and refuses a superseded decision record
ok - ruling revision CAS prevents closure on text changed at the update boundary
ok - an exact retry finishes routing a committed decision after a revised reply
ok - a partial-resolve retry carrying a different decision is still refused
ok - captain-ruling wakes load the single lifecycle owner and preserve close ordering

$ bash tests/fm-captain-ruling-check.test.sh
ok - one private single-link global check is registered
ok - new rulings wake once while malformed, unchanged, and resolved ids stay silent
ok - the check finishes under 5s and leaves pending-decisions.md byte-identical
ok - a half-written or malformed reply region waits until the markers close it
ok - detection follows the append-only markers, not any heading
ok - active captain holds are accepted on any task kind while other holds stay silent
ok - answer reader returns the latest complete open ruling without changing captain input
ok - reply ingestion serializes with active ruling resolution
ok - file-backed ruling channel declares its accepted untrusted boundary

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - mixed secondmate roles, partial state, and captain readiness project independently
ok - main and secondmate captain actionability use the same blocker readiness

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/fm-teardown.test.sh
all teardown safety cases passed

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)

$ for test_script in tests/*.test.sh; do bash "$test_script"; done
ALL 71 TEST SCRIPTS PASSED
```
