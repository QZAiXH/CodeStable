#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/cs-loop/tools/codex-loop.sh"
TMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  if [ "$actual" != "$expected" ]; then
    fail "$message: expected '$expected', got '$actual'"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    fail "$message: missing '$needle' in '$haystack'"
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  local message="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    fail "$message: missing '$needle' in $file"
  fi
}

assert_file_count() {
  local pattern="$1"
  local expected="$2"
  local message="$3"
  local actual
  actual="$(find ${pattern%/*} -maxdepth 1 -name "${pattern##*/}" | wc -l | tr -d ' ')"
  assert_eq "$actual" "$expected" "$message"
}

run_capture() {
  set +e
  LAST_OUTPUT="$("$@" 2>&1)"
  LAST_STATUS=$?
  set -e
}

make_codex_stub() {
  local bin_dir="$TMP_ROOT/bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

echo "$*" >> "${CODEX_STUB_LOG:?}"

if [ "${1:-}" != "exec" ]; then
  echo "stub only supports codex exec" >&2
  exit 99
fi

out=""
sandbox=""
cd_arg=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --cd)
      cd_arg="${args[$((i + 1))]}"
      ;;
    -o|--output-last-message)
      out="${args[$((i + 1))]}"
      ;;
    --sandbox)
      sandbox="${args[$((i + 1))]}"
      ;;
  esac
done

if [ -z "$out" ]; then
  echo "missing -o output path" >&2
  exit 98
fi

mkdir -p "$(dirname "$out")"
prompt="$(cat)"
if [ -n "${CODEX_STUB_PROMPT_DIR:-}" ]; then
  mkdir -p "$CODEX_STUB_PROMPT_DIR"
  role="worker"
  if grep -Fq "You are approval-codex" <<<"$prompt"; then
    role="approval"
  elif grep -Fq "You are decision-codex" <<<"$prompt"; then
    role="decision"
  fi
  printf '%s\n' "$prompt" > "$CODEX_STUB_PROMPT_DIR/$role-$(date +%s%N)-$$.txt"
fi

if grep -Fq "You are approval-codex" <<<"$prompt"; then
  parsed_status="$(awk 'prev { print; exit } /^Parsed decision status:$/ { prev = 1 }' <<<"$prompt")"
  decision_path="$(awk 'prev { print; exit } /^Decision output to review:$/ { prev = 1 }' <<<"$prompt")"
  decision_file="$decision_path"
  if [ -n "$cd_arg" ] && [ -n "$decision_path" ] && [ "${decision_path#/}" = "$decision_path" ]; then
    decision_file="$cd_arg/$decision_path"
  fi
  decision_text=""
  if [ -f "$decision_file" ]; then
    decision_text="$(cat "$decision_file")"
  fi
  case "${CODEX_STUB_APPROVAL:-auto}" in
    auto)
      if [ "$parsed_status" = "UNPARSEABLE" ]; then
        cat > "$out" <<'OUT'
LOOP_APPROVAL: REVISE

Decision output is not parseable. Ask decision-codex to rewrite it before any worker runs.
OUT
      elif [ "$parsed_status" = "CONTINUE" ] && ! grep -Eiq '(^|[[:space:]])Active Workflow|Active workflow|active_workflow' <<<"$decision_text"; then
        cat > "$out" <<'OUT'
LOOP_APPROVAL: REVISE

Decision output does not name an active workflow.
OUT
      elif [ "$parsed_status" = "CONTINUE" ] && ! grep -Fq ".codestable/" <<<"$decision_text"; then
        cat > "$out" <<'OUT'
LOOP_APPROVAL: REVISE

Decision output does not include bounded CodeStable artifact paths.
OUT
      elif [ "$parsed_status" = "DONE" ] && ! grep -Eiq 'verification|verified|passed|evidence' <<<"$decision_text"; then
        cat > "$out" <<'OUT'
LOOP_APPROVAL: REVISE

DONE lacks verification evidence.
OUT
      elif [ "$parsed_status" = "ESCALATE" ]; then
        cat > "$out" <<'OUT'
LOOP_APPROVAL: APPROVED

# Human Escalation

## Context Brief

- The loop needs a human product decision.
- decision-codex correctly escalated instead of sending work to worker-codex.

## Question

Choose the product behavior.

## Why Approval Cannot Decide

