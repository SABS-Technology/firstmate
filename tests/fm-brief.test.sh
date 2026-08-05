#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in any of the three DOD heredoc bodies
# (no-mistakes/direct-PR/local-only) breaks `bash -n` on the whole file.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  # The owner states its own mode-conditional mechanics; pointer docs must never
  # carry substance this help omits.
  assert_contains "$help" "reconciliation and its durable known-open surface are mode-conditional" \
    "fm-brief.sh --help omits the mode-conditional claim-proof mechanics its pointer docs describe"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

test_stage_protocol_is_separate_from_status() {
  local home ship scout charter
  home="$TMP_ROOT/stage-protocol-home"
  mkdir -p "$home/data"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" stage-ship some-proj >/dev/null 2>&1
  ship="$home/data/stage-ship/brief.md"
  assert_grep "Work stage is a separate axis from those supervision states." "$ship" \
    "ship brief collapsed work stage into supervision state"
  assert_grep "fm-stage.sh' emit 'stage-ship' {stage}" "$ship" \
    "ship brief did not embed the stage transition command"
  assert_grep "moves between \`implementation\` and \`validation\`" "$ship" \
    "ship brief did not name its worker-owned transitions"
  assert_grep "States: working, needs-decision, blocked, paused, done, failed." "$ship" \
    "ship brief changed the supervision vocabulary"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" stage-scout some-proj --scout >/dev/null 2>&1
  scout="$home/data/stage-scout/brief.md"
  assert_grep "Spawn recorded the initial" "$scout" \
    "scout brief omitted its initial investigation stage"
  assert_grep "fm-stage.sh' emit 'stage-scout' {stage}" "$scout" \
    "scout brief did not embed the stage transition command"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops \
    "$ROOT/bin/fm-brief.sh" stage-charter --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/stage-charter/brief.md"
  assert_no_grep "fm-stage.sh" "$charter" \
    "persistent secondmate charter was incorrectly modeled as task work"
  pass "fm-brief: work-stage emission stays separate from the supervision status protocol"
}

