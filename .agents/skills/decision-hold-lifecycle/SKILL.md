---
name: decision-hold-lifecycle
description: >-
  Agent-only policy for completing investigations and visual reviews without losing unresolved captain decisions.
  Load before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a decision, on a captain-ruling check wake, and when recording or routing the captain's answer.
user-invocable: false
metadata:
  internal: true
---

# Durable unresolved-decision lifecycle

This skill is the single policy owner for unresolved captain decisions discovered by an investigation or visual review.

## Policy

Every unresolved decision that belongs to the captain and is discovered while producing, reading, presenting, or ending an investigation or visual review must become a structured captain-held work item in the authoritative backlog of the home that owns the originating work before that work or review may be treated as complete.
The agent performs the semantic inventory because scripts must not infer decisions from report prose, visual-review artifacts, terminal output, or chat.
Give each distinct unresolved decision a stable privacy-safe key, register it through `bin/fm-decision-hold.sh hold`, and use the same key on retry so registration is idempotent while different decisions retain different durable identities.
After inventorying the whole report and review surface, run `bin/fm-decision-hold.sh complete` with every unresolved key, or with `--none` only when the reviewed surface contains no unresolved captain decision.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; main-home work creates main-home holds, and secondmate-owned work creates holds in that secondmate home's backlog rather than copying them into the main backlog.
Do not close a hold merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
A dedicated captain-kind hold remains the authoritative Captain's Call item until the captain's answer is durably recorded, dependent work is created in the same backlog and blocked by that hold, and `bin/fm-decision-hold.sh resolve` routes the answer by clearing those dependency edges before closing the hold.
An ordinary work item carrying a captain hold remains the work owner; `resolve-item` records the decision and clears only its hold, and must never complete that work item or release dependencies that represent completion of the work.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create holds.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.
A status change is not ruling ingestion and must never substitute for the decision record, dependent work, dependency edges, or guarded resolution.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that require the captain.
3. For each choice, choose a stable key and use the script's `hold` command with a concise title, reason, and repository.
4. Run the script's `complete` command with the full unresolved-key inventory for that review pass; successful completion atomically regenerates the pending-decisions projection.
5. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
6. After the captain decides, follow the ruling-ingestion turn below.
7. Confirm Bearings no longer shows the closed hold and that routed work remains in structured backlog state.

## Captain-ruling ingestion turn

When a `check:` wake contains `captain-ruling <hold-id>[,<hold-id>...]`, process every named identity in the authoritative `FM_HOME` before returning to routine queue work.
When it contains `captain-ruling-revision <hold-id>[,<hold-id>...]`, the named identity already has a committed ruling and the edited answer is a new decision.
Read the revised answer, inspect the committed decision record and routed work, and register a new stable captain-held decision that asks for explicit revocation or retention of the committed ruling.
Never overwrite the old decision record, reopen the old identity, or apply the revision before that revocation decision resolves.
When it instead contains `captain-ruling-error queue-log-disagreement <hold-id>[,<hold-id>...]`, treat it as a persistent disagreement between the canonical queue and resolver log, inspect the interrupted resolution, and resume or repair that same lifecycle without interpreting or re-recording the captain's answer from the wake.
When it contains `captain-ruling-error resolver-log-invalid`, it names no identity because the resolver log itself failed validation; every ruling detection and guarded resolution stays blocked until that log is repaired, so treat it as an integrity incident and never reconstruct a ruling or a decision record from it.
`docs/decision-hold-lifecycle.md` owns the SC-1 integrity boundary, including the deliberate exclusion of content-level REPLY-versus-COMMIT validation under the captain's 2026-08-04 ruling.
The wake deliberately contains identities rather than answer text, so read each exact current answer with `bin/fm-captain-ruling-check.sh --answer <hold-id>`.
Read `tasks-axi show <hold-id> --full` and use its kind to select the matching guarded resolution path.
For a captain-kind hold, take the originating work id and decision key from its body rather than reconstructing them by splitting the hold identity.
Interpret the ruling and author at least one concrete dependent work item for a captain-kind hold, including when applying the answer means recording a deliberate no-go or scope closure.
Create that work with normal `tasks-axi add` fields and `--blocked-by <hold-id>`, or add that edge to an existing routed item with `tasks-axi block`.
Keep every dependent item in the same authoritative home as the hold and point its durable body or brief at the decision record rather than copying the ruling into multiple owners.
For an ordinary-kind item, keep the existing work item as the implementation owner and do not invent a dependent, clear its work dependencies, or complete it as part of ruling resolution.
Write the captain's exact answer to the private durable record `data/decisions/<hold-id>.md` in that home.
Record the captain's reply verbatim, because the first `resolve` commits only when the observed REPLY record matches it.
For a captain-kind hold, call `bin/fm-decision-hold.sh resolve <origin-id> <decision-key> --decision-file data/decisions/<hold-id>.md --routed-to <task-id>` with every routed identity.
`resolve` also refuses while any task it discovers is still blocked by a captain-kind hold and absent from `--routed-to`, so route each such task rather than working around the refusal.
For an ordinary-kind item, call `bin/fm-decision-hold.sh resolve-item <hold-id> --decision-file data/decisions/<hold-id>.md`; that command clears only the captain hold and leaves the work active.
Only after `resolve` succeeds may captain-kind dependent work proceed.
Only after `resolve-item` succeeds may the ordinary work item proceed.
Regenerate the pending-decisions projection after the matching command succeeds.
Confirm the decision left the canonical captain queue and the routed or ordinary work remains in the structured backlog.
If any creation, dependency, decision-record, or resolve step fails, leave the hold open, preserve the already-authored state, and retry the same identities rather than directly unholding or completing the hold.
Retry with the already prepared decision record after interruption because the first matching COMMIT remains authoritative even when a later edit is waiting as a new decision.
A post-COMMIT edit never changes that retry identity and requires explicit revocation through a new decision before any replacement ruling can be applied.

`bin/fm-decision-hold.sh --help` owns command syntax, identity construction, completion attestation, retry behavior, and close ordering.
`docs/decision-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