- The behavior is not defined in CodeStable artifacts.

## Options

### Option A

- Outcome: Keep current behavior.
- Risk: May not satisfy the new request.
- Evidence: Existing docs do not define the change.

### Option B

- Outcome: Change behavior.
- Risk: User-visible semantics change.
- Evidence: Requires human approval.

## Recommendation

Choose Option A unless the product requirement has changed.

## If Not Decided

The loop remains blocked before implementation.
OUT
      else
        cat > "$out" <<'OUT'
LOOP_APPROVAL: APPROVED

Approval rationale:
- proposal is bounded and low-risk
OUT
      fi
      ;;
    approved)
      cat > "$out" <<'OUT'
LOOP_APPROVAL: APPROVED

Approval rationale:
- proposal is bounded and low-risk
OUT
      ;;
    revise)
      cat > "$out" <<'OUT'
LOOP_APPROVAL: REVISE

Approval rationale:
- worker brief is underspecified but decision-codex can fix it.
OUT
      ;;
    escalate)
      cat > "$out" <<'OUT'
LOOP_APPROVAL: ESCALATE

# Human Escalation

## Context Brief

- decision-codex proposed a change that needs human judgment.
- approval-codex cannot safely approve it from existing artifacts.

## Question

Should the loop change the product behavior?

## Why Approval Cannot Decide

- Existing docs do not define the requested behavior.

## Options

### Option A

- Outcome: Stop and update requirements.
- Risk: Slower progress.
- Evidence: Missing product semantics.

### Option B

- Outcome: Let worker implement the proposal.
- Risk: AI invents behavior.
- Evidence: No approved requirement.

## Recommendation

Choose Option A.

## If Not Decided

Worker-codex will not run.
OUT
      ;;
    bad)
      cat > "$out" <<'OUT'
The approval output missed the required first line.
OUT
      ;;
    preamble-approved)
      cat > "$out" <<'OUT'
Approval rationale before required status.
LOOP_APPROVAL: APPROVED
OUT
      ;;
    *)
      echo "unknown CODEX_STUB_APPROVAL" >&2
      exit 96
      ;;
  esac
elif [ "$sandbox" = "read-only" ]; then
  case "${CODEX_STUB_DECISION:-continue}" in
    done)
      cat > "$out" <<'OUT'
LOOP_DECISION: DONE

Active workflow: cs-feat

Done evidence:
- verification already passed
OUT
      ;;
    done-chosen-workflow)
      cat > "$out" <<'OUT'
LOOP_DECISION: DONE

Active workflow chosen: `cs-feat`, acceptance stage `cs-feat-accept`.

Done evidence:
- verification already passed
OUT
      ;;
    done-no-evidence)
      cat > "$out" <<'OUT'
LOOP_DECISION: DONE

Active workflow: cs-feat

Done.
OUT
      ;;
    escalate)
      cat > "$out" <<'OUT'
LOOP_DECISION: ESCALATE

# Human Escalation

## Question

Choose the product behavior.
OUT
      ;;
    bad)
      cat > "$out" <<'OUT'
The decisioner forgot the required first line.
OUT
      ;;
    lowercase)
      cat > "$out" <<'OUT'
LOOP_DECISION: Continue

Active workflow: cs-feat
OUT
      ;;
    preamble-continue)
      cat > "$out" <<'OUT'
Decision rationale before required status.
LOOP_DECISION: CONTINUE

Active workflow: cs-feat
OUT
      ;;
    multiple-status)
      cat > "$out" <<'OUT'
LOOP_DECISION: CONTINUE
LOOP_DECISION: DONE

Active workflow: cs-feat

# Worker Brief

## Active Workflow

`cs-feat`

## Inputs

- relevant CodeStable artifacts:
  - `.codestable/features/2026-06-14-demo/demo-design.md`

## Allowed Changes

- `src/demo.txt`

## Verification

- `test -f src/demo.txt`
OUT
      ;;
    continue)
      cat > "$out" <<'OUT'
LOOP_DECISION: CONTINUE

Active workflow: cs-feat

# Worker Brief

## Task

Create the minimal feature artifact.

## Active Workflow

`cs-feat`

## Inputs

- loop: `.codestable/loops/2026-06-14-demo/loop.md`
- relevant CodeStable artifacts:
  - `.codestable/features/2026-06-14-demo/demo-design.md`

## Allowed Changes

