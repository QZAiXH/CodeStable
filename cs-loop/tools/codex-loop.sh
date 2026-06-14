#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  codex-loop.sh --loop-dir .codestable/loops/YYYY-MM-DD-slug [--objective "..."]
  codex-loop.sh --loop-dir .codestable/loops/YYYY-MM-DD-slug --human-decision "..."

Runs one loop iteration:
  1. decision-codex with read-only sandbox
  2. approval-codex with read-only sandbox
  3. worker-codex with workspace-write sandbox only when approval is APPROVED
     and decision is CONTINUE

Use --human-decision to record a human decision into human-decision.md and hand
the loop back to decision-codex. It does not run Codex.

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

touch "$LOOP_DIR_ABS/decision-log.md"
touch "$LOOP_DIR_ABS/approval-log.md"
touch "$LOOP_DIR_ABS/worker-brief.md"
touch "$LOOP_DIR_ABS/human-escalation.md"
touch "$LOOP_DIR_ABS/human-decision.md"

if [ ! -f "$LOOP_DIR_ABS/state.yaml" ]; then
  cat > "$LOOP_DIR_ABS/state.yaml" <<STATE
doc_type: loop-state
status: active
iteration: 0
next_actor: decision-codex
active_workflow: null
last_decision: null
last_approval: null
last_human_decision: null
last_worker_result: null
last_verification: null
blocked_reason: null
updated: $(date +%F)
STATE
fi

state_set_raw() {
  local key="$1"
  local value="$2"
  local file="$LOOP_DIR_ABS/state.yaml"
  local tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { replaced = 0 }
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

STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"

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
- relevant CodeStable artifacts
- git diff and verification evidence if present

First choose an active CodeStable workflow such as cs-feat, cs-issue,
cs-refactor, cs-audit, cs-explore, cs-decide, cs-learn, or cs-trick. Do not
write a worker brief unless you can name the active workflow and the exact
CodeStable artifact paths that bound the work. If those artifacts do not exist,
either brief the worker to create the proper CodeStable draft or escalate.

Return first line exactly one of:
LOOP_DECISION: CONTINUE
LOOP_DECISION: ESCALATE
LOOP_DECISION: DONE

If CONTINUE, include a complete replacement for worker-brief.md.
If ESCALATE, include a complete human escalation report.
If DONE, include concrete completion evidence.
PROMPT

DECISION_ARGS=()
if [ -n "${CS_LOOP_DECISION_MODEL:-}" ]; then
  DECISION_ARGS=(--model "$CS_LOOP_DECISION_MODEL")
fi

codex exec --cd "$ROOT" --sandbox read-only "${DECISION_ARGS[@]}" \
  -o "$DECISION_OUT" < "$DECISION_PROMPT"

DECISION="$(sed -n '1{s/^LOOP_DECISION: \(CONTINUE\|ESCALATE\|DONE\)$/\1/p;q;}' "$DECISION_OUT")"
ACTIVE_WORKFLOW="$(
  grep -im1 -E '^[[:space:]]*(-[[:space:]]*)?(Active workflow( chosen)?|active_workflow):' "$DECISION_OUT" \
    | sed -E 's/^[[:space:]]*(-[[:space:]]*)?[^:]+:[[:space:]]*`?([^`[:space:]]+).*/\2/' \
    || true
)"

{
  echo
  echo "## $STAMP decision-codex"
  echo
  echo "Output: \`$LOOP_DIR/runs/$(basename "$DECISION_OUT")\`"
  echo
  echo "Status: ${DECISION:-UNPARSEABLE}"
} >> "$LOOP_DIR_ABS/decision-log.md"

state_set_string last_decision "${DECISION:-UNPARSEABLE}"
if [ -n "$ACTIVE_WORKFLOW" ]; then
  state_set_string active_workflow "$ACTIVE_WORKFLOW"
fi
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
- $LOOP_DIR/runs/$(basename "$DECISION_OUT")
- relevant CodeStable artifacts
- git diff and verification evidence if present

Approve only if the proposal is low-risk, grounded in existing CodeStable
artifacts, names an active workflow, has bounded artifact paths, includes enough
verification evidence, and does not ask worker-codex to decide product,
architecture, tech-stack, security/privacy/data, or scope questions.

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

APPROVAL_ARGS=()
if [ -n "${CS_LOOP_APPROVAL_MODEL:-}" ]; then
  APPROVAL_ARGS=(--model "$CS_LOOP_APPROVAL_MODEL")
fi

codex exec --cd "$ROOT" --sandbox read-only "${APPROVAL_ARGS[@]}" \
  -o "$APPROVAL_OUT" < "$APPROVAL_PROMPT"

APPROVAL="$(sed -n '1{s/^LOOP_APPROVAL: \(APPROVED\|REVISE\|ESCALATE\)$/\1/p;q;}' "$APPROVAL_OUT")"

{
  echo
  echo "## $STAMP approval-codex"
  echo
  echo "Output: \`$LOOP_DIR/runs/$(basename "$APPROVAL_OUT")\`"
  echo
  echo "Status: ${APPROVAL:-UNPARSEABLE}"
  echo
  echo "Reviewed decision: \`$LOOP_DIR/runs/$(basename "$DECISION_OUT")\`"
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
    state_set_raw status waiting-human
    state_set_raw next_actor human
    state_touch
    cp "$APPROVAL_OUT" "$LOOP_DIR_ABS/human-escalation.md"
    echo "Human decision required. See $LOOP_DIR/human-escalation.md"
    exit 20
    ;;
  CONTINUE)
    state_set_raw status active
    state_set_raw next_actor worker-codex
    state_touch
    cp "$DECISION_OUT" "$LOOP_DIR_ABS/worker-brief.md"
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

After changes, run the requested verification when possible.

Return:
- changed files
- verification result
- blockers
- suggested next decision
PROMPT

WORKER_ARGS=()
if [ -n "${CS_LOOP_WORKER_MODEL:-}" ]; then
  WORKER_ARGS=(--model "$CS_LOOP_WORKER_MODEL")
fi

WORKER_SANDBOX="${CS_LOOP_WORKER_SANDBOX:-workspace-write}"
set +e
codex exec --cd "$ROOT" --sandbox "$WORKER_SANDBOX" "${WORKER_ARGS[@]}" \
  -o "$WORKER_OUT" < "$WORKER_PROMPT"
WORKER_STATUS=$?
set -e

{
  echo
  echo "## $STAMP worker-codex"
  echo
  echo "Output: \`$LOOP_DIR/runs/$(basename "$WORKER_OUT")\`"
  if [ "$WORKER_STATUS" -ne 0 ]; then
    echo
    echo "Status: FAILED ($WORKER_STATUS)"
  fi
} >> "$LOOP_DIR_ABS/decision-log.md"

state_set_string last_worker_result "$LOOP_DIR/runs/$(basename "$WORKER_OUT")"
state_set_raw next_actor decision-codex
if [ "$WORKER_STATUS" -ne 0 ]; then
  state_set_raw status blocked
  state_set_string blocked_reason "worker-codex failed with exit $WORKER_STATUS"
  state_touch
  echo "Worker failed with exit $WORKER_STATUS. Output: $WORKER_OUT" >&2
  exit "$WORKER_STATUS"
fi
state_increment_iteration
state_touch

echo "Worker finished. Output: $WORKER_OUT"
