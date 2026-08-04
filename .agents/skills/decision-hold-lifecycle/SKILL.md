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
The hold remains the authoritative Captain's Call item until the captain's answer is durably recorded, dependent work is created in the same backlog and blocked by that hold, and `bin/fm-decision-hold.sh resolve` routes the answer by clearing those dependency edges before closing the hold.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create holds.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.
A status change is not ruling ingestion and must never substitute for the decision record, dependent work, dependency edges, or guarded resolution.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that require the captain.
3. For each choice, choose a stable key and use the script's `hold` command with a concise title, reason, and repository.
4. Run the script's `complete` command with the full unresolved-key inventory for that review pass.
5. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
6. After the captain decides, follow the ruling-ingestion turn below.
7. Confirm Bearings no longer shows the closed hold and that routed work remains in structured backlog state.

## Captain-ruling ingestion turn

When a `check:` wake contains `captain-ruling <hold-id>[,<hold-id>...]`, process every named identity in the authoritative `FM_HOME` before returning to routine queue work.
The wake deliberately contains identities rather than answer text, so read each exact current answer with `bin/fm-captain-ruling-check.sh --answer <hold-id>`.
Read `tasks-axi show <hold-id> --full` and take the originating work id and decision key from its body rather than reconstructing them by splitting the hold identity.
Interpret the ruling and author at least one concrete dependent work item that applies it, including when applying the answer means recording a deliberate no-go or scope closure.
Create new work with normal `tasks-axi add` fields and `--blocked-by <hold-id>`, or add that edge to an existing routed item with `tasks-axi block`.
Keep every dependent item in the same authoritative home as the hold and point its durable body or brief at the decision record rather than copying the ruling into multiple owners.
Write the captain's exact answer to the private durable record `data/decisions/<hold-id>.md` in that home.
Record the captain's reply verbatim, because `resolve` re-reads the current reply and refuses when the record no longer matches it.
Call `bin/fm-decision-hold.sh resolve <origin-id> <decision-key> --decision-file data/decisions/<hold-id>.md --routed-to <task-id>` with every routed identity.
`resolve` also refuses while any task it discovers is still blocked by the hold and absent from `--routed-to`, so route each such task rather than working around the refusal.
Only after `resolve` succeeds may the dependent work be treated as unblocked, dispatched or handed off, and the pending-decisions projection regenerated.
Confirm the hold left the canonical captain queue and the routed work remains in the structured backlog.
If any creation, dependency, decision-record, or resolve step fails, leave the hold open, preserve the already-authored state, and retry the same identities rather than directly unholding or completing the hold.
Retry with the decision record already prepared for that hold rather than re-reading `--answer` into a fresh record, because a retry carrying different decision text is refused even after the captain revised the reply.

`bin/fm-decision-hold.sh --help` owns command syntax, identity construction, completion attestation, retry behavior, and close ordering.
`docs/decision-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