- `src/demo.txt`

## Verification

- `test -f src/demo.txt`
OUT
      ;;
    continue-no-workflow)
      cat > "$out" <<'OUT'
LOOP_DECISION: CONTINUE

# Worker Brief

## Inputs

- relevant CodeStable artifacts:
  - `.codestable/features/2026-06-14-demo/demo-design.md`

## Allowed Changes

- `src/demo.txt`

## Verification

- `test -f src/demo.txt`
OUT
      ;;
    continue-no-artifact)
      cat > "$out" <<'OUT'
LOOP_DECISION: CONTINUE

Active workflow: cs-feat

# Worker Brief

## Active Workflow

`cs-feat`

## Inputs

- loop: `loop.md`

## Allowed Changes

- `src/demo.txt`

## Verification

- `test -f src/demo.txt`
OUT
      ;;
    continue-list-workflow)
      cat > "$out" <<'OUT'
LOOP_DECISION: CONTINUE

# Worker Brief

## Active Workflow

- Active workflow: `cs-feat`
- Current stage: implementation via `cs-feat-impl`

## Inputs

- loop: `.codestable/loops/2026-06-14-demo/loop.md`
- relevant CodeStable artifacts:
  - `.codestable/features/2026-06-14-demo/demo-design.md`

## Allowed Changes

- `src/demo.txt`

## Verification

- `test -f src/demo.txt`
OUT
      ;;
    *)
      echo "unknown CODEX_STUB_DECISION" >&2
      exit 97
      ;;
  esac
else
  if [ "${CODEX_STUB_WORKER:-ok}" = "fail" ]; then
    cat > "$out" <<'OUT'
changed files:
- none
verification result:
- failed
blockers:
- simulated worker failure
suggested next decision:
- inspect blocker
OUT
    exit 42
  fi
  cat > "$out" <<'OUT'
changed files:
- src/demo.txt
verification result:
- passed
blockers:
- none
suggested next decision:
- check completion
OUT
fi
STUB
  chmod +x "$bin_dir/codex"
  export PATH="$bin_dir:$PATH"
}

make_repo() {
  local repo="$TMP_ROOT/repo-$1"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q
    mkdir -p .codestable/reference
    mkdir -p .codestable/features/2026-06-14-demo
    mkdir -p src
    printf '# attention\n' > .codestable/attention.md
    printf '# overview\n' > .codestable/reference/system-overview.md
    printf '# shared conventions\n' > .codestable/reference/shared-conventions.md
    printf '# design\n' > .codestable/features/2026-06-14-demo/demo-design.md
  )
  echo "$repo"
}

make_loop() {
  local repo="$1"
  local loop_dir="$repo/.codestable/loops/2026-06-14-demo"
  mkdir -p "$loop_dir"
  cat > "$loop_dir/loop.md" <<'LOOP'
---
doc_type: loop
slug: demo
status: active
created: 2026-06-14
---

# Demo

## Objective

Create a minimal demo artifact.

## Stop Condition

- `src/demo.txt` exists.
LOOP
}

test_requires_loop_dir() {
  run_capture "$SCRIPT"
  assert_eq "$LAST_STATUS" "2" "missing --loop-dir exits 2"
  assert_contains "$LAST_OUTPUT" "--loop-dir is required" "missing --loop-dir message"
}

test_requires_codestable() {
  local repo="$TMP_ROOT/no-codestable"
  mkdir -p "$repo"
  (cd "$repo" && git init -q)
  run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/demo"
  assert_eq "$LAST_STATUS" "3" "missing .codestable exits 3"
  assert_contains "$LAST_OUTPUT" "Missing .codestable/" "missing .codestable message"
}

test_requires_complete_codestable_skeleton() {
  local repo="$TMP_ROOT/incomplete-codestable"
  mkdir -p "$repo/.codestable/reference"
  (
    cd "$repo"
    git init -q
    printf '# attention\n' > .codestable/attention.md
    printf '# overview\n' > .codestable/reference/system-overview.md
  )
  run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/demo"
  assert_eq "$LAST_STATUS" "4" "incomplete .codestable exits 4"
  assert_contains "$LAST_OUTPUT" "Missing .codestable/reference/shared-conventions.md" "incomplete .codestable message"
}

