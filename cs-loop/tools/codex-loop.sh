#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  codex-loop.sh --init --loop-dir .codestable/loops/YYYY-MM-DD-slug --objective "..."
  codex-loop.sh --loop-dir .codestable/loops/YYYY-MM-DD-slug [--objective "..."]
  codex-loop.sh --loop-dir .codestable/loops/YYYY-MM-DD-slug --human-decision "..."

Runs one loop iteration:
  1. decision-codex with read-only sandbox
  2. approval-codex with read-only sandbox
  3. worker-codex with workspace-write sandbox only when approval is APPROVED
     and decision is CONTINUE

Use --human-decision to record a human decision into human-decision.md and hand
the loop back to decision-codex. It does not run Codex.
Use --init to create or repair the loop control files without running Codex.

Environment:
  CS_LOOP_DECISION_MODEL   Optional model for decision-codex
  CS_LOOP_APPROVAL_MODEL   Optional model for approval-codex
  CS_LOOP_WORKER_MODEL     Optional model for worker-codex
  CS_LOOP_WORKER_SANDBOX   Defaults to workspace-write
USAGE
}

LOOP_DIR=""
OBJECTIVE=""
HUMAN_DECISION=""
HUMAN_DECISION_PROVIDED=0
INIT_ONLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --loop-dir)
      LOOP_DIR="${2:-}"
      shift 2
      ;;
    --objective)
      OBJECTIVE="${2:-}"
      shift 2
      ;;
    --human-decision)
      HUMAN_DECISION="${2:-}"
      HUMAN_DECISION_PROVIDED=1
      shift 2
      ;;
    --init)
      INIT_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$LOOP_DIR" ]; then
  echo "--loop-dir is required" >&2
  usage >&2
  exit 2
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOOP_DIR_ABS="$ROOT/$LOOP_DIR"
RUNS_DIR="$LOOP_DIR_ABS/runs"
LOOP_BASENAME="$(basename "$LOOP_DIR")"
LOOP_SLUG="$(printf '%s' "$LOOP_BASENAME" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//')"

if [ ! -d "$ROOT/.codestable" ]; then
  echo "Missing .codestable/. Run cs-onboard before cs-loop." >&2
  exit 3
fi

for required_file in \
  ".codestable/attention.md" \
  ".codestable/reference/system-overview.md" \
  ".codestable/reference/shared-conventions.md"
do
  if [ ! -f "$ROOT/$required_file" ]; then
    echo "Incomplete .codestable skeleton. Missing $required_file. Run cs-onboard before cs-loop." >&2
    exit 4
  fi
done

mkdir -p "$RUNS_DIR"

ensure_markdown_file() {
  local file="$1"
  local title="$2"
  if [ ! -f "$file" ]; then
    {
      echo "# $title"
      echo
    } > "$file"
  fi
}

ensure_markdown_file "$LOOP_DIR_ABS/decision-log.md" "Decision Log"
ensure_markdown_file "$LOOP_DIR_ABS/approval-log.md" "Approval Log"
ensure_markdown_file "$LOOP_DIR_ABS/worker-brief.md" "Worker Brief"
ensure_markdown_file "$LOOP_DIR_ABS/human-escalation.md" "Human Escalation"
ensure_markdown_file "$LOOP_DIR_ABS/human-decision.md" "Human Decision"
ensure_markdown_file "$LOOP_DIR_ABS/subtask-summary.md" "Subtask Summary"

if [ ! -f "$LOOP_DIR_ABS/loop.md" ]; then
  cat > "$LOOP_DIR_ABS/loop.md" <<LOOP
---
doc_type: loop
slug: $LOOP_SLUG
status: active
created: $(date +%F)
---

# $LOOP_SLUG

## Objective

${OBJECTIVE:-TBD: fill the concrete outcome before relying on this loop.}

## Scope

Allowed:

- TBD: name allowed workflows and paths.

Not allowed:

- Product semantics, architecture, tech stack, security, privacy, data behavior, deployment, or migrations unless already approved in CodeStable artifacts.

## Stop Condition

The loop is complete only when:

- TBD: name the evidence that proves completion.

## Verification

