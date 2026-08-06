# Chat ruling round-trip evidence

Verification date: 2026-08-05.

This transcript used a fresh scratch `FM_HOME` under the disposable worktree.
The actual scratch path is abbreviated as `$SCRATCH` below.
The captain-facing quote-back occurred after the record command returned and before the dependent task was created.

```text
$ FM_HOME="$SCRATCH" bin/fm-decision-hold.sh hold chat-review route --title 'Choose chat route' --reason 'captain route pending' --repo sample
chat-review-decision-route

$ FM_HOME="$SCRATCH" bin/fm-decision-hold.sh complete chat-review route
complete: chat-review decision inventory reviewed (route)

$ FM_HOME="$SCRATCH" bin/fm-captain-queue.sh --json | jq -c '[.items[] | select(.id == "chat-review-decision-route")] | length'
1

$ FM_HOME="$SCRATCH" bin/fm-decision-hold.sh record-ruling chat-review-decision-route --origin chat --ruling-file "$SCRATCH/data/decisions/chat-review-decision-route.md"
recorded: chat-review-decision-route (origin: chat)
quote back to captain before dependent work proceeds:
Use the east route for this rollout.
Keep the west route documented as the fallback.

FIRSTMATE -> CAPTAIN, before dependent creation:
Use the east route for this rollout.
Keep the west route documented as the fallback.

$ (cd "$SCRATCH" && tasks-axi add chat-implementation 'Apply selected chat route' --kind ship --repo sample --body 'Decision record: data/decisions/chat-review-decision-route.md' --blocked-by chat-review-decision-route)

$ FM_HOME="$SCRATCH" bin/fm-decision-hold.sh resolve chat-review route --decision-file "$SCRATCH/data/decisions/chat-review-decision-route.md" --routed-to chat-implementation
resolved: chat-review-decision-route -> chat-implementation

$ (cd "$SCRATCH" && tasks-axi show chat-implementation --full) | sed -n 's/^  blocked: //p'
no

$ FM_HOME="$SCRATCH" bin/fm-captain-queue.sh --json | jq -c '[.items[] | select(.id == "chat-review-decision-route")] | length'
0

$ tr '\t' '|' < "$SCRATCH/state/captain-ruling-log.tsv" | paste -sd';' -
REPLY|v2|chat-review-decision-route|f537397cbde0fdf944bb35c421711fd805d085d2d68af0e1470ee528e7a5375e|-|chat;COMMIT|v2|chat-review-decision-route|f537397cbde0fdf944bb35c421711fd805d085d2d68af0e1470ee528e7a5375e|670974a1f9f094acec33dd2850f9fd3444d62567e8130b96fb0305cf25a59408|chat
```

The captain supplied ordinary multiline prose in chat and never edited a file or handled the internal decision identity.
The origin stayed `chat` across REPLY and COMMIT, the dependent became unblocked, and the open-decision query fell from one matching item to zero.