test_help_unknown_empty_human_and_missing_codex() {
  run_capture "$SCRIPT" --help
  assert_eq "$LAST_STATUS" "0" "help exits 0"
  assert_contains "$LAST_OUTPUT" "Usage:" "help prints usage"

  run_capture "$SCRIPT" --bad
  assert_eq "$LAST_STATUS" "2" "unknown argument exits 2"
  assert_contains "$LAST_OUTPUT" "Unknown argument: --bad" "unknown argument message"

  local repo
  repo="$(make_repo no-codex)"
  make_loop "$repo"
  run_capture bash -c "cd '$repo' && PATH=/usr/bin:/bin '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "127" "missing codex exits 127"
  assert_contains "$LAST_OUTPUT" "codex command not found" "missing codex message"

  run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo --human-decision ''"
  assert_eq "$LAST_STATUS" "2" "empty human decision exits 2"
  assert_contains "$LAST_OUTPUT" "--human-decision requires a non-empty value" "empty human decision message"
}

test_initializes_missing_loop_dir_and_state_files() {
  local repo
  repo="$(make_repo initialize)"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=done run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-new-loop"
  assert_eq "$LAST_STATUS" "0" "missing loop dir is created"
  local loop="$repo/.codestable/loops/2026-06-14-new-loop"
  [ -d "$loop/runs" ] || fail "runs directory was not created"
  for file in state.yaml decision-log.md approval-log.md worker-brief.md human-escalation.md human-decision.md; do
    [ -f "$loop/$file" ] || fail "missing initialized $file"
  done
  assert_file_contains "$loop/state.yaml" "doc_type: loop-state" "initial state doc type"
  assert_file_contains "$loop/state.yaml" "updated: $(date +%F)" "state updated date"
}

test_human_decision_record_mode() {
  local repo
  repo="$(make_repo human-decision)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo --human-decision 'Choose Option A and update requirements first.'"
  assert_eq "$LAST_STATUS" "0" "human decision record exits 0"
  assert_contains "$LAST_OUTPUT" "Human decision recorded" "human decision record message"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/human-decision.md" "## " "human decision timestamp written"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/human-decision.md" "Choose Option A and update requirements first." "human decision text written"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "status: active" "human decision reactivates loop"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "next_actor: decision-codex" "human decision routes to decision"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'last_human_decision: ".codestable/loops/2026-06-14-demo/human-decision.md#' "human decision records pointer"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "blocked_reason: null" "human decision clears blocked reason"
  local calls
  calls="$(wc -l < "$CODEX_STUB_LOG" | tr -d ' ')"
  assert_eq "$calls" "0" "human decision record should not run codex"
}

test_human_decision_appends_and_escapes_state_pointer() {
  local repo
  repo="$(make_repo human-decision-append)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo --human-decision 'First decision'"
  assert_eq "$LAST_STATUS" "0" "first human decision exits 0"
  run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo --human-decision 'Second \"quoted\" decision with backslash \\\\'"
  assert_eq "$LAST_STATUS" "0" "second human decision exits 0"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/human-decision.md" "First decision" "first human decision preserved"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/human-decision.md" "Second \"quoted\" decision with backslash \\\\" "second human decision appended"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'last_human_decision: ".codestable/loops/2026-06-14-demo/human-decision.md#' "last human decision pointer quoted"
}

test_done_path_skips_worker() {
  local repo
  repo="$(make_repo done)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=done run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "0" "DONE exits 0"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/decision-log.md" "Status: DONE" "DONE logged"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "status: done" "DONE updates state status"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "next_actor: null" "DONE clears next actor"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'last_decision: "DONE"' "DONE records last decision"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'last_approval: "APPROVED"' "DONE records approval"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'active_workflow: "cs-feat"' "DONE records active workflow"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/approval-log.md" "Status: APPROVED" "DONE approval logged"
  local calls
  calls="$(wc -l < "$CODEX_STUB_LOG" | tr -d ' ')"
  assert_eq "$calls" "2" "DONE should run decision and approval only"
}

test_done_path_extracts_chosen_workflow() {
  local repo
  repo="$(make_repo done-chosen-workflow)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=done-chosen-workflow run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "0" "DONE with chosen workflow exits 0"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'active_workflow: "cs-feat"' "DONE extracts chosen active workflow"
}