test_ship_claim_proof_discipline() {
  local home id id_proj proj brief
  home="$TMP_ROOT/claim-proof-home"
  write_registry "$home"

  for id_proj in "claim-proof-nm:no-registry-proj" "claim-proof-direct:direct-proj" "claim-proof-local:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_grep "# Claim-proof discipline" "$brief" \
      "$id: ship brief is missing the claim-proof discipline"
    assert_grep "name and execute the smallest edits that make the claim false" "$brief" \
      "$id: ship brief lost the falsifying-mutation requirement"
    assert_grep "While implementing, close any falsifying edit the check leaves green." "$brief" \
      "$id: ship brief lost the close-while-implementing escape rule"
    assert_grep "as known-open before \`done\` - never pane-only output." "$brief" \
      "$id: ship brief lost the durable known-open reporting surface"
    assert_grep "cannot be closed within the requested instance" "$brief" \
      "$id: an escape impossible to close in scope has no stated disposition"
    assert_grep "same defect class beyond the requested instance" "$brief" \
      "$id: ship brief lost class-generalization escalation"
    assert_grep "or expand the round; firstmate decides whether it blocks or becomes separately tracked work" "$brief" \
      "$id: class generalization could be read as authorizing scope growth"
    assert_grep "authorizes no follow-up fixing or scope growth" "$brief" \
      "$id: ship brief lost its scope-growth reconciliation"
  done

  # Gate-response rules 3 and 5 exist only in the no-mistakes contract, so only
  # that brief may cite them by number; the other modes carry mode-neutral
  # wording, since their own `# Rules` items 3 and 5 say something else entirely.
  brief="$home/data/claim-proof-nm/brief.md"
  assert_grep "Once a no-mistakes run is active, or if one cannot be closed within the requested instance, stop closing escapes and record it in the PR body" "$brief" \
    "no-mistakes brief lost the gate-round timing rule for escapes"
  assert_grep "Both preserve the validation gate-response contract below" "$brief" \
    "no-mistakes brief lost its self-contained pointer to the gate-response contract"
  assert_grep "scope growth into an unrelated defect class or unrelated surface (rule 5)." "$brief" \
    "no-mistakes brief lost its explicit gate-response rule reconciliation"
  # Only this mode runs against a review gate, so only its claim-proof item 2 may
  # speak of listed findings. The brief must never both require (rule 5) and
  # forbid (claim-proof item 2) closing the defect class of a listed finding.
  assert_grep "same defect class beyond the requested instance, and no listed review finding covers that class, name the generalization and escalate it to firstmate" "$brief" \
    "no-mistakes claim-proof escalation still swallows the defect class of a listed finding"
  assert_grep "Do not fix that unlisted generalization or expand the round" "$brief" \
    "no-mistakes brief forbids fixing a listed finding's own class, not just an unlisted one"
  assert_grep "The defect class a listed finding belongs to is never such a generalization" "$brief" \
    "no-mistakes brief lets claim-proof escalation override rule 5's class-closure requirement"
  assert_grep "escalating that class instead of closing it there is the instance-only closure rule 5 forbids" "$brief" \
    "no-mistakes brief does not name instance-only closure as the failure escalation would cause"
  assert_grep "A defect class that a listed finding does belong to is not this case: it stays in the round and you close it there" "$brief" \
    "claim-proof item 2 does not keep a listed finding's class in-round"
  assert_no_grep "scope growth (rules 3 and 5)." "$brief" \
    "no-mistakes brief still cites rule 5 as blanket authority against closing a listed finding's class"
  # The claim-proof section cites rule 5, so it must carry rule 5's own two
  # qualifiers: the rules-2/3 fix-eligible boundary and the escalation that a
  # purpose-defeating deferral requires. Otherwise it demands in-round closure
  # rule 5 defers, and forbids the escalation rule 5 mandates.
  assert_grep "within the fix-eligible boundary rules 2 and 3 set" "$brief" \
    "claim-proof note demands class closure past the boundary rules 2 and 3 set"
  assert_grep "a same-class instance rules 2 or 3 defer remains a follow-up and the class still counts as completely closed" "$brief" \
    "claim-proof note reads a rules-2-or-3 deferral as the incomplete closure rule 5 forbids"
  assert_grep "a deferral rule 5 calls purpose-defeating goes to firstmate rather than into a silent follow-up" "$brief" \
    "claim-proof note forbids the escalation rule 5 requires for a purpose-defeating deferral"
  # Item 2 renders right after the brief's own `# Rules`, whose items 2, 3, and 5
  # say something else entirely, and before the note that names the contract. Its
  # citations must carry the "gate-response" qualifier or they resolve to the
  # wrong list at the point of reading.
  assert_grep "as far as gate-response rules 2 and 3 make its instances fix-eligible" "$brief" \
    "claim-proof item 2 keeps a listed finding's class in-round past the fix-eligible boundary, or cites a rule list the reader resolves to the brief's own Rules"
  assert_grep "one whose deferral would defeat the purpose of the change goes to firstmate as gate-response rule 5 requires" "$brief" \
    "claim-proof item 2 leaves a purpose-defeating deferral no route to firstmate, or routes it via the brief's own rule 5 instead"

  assert_grep "record it in the PR body as known-open" "$home/data/claim-proof-direct/brief.md" \
    "direct-PR brief must name the PR body as the durable known-open surface"
  assert_grep "record it in your branch commit message as known-open" "$home/data/claim-proof-local/brief.md" \
    "local-only brief must name a surface it actually produces, not a PR body"
  for id in claim-proof-direct claim-proof-local; do
    brief="$home/data/$id/brief.md"
    assert_grep "Neither rule widens the task" "$brief" \
      "$id: brief lost the mode-neutral scope reconciliation"
    assert_grep "If one surfaces too late to close in scope, or cannot be closed" "$brief" \
      "$id: the late-escape trigger lost its completion and reads as a dangling clause"
    # These modes have no review gate, no findings list, and no rounds, so their
    # claim-proof item 2 keeps the flat escalate-do-not-fix boundary.
    assert_grep "same defect class beyond the requested instance, name the generalization and escalate it to firstmate" "$brief" \
      "$id: brief lost the flat class-generalization escalation for a mode with no review gate"
    assert_grep "Do not fix that generalization or expand the round" "$brief" \
      "$id: brief narrowed its do-not-fix boundary to a subset of generalizations"
    assert_no_grep "listed review finding" "$brief" \
      "$id: brief qualifies escalation on a findings list this mode never produces"
    assert_no_grep "it stays in the round and you close it there" "$brief" \
      "$id: brief tells a crewmate with no review round to close a defect class in-round"
    assert_no_grep "fix-eligible" "$brief" \
      "$id: brief bounds its scope by a severity rubric this mode never receives"
    assert_no_grep "purpose-defeating" "$brief" \
      "$id: brief leaked the gate-only purpose-defeating deferral escalation"
    assert_no_grep "rules 3 and 5" "$brief" \
      "$id: brief cites gate-response rules its scaffold never defines"
    assert_no_grep "gate-response" "$brief" \
      "$id: brief references the no-mistakes-only gate-response contract"
    assert_no_grep "Once a no-mistakes run is active" "$brief" \
      "$id: brief leaked no-mistakes gate-round timing into a non-pipeline mode"
  done
  pass "fm-brief.sh: every ship mode carries bounded claim-proof discipline"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'The installed no-mistakes SKILL and the live `axi` help are authoritative and version-matched for all gate mechanics.' "$brief" \
    "no-mistakes DOD lost its installed-guidance ownership reference"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

test_no_mistakes_gate_response_contract_is_ship_only() {
  local home ship scout direct local_brief charter heading
  home="$TMP_ROOT/gate-response-home"
  write_registry "$home"
  heading="# Validation gate-response contract"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" gate-response-ship some-proj >/dev/null 2>&1
  ship="$home/data/gate-response-ship/brief.md"
  assert_grep "$heading" "$ship" \
    "no-mistakes ship brief is missing the validation gate-response contract"
  assert_grep 'all findings you will fix in that round together, grouped by root cause and dependency-ordered' "$ship" \
    "gate-response contract lost the all-findings-in-one-response rule"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_no_grep '`--findings`' "$ship" \
    "gate-response contract duplicated version-sensitive finding-selection syntax"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_no_grep 'skipping records `user_chose_to_ignore`' "$ship" \
    "gate-response contract duplicated skip-persistence mechanics"
  assert_no_grep 'complete re-review of the diff' "$ship" \
    "gate-response contract duplicated review-loop behavior"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'Fix only `error` severity in this branch. Skip `warning` and `info` as follow-ups.' "$ship" \
    "gate-response contract lost the severity rubric"
  assert_grep 'Documentation wording, justification prose, comment text, and evidence or validation hardening are always follow-ups' "$ship" \
    "gate-response contract lost the follow-up-class skip rule"
  assert_grep 'After three fix rounds in one review step, STOP before opening a fourth.' "$ship" \
    "gate-response contract lost the three-fix-round checkpoint"
  assert_grep 'This is a checkpoint, not the final limit: firstmate owns whether the run continues' "$ship" \
    "gate-response contract lost the firstmate-owned continuation checkpoint"
  assert_no_grep 'separate cap of 4' "$ship" \
    "gate-response contract leaked the captain-private firstmate cap"
  assert_grep 'Close the full defect class each listed finding belongs to; closing only the listed instances is an incomplete fix, not a bounded one.' "$ship" \
    "gate-response contract lets a fixer stop at listed instances instead of closing their defect class"
  assert_grep 'name the class you believe it belongs to in your gate response and state the class you are closing' "$ship" \
    "gate-response contract does not make the fixer declare the broader class it is closing"
  assert_grep 'Do not expand the round into an unrelated defect class or unrelated surface' "$ship" \
    "gate-response contract lost the boundary against unrelated scope growth"
  # Rule 5 must not order a fixer past the fix-eligible boundary rules 2 and 3 set,
  # and must not let a deferral that breaks the change be filed silently.
  assert_grep 'Rules 2 and 3 bound which of them are fix-eligible and take precedence over this rule' "$ship" \
    "class closure can order a fixer past the severity and follow-up-class boundaries rules 2 and 3 set"
  assert_grep 'closing the class within that boundary is a complete fix, not an instance-only one' "$ship" \
    "a rules-2-and-3 deferral still reads as the incomplete instance-only closure rule 5 forbids"
  assert_grep 'name it in your gate response as a purpose-defeating deferral and escalate it to firstmate instead of silently filing a follow-up' "$ship" \
    "a deferral that defeats the purpose of the change can be filed as a silent follow-up"
  assert_grep 'Severity grades quality, not whether the thing under construction works.' "$ship" \
    "gate-response contract lost why a low-severity same-class instance can still defeat the change"
  assert_grep 'A reachable PHI exposure, auth bypass, or credential leak blocks regardless of severity, including when pre-existing.' "$ship" \
    "gate-response contract weakened the security floor"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" gate-response-scout some-proj --scout >/dev/null 2>&1
  scout="$home/data/gate-response-scout/brief.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" gate-response-direct direct-proj >/dev/null 2>&1
  direct="$home/data/gate-response-direct/brief.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" gate-response-local local-proj >/dev/null 2>&1
  local_brief="$home/data/gate-response-local/brief.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops \
    "$ROOT/bin/fm-brief.sh" gate-response-charter --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/gate-response-charter/brief.md"

  for brief in "$scout" "$direct" "$local_brief" "$charter"; do
    assert_no_grep "$heading" "$brief" \
      "validation gate-response contract leaked into a non-no-mistakes scaffold"
  done
  pass "fm-brief.sh: validation gate-response contract is complete and no-mistakes-ship-only"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, or work ready for review' "$brief" \
    "secondmate charter lost decisions, blockers, failures, or ready outcomes"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# The pre-flight harvest front-loads human-input decisions to dispatch time. Both
# task scaffolds must carry the section, and an unfilled one must render the default
# no-decisions line rather than leaking a placeholder into a dispatched brief.
test_preflight_section_renders_in_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/preflight-home"
  mkdir -p "$home/data"

  for kind in ship scout; do
    id="brief-preflight-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$kind: brief was not scaffolded"
    assert_grep "## Pre-flight decisions" "$brief" \
      "$kind brief is missing the pre-flight decisions section"
    assert_grep "No pre-flight decisions are recorded for this task." "$brief" \
      "$kind brief did not render the default no-decisions line"
    assert_grep "Any decision recorded above is already answered" "$brief" \
      "$kind brief lost the standing follow-the-pre-answers instruction"
    assert_grep "raise it as a single batched \`needs-decision:\` as early as you can" "$brief" \
      "$kind brief lost the raise-uncovered-decisions-early instruction"
    assert_grep "ideally before you build anything on top of it" "$brief" \
      "$kind brief lost the raise-before-building bar"
  done
  pass "fm-brief.sh: ship and scout briefs carry the pre-flight decisions section"
}

# When firstmate harvested decisions, its text replaces the default line entirely,
# and the standing crew instruction still stands.
test_preflight_decisions_are_firstmate_fillable() {
  local home id brief
  home="$TMP_ROOT/preflight-filled-home"
  mkdir -p "$home/data"
  id="brief-preflight-filled"
  FM_HOME="$home" FM_PREFLIGHT_DECISIONS='- Storage backend: captain chose SQLite over Postgres.' \
    "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "Storage backend: captain chose SQLite over Postgres." "$brief" \
    "filled brief did not render the harvested pre-flight decisions"
  assert_no_grep "No pre-flight decisions are recorded for this task." "$brief" \
    "filled brief still rendered the default no-decisions line"
  assert_grep "Any decision recorded above is already answered" "$brief" \
    "filled brief lost the standing follow-the-pre-answers instruction"
  pass "fm-brief.sh: harvested pre-flight decisions replace the default line"
}

# A charter is a standing scope, not a task, so it has no anticipated decisions.
test_preflight_section_absent_from_secondmate_charter() {
  local home brief
  home="$TMP_ROOT/preflight-charter-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_SECONDMATE_CHARTER='ops domain' \
    "$ROOT/bin/fm-brief.sh" preflight-mate --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/preflight-mate/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_no_grep "## Pre-flight decisions" "$brief" \
    "secondmate charter must not carry a task-scoped pre-flight section"
  pass "fm-brief.sh: secondmate charter carries no pre-flight section"
}

# Escalated decisions must arrive answerable in one pass: options, a recommendation,
# and a blast radius. It is a framing convention, never a gate on reporting. The framing
# lives where firstmate reads it on wake, never in the status append: supervision reads
# the LAST status line, so a multi-line append would bury the needs-decision verb behind
# a verb-less continuation line and degrade captain-relevance and stale triage.
test_needs_decision_carries_blast_radius_framing() {
  local home id brief
  home="$TMP_ROOT/blast-radius-home"
  mkdir -p "$home/data"

  for kind in ship scout; do
    id="brief-blast-radius-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$kind: brief was not scaffolded"
    assert_grep "the options and their tradeoffs, your recommendation, and a one-line blast radius" "$brief" \
      "$kind brief lost the options-and-recommendation decision framing"
    assert_grep "what breaks if the call is wrong, and what would catch it if it does" "$brief" \
      "$kind brief lost the blast-radius decision framing"
    assert_grep "Keep that append to a single short line" "$brief" \
      "$kind brief let decision framing loosen rule 4's one-line status contract"
    assert_grep "which firstmate reads on wake" "$brief" \
      "$kind brief did not send the full decision framing where firstmate reads it"
    assert_grep "must never delay reporting it" "$brief" \
      "$kind brief let decision framing become a gate on reporting"
  done
  pass "fm-brief.sh: needs-decision framing carries options, recommendation, and blast radius"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

test_script_parses
test_help_includes_entire_header
test_preflight_section_renders_in_ship_and_scout
test_preflight_decisions_are_firstmate_fillable
test_preflight_section_absent_from_secondmate_charter
test_needs_decision_carries_blast_radius_framing
test_ship_modes_generate_clean_briefs
test_stage_protocol_is_separate_from_status
test_ship_claim_proof_discipline
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_no_mistakes_gate_response_contract_is_ship_only
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_scout_and_secondmate_scaffold