- \`TBD\`

## Roles

- decision-codex: read-only low-level decision proposals.
- approval-codex: read-only independent approval before worker or human escalation.
- worker-codex: scoped implementation from \`worker-brief.md\`.
- human: handles approval-codex escalation only.

## Escalation Policy

Escalate product semantics, architecture, tech stack, security/privacy/data-risk,
conflicting docs, missing verification, or repeated blockers.
LOOP
fi

if [ ! -f "$LOOP_DIR_ABS/state.yaml" ]; then
  cat > "$LOOP_DIR_ABS/state.yaml" <<STATE
doc_type: loop-state
slug: "$LOOP_SLUG"
status: active
iteration: 0
next_actor: decision-codex
active_workflow: null
active_roadmap: null
active_roadmap_item: null
roadmap_stage: null
last_decision: null
last_approval: null
last_human_decision: null
last_worker_result: null
last_subtask_summary: null
last_verification: null
blocked_reason: null
blocker_count: 0
last_blocker_signature: null
updated: $(date +%F)
STATE
fi

state_set_raw() {
  local key="$1"
  local value="$2"
  local file="$LOOP_DIR_ABS/state.yaml"
  local tmp
  tmp="$(mktemp)"
  STATE_VALUE="$value" awk -v key="$key" '
    BEGIN {
      value = ENVIRON["STATE_VALUE"]
      replaced = 0
    }
    $0 ~ "^" key ":" {
      print key ": " value
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) {
        print key ": " value
      }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

yaml_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

state_set_string() {
  state_set_raw "$1" "$(yaml_quote "$2")"
}

state_set_optional_string() {
  local key="$1"
  local value="$2"
  if [ -z "$value" ]; then
    return
  fi
  if [ "$value" = "null" ]; then
    state_set_raw "$key" null
  else
    state_set_string "$key" "$value"
  fi
}

state_touch() {
  state_set_raw updated "$(date +%F)"
}

state_increment_iteration() {
  local current
  current="$(awk -F ': *' '$1 == "iteration" { print $2; found = 1 } END { if (!found) print 0 }' "$LOOP_DIR_ABS/state.yaml")"
  case "$current" in
    ''|*[!0-9]*) current=0 ;;
  esac
  state_set_raw iteration "$((current + 1))"
}

state_ensure_key() {
  local key="$1"
  local value="$2"
  if ! grep -q "^$key:" "$LOOP_DIR_ABS/state.yaml"; then
    state_set_raw "$key" "$value"
  fi
}

state_get_value() {
  local key="$1"
  awk -F ': *' -v key="$key" '
    $1 == key {
      value = substr($0, index($0, ":") + 1)
      sub(/^[[:space:]]*/, "", value)
      if (value ~ /^".*"$/) {
        sub(/^"/, "", value)
        sub(/"$/, "", value)
      }
      print value
      exit
    }
  ' "$LOOP_DIR_ABS/state.yaml"
}

state_get_int() {
  local key="$1"
  local value
  value="$(state_get_value "$key")"
  case "$value" in
    ''|*[!0-9]*) value=0 ;;
  esac
  printf '%s\n' "$value"
}

extract_scalar_field() {
  local pattern="$1"
  local file="$2"
  grep -im1 -E "^[[:space:]]*(-[[:space:]]*)?(${pattern}):" "$file" \
    | sed -E 's/^[[:space:]]*(-[[:space:]]*)?[^:]+:[[:space:]]*`?([^`[:space:]]+).*/\2/' \
    || true
}

extract_text_field() {
  local pattern="$1"
  local file="$2"
  grep -im1 -E "^[[:space:]]*(-[[:space:]]*)?(${pattern}):" "$file" \
    | sed -E 's/^[[:space:]]*(-[[:space:]]*)?[^:]+:[[:space:]]*//; s/^`//; s/`$//' \
    || true
}

first_nonempty_body_line() {
  local file="$1"
  awk '
    NR == 1 { next }
    /^[[:space:]]*$/ { next }
    {
      line = $0
      sub(/^[[:space:]-]*/, "", line)
      print line
      exit
    }
  ' "$file"
}

extract_worker_block() {
  local field="$1"
  local file="$2"
  awk -v field="$field" '
    BEGIN { wanted = tolower(field); found = 0; count = 0 }
    {
      line = $0
      lower = tolower(line)
      if (lower ~ "^" wanted ":[[:space:]]*$") {
        found = 1
        next
      }
      if (found && lower ~ "^[a-z][a-z ]*:[[:space:]]*$") {
        exit
      }
      if (found && line !~ /^[[:space:]]*$/) {
        sub(/^[[:space:]-]*/, "", line)
        print line
        count++
        if (count >= 3) {
          exit
        }
      }
    }
  ' "$file"
}

join_lines() {
  awk 'NF { if (out != "") out = out "; "; out = out $0 } END { print out }'
}

blocker_signature() {
  local text="$1"
  printf '%s' "$text" | cksum | awk '{ print $1 ":" $2 }'
}

write_human_blocker_escalation() {
  local reason="$1"
  local signature="$2"
  local count="$3"
  local worker_output="$4"
  cat > "$LOOP_DIR_ABS/human-escalation.md" <<ESCALATION
# Human Escalation

## Context Brief

- The loop hit the same worker blocker in consecutive rounds.
- Blocker count: $count.
- Blocker signature: $signature.
- Latest worker output: \`$worker_output\`.

## Question

How should the loop proceed past this repeated blocker?

## Why Approval Cannot Decide

- Repeating the same blocker means the low-level loop is no longer making safe progress.

## Options

### Option A

- Outcome: Update the CodeStable artifacts or worker brief before continuing.
- Risk: Slower, but keeps scope explicit.
- Evidence: $reason

### Option B

- Outcome: Stop this loop and handle the blocker manually.
- Risk: More manual work.
- Evidence: $reason

## Recommendation

Choose Option A if the blocker is caused by missing scope, verification, or artifact detail; choose Option B if it needs debugging outside the loop.

## If Not Decided

The loop remains stopped before another worker run.
ESCALATION
}

record_blocker() {
  local reason="$1"
  local worker_output="$2"
  local exit_code="$3"
  local signature previous_signature count
  signature="$(blocker_signature "$reason")"
  previous_signature="$(state_get_value last_blocker_signature)"
  count="$(state_get_int blocker_count)"
  if [ "$previous_signature" = "$signature" ]; then
    count="$((count + 1))"
  else
    count=1
  fi

  state_set_string last_blocker_signature "$signature"
  state_set_raw blocker_count "$count"
  state_set_string blocked_reason "$reason"

  if [ "$count" -ge 2 ]; then
    state_set_raw status waiting-human
    state_set_raw next_actor human
    write_human_blocker_escalation "$reason" "$signature" "$count" "$worker_output"
    state_touch
    echo "Repeated blocker requires human decision. See $LOOP_DIR/human-escalation.md" >&2
    exit 20
  fi

  state_set_raw status blocked
  state_set_raw next_actor decision-codex
  state_touch
  if [ "$exit_code" -eq 0 ]; then
    echo "Worker reported a blocker. Output: $worker_output" >&2
    exit 25
  fi
  echo "Worker failed with exit $exit_code. Output: $worker_output" >&2
  exit "$exit_code"
}

reset_blocker_state() {
  state_set_raw blocker_count 0
  state_set_raw last_blocker_signature null
  state_set_raw blocked_reason null
}

extract_worker_brief() {
  local source="$1"
  local destination="$2"
  if grep -q '^# Worker Brief[[:space:]]*$' "$source"; then
    awk 'found { print } /^# Worker Brief[[:space:]]*$/ { found = 1; print }' "$source" > "$destination"
  else
    cp "$source" "$destination"
  fi
}

brief_has_section() {
  local section="$1"
  local file="$2"
  grep -Eq "^##[[:space:]]+$section[[:space:]]*$" "$file"
}

extract_brief_section_value() {
  local section="$1"
  local file="$2"
  awk -v section="$section" '
    $0 ~ "^##[[:space:]]+" section "[[:space:]]*$" {
      found = 1
      next
    }
    found && /^##[[:space:]]+/ {
      exit
    }
    found && $0 !~ /^[[:space:]]*$/ {
      line = $0
      sub(/^[[:space:]-]*/, "", line)
      sub(/^[Aa]ctive [Ww]orkflow:[[:space:]]*/, "", line)
      gsub(/`/, "", line)
      split(line, parts, /[[:space:],]+/)
      print parts[1]
      exit
    }
  ' "$file"
}