test_done_without_evidence_requests_revision() {
  local repo
  repo="$(make_repo done-no-evidence)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=done-no-evidence run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "22" "DONE without evidence requests revision"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "status: needs-revision" "DONE without evidence marks revision"
  local calls
  calls="$(wc -l < "$CODEX_STUB_LOG" | tr -d ' ')"
  assert_eq "$calls" "2" "DONE without evidence should not run worker"
}

test_escalate_path_writes_report() {
  local repo
  repo="$(make_repo escalate)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=escalate run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "20" "ESCALATE exits 20"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/human-escalation.md" "LOOP_APPROVAL: APPROVED" "approved escalation copied"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/human-escalation.md" "## Context Brief" "escalation includes context brief"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "status: waiting-human" "ESCALATE updates state status"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "next_actor: human" "ESCALATE routes to human"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'last_approval: "APPROVED"' "ESCALATE records approval"
  local calls
  calls="$(wc -l < "$CODEX_STUB_LOG" | tr -d ' ')"
  assert_eq "$calls" "2" "ESCALATE should run decision and approval only"
}

test_bad_decision_path_requests_revision() {
  local repo
  repo="$(make_repo bad)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=bad run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "22" "unparseable decision requests revision"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/approval-log.md" "Status: REVISE" "bad decision revision logged"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "status: needs-revision" "bad decision marks revision needed"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "next_actor: decision-codex" "bad decision routes back to decision"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'last_decision: "UNPARSEABLE"' "bad decision records unparseable"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'last_approval: "REVISE"' "bad decision records revision approval"
  local calls
  calls="$(wc -l < "$CODEX_STUB_LOG" | tr -d ' ')"
  assert_eq "$calls" "2" "bad decision should not run worker"
}

test_decision_status_must_be_first_line_and_uppercase() {
  local repo
  repo="$(make_repo preamble-decision)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=preamble-continue run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "22" "decision status after preamble requests revision"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'last_decision: "UNPARSEABLE"' "preamble decision is unparseable"

  repo="$(make_repo lowercase-decision)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=lowercase run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "22" "lowercase decision requests revision"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'last_decision: "UNPARSEABLE"' "lowercase decision is unparseable"
}

test_multiple_decision_status_uses_first_line() {
  local repo
  repo="$(make_repo multiple-status)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=multiple-status run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "0" "multiple decision statuses use first line"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'last_decision: "CONTINUE"' "first decision status recorded"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "iteration: 1" "first status drives worker path"
}

test_approval_revise_path_skips_worker() {
  local repo
  repo="$(make_repo revise)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=continue CODEX_STUB_APPROVAL=revise \
    run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "22" "REVISE exits 22"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/approval-log.md" "Status: REVISE" "REVISE logged"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "status: needs-revision" "REVISE updates state"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "next_actor: decision-codex" "REVISE routes back to decision"
  local calls
  calls="$(wc -l < "$CODEX_STUB_LOG" | tr -d ' ')"
  assert_eq "$calls" "2" "REVISE should not run worker"
}

test_approval_escalate_path_skips_worker() {
  local repo
  repo="$(make_repo approval-escalate)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=continue CODEX_STUB_APPROVAL=escalate \
    run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "20" "approval ESCALATE exits 20"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/human-escalation.md" "LOOP_APPROVAL: ESCALATE" "approval escalation copied"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/human-escalation.md" "## Context Brief" "approval escalation includes context"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "status: waiting-human" "approval escalation updates state"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "next_actor: human" "approval escalation routes human"
  local calls
  calls="$(wc -l < "$CODEX_STUB_LOG" | tr -d ' ')"
  assert_eq "$calls" "2" "approval ESCALATE should not run worker"
}

test_bad_approval_path_writes_escalation() {
  local repo
  repo="$(make_repo bad-approval)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=continue CODEX_STUB_APPROVAL=bad \
    run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "23" "unparseable approval exits 23"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/human-escalation.md" "missed the required first line" "bad approval copied to escalation"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "status: blocked" "bad approval marks blocked"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "next_actor: human" "bad approval routes human"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'last_approval: "UNPARSEABLE"' "bad approval records unparseable"
  local calls
  calls="$(wc -l < "$CODEX_STUB_LOG" | tr -d ' ')"
  assert_eq "$calls" "2" "bad approval should not run worker"
}

