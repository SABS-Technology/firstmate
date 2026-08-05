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

The `resolve` subcommand handles dedicated captain-kind holds and requires a decision file plus at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It enumerates the active home's blocked work through `tasks-axi list --blocked` and refuses while any task it finds still carries a `blocked-by` edge to the hold without being named by `--routed-to`, so the caller's list can no longer under-report dependent work.
It requires the canonical regular `data/decisions/<hold-id>.md` record and verifies that every routed task's durable body or brief points to that exact path before any mutation.
It requires ownership of the home session lock because direct concurrent backlog mutation is unsupported.
It enumerates blocked dependents again before the first write and refuses if that inventory changed.
Reply ingestion and resolution serialize program processes through one scoped ruling-resolution lock, but the captain-owned editor deliberately does not participate in that lock.
The detector ingests complete `data/captain-replies.md` observations as ordered REPLY digests in `state/captain-ruling-log.tsv`.
The resolver appends the identity's first matching COMMIT before its first backlog mutation, which is the snapshot commit point selected by the captain on 2026-08-05.
That COMMIT remains authoritative for idempotent roll-forward after interruption even if a later editor observation appends another REPLY.
A later REPLY is surfaced as `captain-ruling-revision <hold-id>` and becomes a new decision requiring explicit revocation of the committed ruling rather than an overwrite of it.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.

## Resolver integrity and snapshot criterion (SC-1)

A resolver log is accepted only when its storage properties and raw record grammar are positively validated.
Content-level agreement between a REPLY and a COMMIT is deliberately not revalidated by the detector.
The program-owned writer already requires the last record for the hold to be a matching REPLY before it appends a COMMIT, while a non-program writer falls within the local ruling-channel trust gap accepted by the captain's 2026-08-04 ruling.

The detector separately compares the canonical captain queue's open state with the resolver log's settled state.
When an open replyable hold has a COMMIT last, it reads both sources again after a bounded delay so the normal COMMIT-before-close roll-forward window can finish.
If the later queue and log observations still disagree, the detector emits one deduplicated privacy-safe `captain-ruling-error queue-log-disagreement <hold-id>` notification through the existing durable watcher acknowledgment machinery.
It never includes answer text and never resolves the disagreement silently in favor of either source.

The reply-edit window uses snapshot semantics under the captain's 2026-08-05 ruling.
The ruling acted on is the complete reply the program observed when it appended the first COMMIT, and an editor change after that observation cannot retroactively replace it.
The detector surfaces a later complete answer as a distinct revision wake even after the original hold closes.
The lifecycle agent then creates a new captain-held decision for explicit revocation or retention; it never rewrites the committed decision record or reuses the resolved identity.

The `resolve-item` subcommand handles a captain hold carried by ordinary work.
It requires the canonical `data/decisions/<hold-id>.md` record, commits its matching reply under the same ruling-resolution lock, records the decision digest and pointer on the existing work item, and clears only the captain hold.
It accepts no routed identities and contains no task-completion path, so resolving the decision cannot complete the underlying work or release dependencies that represent completion of that work.
Such a retry rolls forward only while the same COMMIT remains last in the ruling log.

## Accepted local ruling threat model

The file-backed reply channel is not trusted or authenticated.
This is an accepted weakness for a single-user machine where every agent already runs as the captain's UID and can modify `bin/` directly.
A compromised local process can fabricate a ruling, and no signing key, shared secret, or separate authenticated channel is added because that would defend one door in an already-open house.
The detection boundary is human detection: a fabricated record in `data/decisions/` does not match any ruling the captain remembers making.
Captain rulings normally arrive in chat or Linear.
The queue file is only a fallback and does not become the primary ruling path.

`bin/fm-captain-ruling-check.sh` emits only privacy-safe hold identities from its watcher path.
It reads complete `<hold-id>: <answer>` lines from captain-owned `data/captain-replies.md`, atomically ingests new answer digests into the program log, and never writes the editor surface.
Its explicit `--answer <hold-id>` read returns the latest ingested complete answer while the hold is open or while a post-COMMIT revision is pending.
On that wake, the lifecycle skill owns the semantic agent turn: it writes the exact answer to `data/decisions/<hold-id>.md`, then selects `resolve` for a dedicated captain-kind hold or `resolve-item` for a hold carried by ordinary work.
The guarded resolver remains the only decision-resolution path, so a status-only change, missing work item, or missing dependency edge cannot close a dedicated captain decision or complete ordinary work.

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
Queue-versus-log disagreement regression verification date: 2026-08-05.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.
The snapshot regression changes the editor surface immediately after the final ingest observation and before COMMIT, proves the observed answer routes and closes, and then proves the later edit emits a revision wake.
Its staged mutant disables only the revision surface and becomes silent, which proves the wake is load-bearing.
The interruption regression discovers both ruling-log and backlog changes, injects after every observed mutation, and distinguishes the pre-COMMIT REPLY position from COMMIT and every later position.
Before COMMIT, a newly observed answer can replace the prepared record; from COMMIT onward, the committed answer rolls forward and the later edit becomes a new revocation decision.
The legitimate partial-routing retry still finishes from the matching COMMIT, while a retry carrying a different decision identity remains refused.

## Interruption-probe observation boundary

The committed resolver regression observes two files: net changes to `data/backlog.md` around every synchronous `tasks-axi` child call, and net changes to `state/captain-ruling-log.tsv` around the program's append writer.
Its process boundary is the resolver process and those direct child calls; external processes, direct writer bypasses, and mutations to other files are not observed.
Its timing boundary is immediately before and after each call returns; a write-and-revert inside one call leaves no net durable change and is unobservable by construction.
These residual classes are accepted under firstmate's 2026-08-05 ruling rather than covered by a filesystem watcher or write-during-call journal.

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
ok - the last observed answer commits, while a later edit becomes a distinct revocation decision
ok - every observed mutation interruption preserves the committed snapshot and surfaces a later edit
ok - every ordinary-work mutation interruption preserves the snapshot and surfaces a later edit
ok - in-flight captain holds generate, wake, read, record, route, and resolve
ok - ordinary-kind replies resolve only the captain hold and never complete the work item
ok - an exact retry finishes routing a committed decision when no reply changed
ok - a partial-resolve retry carrying a different decision is still refused
ok - captain-ruling wakes load the single lifecycle owner and preserve close ordering

$ bash tests/fm-captain-ruling-check.test.sh
ok - one private single-link global check is registered
ok - new rulings wake once while malformed, unchanged, and resolved ids stay silent
ok - the check finishes under 5s and leaves captain-replies.md byte-identical
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