is_allowed_workflow() {
  case "$1" in
    cs-feat|cs-roadmap|cs-issue|cs-refactor|cs-audit|cs-explore|cs-decide|cs-learn|cs-trick)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_worker_brief() {
  local file="$1"
  local missing=""
  local section workflow
  for section in "Task" "Active Workflow" "Inputs" "Allowed Changes" "Verification" "Return Format"; do
    if ! brief_has_section "$section" "$file"; then
      missing="$missing $section"
    fi
  done
  if [ -n "$missing" ]; then
    echo "worker brief missing required section(s):$missing" >&2
    return 1
  fi
  if ! grep -Eq '\.codestable/(features|issues|refactors|roadmap|architecture|requirements|compound|audits)/' "$file"; then
    echo "worker brief does not include a bounded CodeStable artifact path" >&2
    return 1
  fi
  workflow="$(extract_brief_section_value "Active Workflow" "$file")"
  if ! is_allowed_workflow "$workflow"; then
    echo "worker brief does not include an allowed active workflow" >&2
    return 1
  fi
}

validate_human_escalation_report() {
  local file="$1"
  local section
  for section in "Context Brief" "Question" "Why Approval Cannot Decide" "Options" "Recommendation" "If Not Decided"; do
    if ! brief_has_section "$section" "$file"; then
      echo "human escalation report missing section: $section" >&2
      return 1
    fi
  done
}