test_approval_status_must_be_first_line() {
  local repo
  repo="$(make_repo preamble-approval)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=continue CODEX_STUB_APPROVAL=preamble-approved \
    run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "23" "approval status after preamble blocks"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'last_approval: "UNPARSEABLE"' "preamble approval is unparseable"
  local calls
  calls="$(wc -l < "$CODEX_STUB_LOG" | tr -d ' ')"
  assert_eq "$calls" "2" "preamble approval should not run worker"
}

test_continue_path_runs_worker() {
  local repo
  repo="$(make_repo continue)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=continue CS_LOOP_DECISION_MODEL=decision-model CS_LOOP_APPROVAL_MODEL=approval-model CS_LOOP_WORKER_MODEL=worker-model CS_LOOP_WORKER_SANDBOX=workspace-write \
    run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo --objective 'demo objective'"
  assert_eq "$LAST_STATUS" "0" "CONTINUE exits 0"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/worker-brief.md" "## Active Workflow" "worker brief keeps active workflow"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/decision-log.md" "Status: CONTINUE" "CONTINUE logged"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/approval-log.md" "Status: APPROVED" "CONTINUE approval logged"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/decision-log.md" "worker-codex" "worker logged"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'last_decision: "CONTINUE"' "CONTINUE records last decision"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'last_approval: "APPROVED"' "CONTINUE records approval"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'active_workflow: "cs-feat"' "CONTINUE records active workflow"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "next_actor: decision-codex" "worker completion routes back to decision"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "iteration: 1" "worker completion increments iteration"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'last_worker_result: ".codestable/loops/2026-06-14-demo/runs/' "worker completion records output"
  local calls
  calls="$(wc -l < "$CODEX_STUB_LOG" | tr -d ' ')"
  assert_eq "$calls" "3" "CONTINUE should run decision, approval, and worker"
  assert_file_contains "$CODEX_STUB_LOG" "--sandbox read-only" "decision sandbox captured"
  assert_file_contains "$CODEX_STUB_LOG" "--sandbox workspace-write" "worker sandbox captured"
  assert_file_contains "$CODEX_STUB_LOG" "--model decision-model" "decision model captured"
  assert_file_contains "$CODEX_STUB_LOG" "--model approval-model" "approval model captured"
  assert_file_contains "$CODEX_STUB_LOG" "--model worker-model" "worker model captured"
}

test_continue_without_workflow_or_artifact_requests_revision() {
  local repo
  repo="$(make_repo no-workflow)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=continue-no-workflow run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "22" "CONTINUE without workflow requests revision"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "status: needs-revision" "missing workflow marks revision"

  repo="$(make_repo no-artifact)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=continue-no-artifact run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "22" "CONTINUE without artifact path requests revision"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "status: needs-revision" "missing artifact marks revision"
}

test_preserves_existing_iteration_and_unique_run_names() {
  local repo
  repo="$(make_repo preserve-state)"
  make_loop "$repo"
  cat > "$repo/.codestable/loops/2026-06-14-demo/state.yaml" <<'STATE'
doc_type: loop-state
status: active
iteration: 3
next_actor: decision-codex
active_workflow: null
last_decision: null
last_approval: null
last_human_decision: null
last_worker_result: null
last_verification: null
blocked_reason: null
updated: 2000-01-01
STATE
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=continue run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "0" "existing state continue exits 0"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "iteration: 4" "existing iteration is preserved and incremented"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "updated: $(date +%F)" "existing state updated date refreshed"

  CODEX_STUB_DECISION=done run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "0" "second run exits 0"
  assert_file_count "$repo/.codestable/loops/2026-06-14-demo/runs/*-decision-codex.md" "2" "runs decision files are not overwritten"
}

test_worker_failure_records_state_and_output() {
  local repo
  repo="$(make_repo worker-fail)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=continue CODEX_STUB_WORKER=fail \
    run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "42" "worker failure exits with worker status"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "status: blocked" "worker failure marks blocked"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" "next_actor: decision-codex" "worker failure returns to decision"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'blocked_reason: "worker-codex failed with exit 42"' "worker failure records reason"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/decision-log.md" "Status: FAILED (42)" "worker failure logged"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/runs/"*"worker-codex.md" "simulated worker failure" "worker failure output preserved"
}