state_ensure_key active_roadmap null
state_ensure_key active_roadmap_item null
state_ensure_key roadmap_stage null
state_ensure_key last_subtask_summary null
state_ensure_key last_verification null
state_ensure_key blocker_count 0
state_ensure_key last_blocker_signature null

STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"

if [ "$INIT_ONLY" -eq 1 ]; then
  state_touch
  echo "Loop initialized in $LOOP_DIR. Fill TBD fields in loop.md before relying on automated execution."
  exit 0
fi

if [ "$HUMAN_DECISION_PROVIDED" -eq 1 ]; then
  if [ -z "$HUMAN_DECISION" ]; then
    echo "--human-decision requires a non-empty value" >&2
    exit 2
  fi

  {
    echo
    echo "## $STAMP human"
    echo
    printf '%s\n' "$HUMAN_DECISION"
  } >> "$LOOP_DIR_ABS/human-decision.md"

  state_set_raw status active
  state_set_raw next_actor decision-codex
  state_set_string last_human_decision "$LOOP_DIR/human-decision.md#$STAMP"
  state_set_raw blocked_reason null
  state_set_raw blocker_count 0
  state_set_raw last_blocker_signature null
  state_touch

  echo "Human decision recorded in $LOOP_DIR/human-decision.md. Re-run without --human-decision to continue."
  exit 0
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "codex command not found" >&2
  exit 127
fi

DECISION_OUT="$RUNS_DIR/$STAMP-decision-codex.md"
APPROVAL_OUT="$RUNS_DIR/$STAMP-approval-codex.md"
WORKER_OUT="$RUNS_DIR/$STAMP-worker-codex.md"
DECISION_PROMPT="$(mktemp)"
APPROVAL_PROMPT="$(mktemp)"
WORKER_PROMPT="$(mktemp)"
trap 'rm -f "$DECISION_PROMPT" "$APPROVAL_PROMPT" "$WORKER_PROMPT"' EXIT

cat > "$DECISION_PROMPT" <<PROMPT
You are decision-codex for a CodeStable loop.

You are read-only. Do not modify source code. Propose low-level loop decisions.
Do not approve your own output; approval-codex will review your proposal before
any worker runs or any human is asked. Escalate product semantics, architecture,
tech stack, long-term constraints, security/privacy/data behavior, conflicting
docs, missing verification, or repeated blockers.

Objective:
${OBJECTIVE:-Read loop.md in the loop directory.}

Loop directory:
$LOOP_DIR

Read:
- .codestable/attention.md if present
- $LOOP_DIR/loop.md
- $LOOP_DIR/state.yaml
- $LOOP_DIR/decision-log.md
- $LOOP_DIR/approval-log.md
- $LOOP_DIR/human-decision.md
- $LOOP_DIR/worker-brief.md
- $LOOP_DIR/subtask-summary.md
- relevant CodeStable artifacts
- .codestable/roadmap/ when the objective may be larger than one feature
- git diff and verification evidence if present