test_prompt_contract_contains_required_context() {
  local repo prompt_dir
  repo="$(make_repo prompt-contract)"
  make_loop "$repo"
  prompt_dir="$TMP_ROOT/prompts"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_PROMPT_DIR="$prompt_dir" CODEX_STUB_DECISION=continue \
    run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo --objective 'prompt objective'"
  assert_eq "$LAST_STATUS" "0" "prompt contract run exits 0"

  local decision_prompt approval_prompt worker_prompt
  decision_prompt="$(find "$prompt_dir" -name 'decision-*.txt' | head -1)"
  approval_prompt="$(find "$prompt_dir" -name 'approval-*.txt' | head -1)"
  worker_prompt="$(find "$prompt_dir" -name 'worker-*.txt' | head -1)"
  [ -n "$decision_prompt" ] || fail "decision prompt was not captured"
  [ -n "$approval_prompt" ] || fail "approval prompt was not captured"
  [ -n "$worker_prompt" ] || fail "worker prompt was not captured"

  assert_file_contains "$decision_prompt" ".codestable/attention.md" "decision prompt reads attention"
  assert_file_contains "$decision_prompt" "decision-log.md" "decision prompt reads decision log"
  assert_file_contains "$decision_prompt" "approval-log.md" "decision prompt reads approval log"
  assert_file_contains "$decision_prompt" "human-decision.md" "decision prompt reads human decision"
  assert_file_contains "$decision_prompt" "worker-brief.md" "decision prompt reads worker brief"
  assert_file_contains "$decision_prompt" "read-only" "decision prompt states read-only"
  assert_file_contains "$decision_prompt" "Do not approve your own output" "decision prompt forbids self approval"
  assert_file_contains "$decision_prompt" "First choose an active CodeStable workflow" "decision prompt requires active workflow"
  assert_file_contains "$decision_prompt" "prompt objective" "decision prompt includes objective"

  assert_file_contains "$approval_prompt" "Decision output to review:" "approval prompt names decision output"
  assert_file_contains "$approval_prompt" "Parsed decision status:" "approval prompt includes parsed decision"
  assert_file_contains "$approval_prompt" "LOOP_APPROVAL: APPROVED" "approval prompt lists statuses"
  assert_file_contains "$approval_prompt" "Do not invent a replacement plan" "approval prompt preserves approval boundary"
  assert_file_contains "$approval_prompt" "prompt objective" "approval prompt includes objective"

  assert_file_contains "$worker_prompt" "Only execute the approved task" "worker prompt limits execution"
  assert_file_contains "$worker_prompt" "does not name an Active Workflow" "worker prompt blocks missing workflow"
  assert_file_contains "$worker_prompt" "Return:" "worker prompt includes return contract"
}

test_continue_path_extracts_list_workflow() {
  local repo
  repo="$(make_repo continue-list-workflow)"
  make_loop "$repo"
  : > "$CODEX_STUB_LOG"
  CODEX_STUB_DECISION=continue-list-workflow \
    run_capture bash -c "cd '$repo' && '$SCRIPT' --loop-dir .codestable/loops/2026-06-14-demo"
  assert_eq "$LAST_STATUS" "0" "CONTINUE with list workflow exits 0"
  assert_file_contains "$repo/.codestable/loops/2026-06-14-demo/state.yaml" 'active_workflow: "cs-feat"' "CONTINUE extracts list active workflow"
}

export CODEX_STUB_LOG="$TMP_ROOT/codex-stub.log"
make_codex_stub

test_requires_loop_dir
test_requires_codestable
test_requires_complete_codestable_skeleton
test_help_unknown_empty_human_and_missing_codex
test_initializes_missing_loop_dir_and_state_files
test_human_decision_record_mode
test_human_decision_appends_and_escapes_state_pointer
test_done_path_skips_worker
test_done_path_extracts_chosen_workflow
test_done_without_evidence_requests_revision
test_escalate_path_writes_report
test_bad_decision_path_requests_revision
test_decision_status_must_be_first_line_and_uppercase
test_multiple_decision_status_uses_first_line
test_approval_revise_path_skips_worker
test_approval_escalate_path_skips_worker
test_bad_approval_path_writes_escalation
test_approval_status_must_be_first_line
test_continue_path_runs_worker
test_continue_without_workflow_or_artifact_requests_revision
test_preserves_existing_iteration_and_unique_run_names
test_worker_failure_records_state_and_output
test_prompt_contract_contains_required_context
test_continue_path_extracts_list_workflow

echo "All cs-loop tests passed."