First choose an active CodeStable workflow such as cs-feat, cs-roadmap,
cs-issue, cs-refactor, cs-audit, cs-explore, cs-decide, cs-learn, or cs-trick.
For feature/change objectives, first classify task size:
- Use cs-feat only when the work fits one feature design/implementation/acceptance
  and does not need cross-feature interface contracts or a dependency DAG.
- Use cs-roadmap when the request spans multiple independently acceptable
  deliverables, multiple modules, shared contracts, or ordered sub-features.

When cs-roadmap is chosen, first brief worker-codex to create or update the
roadmap docs and items.yaml only. After that, approval-codex must review whether
the decomposition is reasonable before any sub-feature starts. Once approved,
continue through existing cs-feat flow one roadmap item at a time.

For roadmap loops, include these metadata lines whenever known:
Active workflow: <workflow>
Roadmap: <roadmap-slug-or-null>
Roadmap item: <item-slug-or-null>
Roadmap stage: routing | roadmap-draft | roadmap-review | feature-design | feature-impl | feature-accept | completed
Previous subtask summary: <one short line or null>

Do not write a worker brief unless you can name the active workflow and the
exact CodeStable artifact paths that bound the work. If those artifacts do not
exist, either brief the worker to create the proper CodeStable draft or escalate.

When starting a new roadmap item, the worker brief must include:
- a Context Boundary section that says this is a fresh subtask context
- a Previous Subtask Summary section with only the prior item's accepted outcome,
  validation, changed contracts, and remaining constraints
- explicit instruction not to read previous feature directories or old worker
  outputs unless they are named as inputs

Return first line exactly one of:
LOOP_DECISION: CONTINUE
LOOP_DECISION: ESCALATE
LOOP_DECISION: DONE

If CONTINUE, include a complete replacement for worker-brief.md.
If ESCALATE, include a complete human escalation report.
If DONE, include concrete completion evidence.
PROMPT

if [ -n "${CS_LOOP_DECISION_MODEL:-}" ]; then
  codex exec --cd "$ROOT" --sandbox read-only --model "$CS_LOOP_DECISION_MODEL" \
    -o "$DECISION_OUT" < "$DECISION_PROMPT"
else
  codex exec --cd "$ROOT" --sandbox read-only \
    -o "$DECISION_OUT" < "$DECISION_PROMPT"
fi

DECISION_FIRST_LINE="$(sed -n '1p' "$DECISION_OUT")"
case "$DECISION_FIRST_LINE" in
  "LOOP_DECISION: CONTINUE") DECISION="CONTINUE" ;;
  "LOOP_DECISION: ESCALATE") DECISION="ESCALATE" ;;
  "LOOP_DECISION: DONE") DECISION="DONE" ;;
  *) DECISION="" ;;
esac
ACTIVE_WORKFLOW="$(
  grep -im1 -E '^[[:space:]]*(-[[:space:]]*)?(Active workflow( chosen)?|active_workflow):' "$DECISION_OUT" \
    | sed -E 's/^[[:space:]]*(-[[:space:]]*)?[^:]+:[[:space:]]*`?([^`[:space:]]+).*/\2/' \
    || true
)"
ACTIVE_ROADMAP="$(extract_scalar_field 'Roadmap|active_roadmap' "$DECISION_OUT")"
ACTIVE_ROADMAP_ITEM="$(extract_scalar_field 'Roadmap item|roadmap_item|active_roadmap_item' "$DECISION_OUT")"
ROADMAP_STAGE="$(extract_scalar_field 'Roadmap stage|roadmap_stage' "$DECISION_OUT")"
PREVIOUS_SUBTASK_SUMMARY="$(extract_text_field 'Previous subtask summary|previous_subtask_summary|Last subtask summary|last_subtask_summary' "$DECISION_OUT")"
DECISION_SUMMARY="$(first_nonempty_body_line "$DECISION_OUT")"

{
  echo
  echo "## $STAMP decision-codex"
  echo
  echo "Output: \`$LOOP_DIR/runs/$(basename "$DECISION_OUT")\`"
  echo
  echo "Status: ${DECISION:-UNPARSEABLE}"
  echo
  echo "Decision summary:"
  echo
  echo "- ${DECISION_SUMMARY:-See raw output.}"
  echo
  echo "Evidence index:"
  echo
  echo "- Raw decision output: \`$LOOP_DIR/runs/$(basename "$DECISION_OUT")\`"
  echo "- Active workflow: ${ACTIVE_WORKFLOW:-unknown}"
  echo "- Roadmap: ${ACTIVE_ROADMAP:-unknown}"
  echo "- Roadmap item: ${ACTIVE_ROADMAP_ITEM:-unknown}"
} >> "$LOOP_DIR_ABS/decision-log.md"

state_set_string last_decision "${DECISION:-UNPARSEABLE}"
state_set_optional_string active_workflow "$ACTIVE_WORKFLOW"
state_set_optional_string active_roadmap "$ACTIVE_ROADMAP"
state_set_optional_string active_roadmap_item "$ACTIVE_ROADMAP_ITEM"
state_set_optional_string roadmap_stage "$ROADMAP_STAGE"
state_set_optional_string last_subtask_summary "$PREVIOUS_SUBTASK_SUMMARY"
state_set_raw next_actor approval-codex
state_touch

cat > "$APPROVAL_PROMPT" <<PROMPT
You are approval-codex for a CodeStable loop.

You are read-only. Do not modify source code or CodeStable artifacts. Your job is
to independently approve, reject for revision, or escalate the latest
decision-codex proposal. Do not invent a replacement plan and do not approve
high-risk decisions.

Objective:
${OBJECTIVE:-Read loop.md in the loop directory.}

Loop directory:
$LOOP_DIR

Decision output to review:
$LOOP_DIR/runs/$(basename "$DECISION_OUT")

Parsed decision status:
${DECISION:-UNPARSEABLE}

Read:
- .codestable/attention.md if present
- $LOOP_DIR/loop.md
- $LOOP_DIR/state.yaml
- $LOOP_DIR/decision-log.md
- $LOOP_DIR/approval-log.md
- $LOOP_DIR/human-decision.md
- $LOOP_DIR/worker-brief.md
- $LOOP_DIR/subtask-summary.md
- $LOOP_DIR/runs/$(basename "$DECISION_OUT")
- relevant CodeStable artifacts
- .codestable/roadmap/ when the objective may be larger than one feature
- git diff and verification evidence if present

Approve only if the proposal is low-risk, grounded in existing CodeStable
artifacts, names an active workflow, has bounded artifact paths, includes enough
verification evidence, and does not ask worker-codex to decide product,
architecture, tech-stack, security/privacy/data, or scope questions.

For feature/change objectives, independently check the task-size routing. If a
multi-feature request is routed directly to cs-feat without a reason, use REVISE
or ESCALATE. If the proposal creates or updates a roadmap, review the split:
module boundaries, executable interface contracts, items.yaml DAG, dependency
reasons, one minimal loop item, and no hidden product-priority decision. Use
REVISE for fixable split issues. Use ESCALATE only when a real human choice is
needed, such as product priority, architecture direction, or conflicting docs.

For a proposal that starts a new roadmap item in cs-feat, approve only when the
worker brief contains Context Boundary and Previous Subtask Summary sections and
does not invite worker-codex to read previous feature directories or old worker
outputs as context unless explicitly listed as inputs.

Return first line exactly one of:
LOOP_APPROVAL: APPROVED
LOOP_APPROVAL: REVISE
LOOP_APPROVAL: ESCALATE

Use REVISE when the decision proposal is underspecified but can be fixed by
decision-codex without human judgment.

Use ESCALATE when the proposal requires a real human decision or you cannot
decide from the evidence. If ESCALATE, include a complete Human Escalation report
with Context Brief, Question, Why Approval Cannot Decide, Options,
Recommendation, Evidence, and If Not Decided.

If approving a decision proposal whose status is ESCALATE, also include a
complete Human Escalation report so it can be shown directly to the user.
PROMPT

if [ -n "${CS_LOOP_APPROVAL_MODEL:-}" ]; then
  codex exec --cd "$ROOT" --sandbox read-only --model "$CS_LOOP_APPROVAL_MODEL" \
    -o "$APPROVAL_OUT" < "$APPROVAL_PROMPT"
else
  codex exec --cd "$ROOT" --sandbox read-only \
    -o "$APPROVAL_OUT" < "$APPROVAL_PROMPT"
fi

APPROVAL_FIRST_LINE="$(sed -n '1p' "$APPROVAL_OUT")"
case "$APPROVAL_FIRST_LINE" in
  "LOOP_APPROVAL: APPROVED") APPROVAL="APPROVED" ;;
  "LOOP_APPROVAL: REVISE") APPROVAL="REVISE" ;;
  "LOOP_APPROVAL: ESCALATE") APPROVAL="ESCALATE" ;;
  *) APPROVAL="" ;;
esac
APPROVAL_SUMMARY="$(first_nonempty_body_line "$APPROVAL_OUT")"

{
  echo
  echo "## $STAMP approval-codex"
  echo
  echo "Output: \`$LOOP_DIR/runs/$(basename "$APPROVAL_OUT")\`"
  echo
  echo "Status: ${APPROVAL:-UNPARSEABLE}"
  echo
  echo "Reviewed decision: \`$LOOP_DIR/runs/$(basename "$DECISION_OUT")\`"
  echo
  echo "Approval rationale:"
  echo
  echo "- ${APPROVAL_SUMMARY:-See raw output.}"
  echo
  echo "Evidence index:"
  echo
  echo "- Raw approval output: \`$LOOP_DIR/runs/$(basename "$APPROVAL_OUT")\`"
} >> "$LOOP_DIR_ABS/approval-log.md"

state_set_string last_approval "${APPROVAL:-UNPARSEABLE}"
state_touch

case "$APPROVAL" in
  APPROVED)
    ;;
  REVISE)
    state_set_raw status needs-revision
    state_set_raw next_actor decision-codex
    state_set_string blocked_reason "approval requested decision revision"
    state_touch
    echo "Decision revision required. See $LOOP_DIR/approval-log.md and $APPROVAL_OUT"
    exit 22
    ;;
  ESCALATE)
    if ! validate_human_escalation_report "$APPROVAL_OUT"; then
      state_set_raw status blocked
      state_set_raw next_actor human
      state_set_string blocked_reason "approval escalation report failed template validation"
      state_touch
      cp "$APPROVAL_OUT" "$LOOP_DIR_ABS/human-escalation.md"
      echo "Approval escalation report failed template validation. See $LOOP_DIR/human-escalation.md" >&2
      exit 24
    fi
    state_set_raw status waiting-human
    state_set_raw next_actor human
    state_touch
    cp "$APPROVAL_OUT" "$LOOP_DIR_ABS/human-escalation.md"
    echo "Human decision required. See $LOOP_DIR/human-escalation.md"
    exit 20
    ;;
  *)
    state_set_raw status blocked
    state_set_raw next_actor human
    state_touch
    cp "$APPROVAL_OUT" "$LOOP_DIR_ABS/human-escalation.md"
    echo "Approval output was not parseable. See $LOOP_DIR/human-escalation.md" >&2
    exit 23
    ;;
esac

case "$DECISION" in
  DONE)
    state_set_raw status done
    state_set_raw next_actor null
    state_touch
    echo "Loop done. Decision output: $DECISION_OUT Approval output: $APPROVAL_OUT"
    exit 0
    ;;
  ESCALATE)
    if ! validate_human_escalation_report "$APPROVAL_OUT"; then
      state_set_raw status blocked
      state_set_raw next_actor human
      state_set_string blocked_reason "approved escalation report failed template validation"
      state_touch
      cp "$APPROVAL_OUT" "$LOOP_DIR_ABS/human-escalation.md"
      echo "Approved escalation report failed template validation. See $LOOP_DIR/human-escalation.md" >&2
      exit 24
    fi
    state_set_raw status waiting-human
    state_set_raw next_actor human
    state_touch
    cp "$APPROVAL_OUT" "$LOOP_DIR_ABS/human-escalation.md"
    echo "Human decision required. See $LOOP_DIR/human-escalation.md"
    exit 20
    ;;
  CONTINUE)
    BRIEF_ACTIVE_WORKFLOW=""
    state_set_raw status active
    state_set_raw next_actor worker-codex
    state_touch
    extract_worker_brief "$DECISION_OUT" "$LOOP_DIR_ABS/worker-brief.md"
    if ! validate_worker_brief "$LOOP_DIR_ABS/worker-brief.md"; then
      state_set_raw status needs-revision
      state_set_raw next_actor decision-codex
      state_set_string blocked_reason "worker brief failed script validation"
      state_touch
      echo "Worker brief failed script validation. See $LOOP_DIR/worker-brief.md" >&2
      exit 26
    fi
    BRIEF_ACTIVE_WORKFLOW="$(extract_brief_section_value "Active Workflow" "$LOOP_DIR_ABS/worker-brief.md")"
    state_set_optional_string active_workflow "$BRIEF_ACTIVE_WORKFLOW"
    ;;
  *)
    state_set_raw status blocked
    state_set_raw next_actor human
    state_touch
    cp "$APPROVAL_OUT" "$LOOP_DIR_ABS/human-escalation.md"
    echo "Approved decision output was not parseable. See $LOOP_DIR/human-escalation.md" >&2
    exit 21
    ;;
esac

cat > "$WORKER_PROMPT" <<PROMPT
You are worker-codex for a CodeStable loop.

Only execute the approved task in:
$LOOP_DIR/worker-brief.md

Do not make product, architecture, tech-stack, long-term constraint, or scope
decisions. If the brief is underspecified, stop and report a blocker.
If the brief does not name an Active Workflow and concrete CodeStable artifact
paths, stop and report a blocker.

If the brief is for a roadmap item, treat its Context Boundary as a hard
boundary. Start from the current worker brief, the named roadmap docs/items, the
target feature artifacts, and current code. Do not read previous feature
directories, old worker outputs, or conversation history unless the brief names
them as inputs. Use only the Previous Subtask Summary for prior-item context.

After changes, run the requested verification when possible.

Return:
- changed files
- verification result
- blockers
- suggested next decision
PROMPT

WORKER_SANDBOX="${CS_LOOP_WORKER_SANDBOX:-workspace-write}"
set +e
if [ -n "${CS_LOOP_WORKER_MODEL:-}" ]; then
  codex exec --cd "$ROOT" --sandbox "$WORKER_SANDBOX" --model "$CS_LOOP_WORKER_MODEL" \
    -o "$WORKER_OUT" < "$WORKER_PROMPT"
else
  codex exec --cd "$ROOT" --sandbox "$WORKER_SANDBOX" \
    -o "$WORKER_OUT" < "$WORKER_PROMPT"
fi
WORKER_STATUS=$?
set -e
WORKER_REL="$LOOP_DIR/runs/$(basename "$WORKER_OUT")"
WORKER_VERIFICATION="$(extract_worker_block "verification result" "$WORKER_OUT" | join_lines)"
WORKER_BLOCKERS="$(extract_worker_block "blockers" "$WORKER_OUT" | join_lines)"

{
  echo
  echo "## $STAMP worker-codex"
  echo
  echo "Output: \`$WORKER_REL\`"
  echo
  echo "Verification:"
  echo
  echo "- ${WORKER_VERIFICATION:-not reported}"
  echo
  echo "Blockers:"
  echo
  echo "- ${WORKER_BLOCKERS:-not reported}"
  if [ "$WORKER_STATUS" -ne 0 ]; then
    echo
    echo "Status: FAILED ($WORKER_STATUS)"
  fi
} >> "$LOOP_DIR_ABS/decision-log.md"

state_set_string last_worker_result "$WORKER_REL"
state_set_string last_verification "${WORKER_VERIFICATION:-not reported}"
state_set_raw next_actor decision-codex
if [ "$WORKER_STATUS" -ne 0 ]; then
  record_blocker "worker-codex failed with exit $WORKER_STATUS: ${WORKER_BLOCKERS:-no blocker details reported}" "$WORKER_REL" "$WORKER_STATUS"
fi

if [ -n "$WORKER_BLOCKERS" ] && ! printf '%s\n' "$WORKER_BLOCKERS" | grep -Eiq '^(none|no blockers?|n/a|null)$'; then
  record_blocker "worker-codex reported blocker: $WORKER_BLOCKERS" "$WORKER_REL" 0
fi

reset_blocker_state
state_increment_iteration
state_touch

echo "Worker finished. Output: $WORKER_OUT"
