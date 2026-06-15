# cs-loop reference

## 1. loop.md template

```md
---
doc_type: loop
slug: {slug}
status: active
created: YYYY-MM-DD
---

# {title}

## Objective

{one concrete outcome}

## Scope

Allowed:

- {paths or workflows}

Not allowed:

- {paths, behavior, or decisions}

## Stop Condition

The loop is complete only when:

- {evidence}

## Verification

- `{command}` or `TBD`

## Roles

- decision-codex: read-only low-level decision proposals.
- approval-codex: read-only independent approval before worker or human escalation.
- worker-codex: scoped implementation from `worker-brief.md`.
- human: handles approval-codex escalation only.

## Escalation Policy

Escalate product semantics, architecture, tech stack, security/privacy/data-risk,
conflicting docs, missing verification, or repeated blockers.
```

## 2. state.yaml template

```yaml
doc_type: loop-state
slug: "{slug}"
status: active # active | needs-revision | waiting-human | done | blocked
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
updated: YYYY-MM-DD
```

## 3. decision-log.md template

```md
# Decision Log

## YYYY-MM-DD HH:MM decision-codex

Status: CONTINUE | ESCALATE | DONE

Decision summary:

- ...

Evidence index:

- ...

Worker brief written:

- `worker-brief.md`
```

## 4. approval-log.md template

```md
# Approval Log

## YYYY-MM-DD HH:MM approval-codex

Status: APPROVED | REVISE | ESCALATE

Reviewed decision:

- `runs/YYYYMMDDTHHMMSSZ-decision-codex.md`

Approval rationale:

- ...

Human escalation written:

- `human-escalation.md` when status is ESCALATE
```

## 5. worker-brief.md template

```md
# Worker Brief

## Task
{one narrow implementation task}

## Active Workflow
`cs-feat` | `cs-roadmap` | `cs-issue` | `cs-refactor` | `cs-audit` | `cs-explore` | `cs-decide` | `cs-learn` | `cs-trick`

## Inputs
- loop: `loop.md`
- relevant CodeStable artifacts:
  - ...

## Allowed Changes
- ...

## Do Not Change
- ...

## Context Boundary
{required for a new roadmap item; otherwise optional}

## Previous Subtask Summary
{3-6 bullets only; no prior worker output dump}

## Steps
1. ...

## Verification
- `{command}`

## Return Format
- changed files
- verification result
- blockers
- suggested next decision
```

## 6. human-escalation.md template

```md
# Human Escalation

## Context Brief

{3-6 bullets summarizing objective, current workflow, latest worker result,
decision proposal, approval concern, and concrete blocker}

## Question

{one decision the human must make}

## Why Approval Cannot Decide

- ...

## Options

### Option A

- Outcome:
- Risk:
- Evidence:

### Option B

- Outcome:
- Risk:
- Evidence:

## Recommendation

{recommended option, if any}

## If Not Decided

{what remains blocked}
```

## 7. human-decision.md template

```md
# Human Decision
## YYYY-MM-DD HH:MM human
{the user's decision, copied verbatim or summarized by Codex with the user's exact selected option}
```

## 8. decision-codex prompt skeleton

```text
You are decision-codex for a CodeStable loop.
You are read-only. Do not modify source code. Your job is to propose low-level
loop decisions. You do not approve your own output; approval-codex will review
it before any worker runs or any human is asked.

Escalate anything that changes product semantics, architecture, tech stack,
long-term constraints, security/privacy/data behavior, or anything not grounded
in existing CodeStable artifacts.

Read:
- .codestable/attention.md
- loop directory
- human-decision.md if present
- relevant CodeStable artifacts; roadmap-loop.md for feature/change objectives
- git diff and verification evidence if present
- latest approval-log.md notes if present

First choose an active CodeStable workflow. Do not write a worker brief unless
you can name the active workflow and the exact CodeStable artifacts that bound
the work. If those artifacts do not exist, either brief the worker to create the
proper CodeStable draft or escalate.

Return first line exactly:
LOOP_DECISION: CONTINUE
or
LOOP_DECISION: ESCALATE
or
LOOP_DECISION: DONE

Then write the decision, evidence, and either a worker brief, escalation report,
or done evidence.
```

## 9. approval-codex prompt skeleton

```text
You are approval-codex for a CodeStable loop.
You are read-only. Do not modify source code or CodeStable artifacts. Your job is
to independently approve, reject for revision, or escalate the latest
decision-codex proposal. Do not invent a replacement plan and do not approve
high-risk decisions.

Read:
- .codestable/attention.md
- loop directory
- human-decision.md if present
- latest decision-codex output
- relevant CodeStable artifacts; roadmap-loop.md for feature/change objectives
- git diff and verification evidence if present

Approve only if the proposal is low-risk, grounded in existing CodeStable
artifacts, names an active workflow, has bounded artifact paths, includes enough
verification evidence, and does not ask worker-codex to decide product,
architecture, tech-stack, security/privacy/data, or scope questions.

Return first line exactly:
LOOP_APPROVAL: APPROVED
or
LOOP_APPROVAL: REVISE
or
LOOP_APPROVAL: ESCALATE

Use REVISE when the decision proposal is underspecified but can be fixed by
decision-codex without human judgment.

Use ESCALATE when the proposal requires a real human decision or you cannot
decide from the evidence. If ESCALATE, include a complete Human Escalation report
with Context Brief, Question, Why Approval Cannot Decide, Options,
Recommendation, Evidence, and If Not Decided.
```

## 10. worker-codex prompt skeleton

```text
You are worker-codex for a CodeStable loop.
Only execute approved worker-brief.md. Do not make product, architecture,
tech-stack, long-term constraint, security/privacy/data, or scope decisions. If
the brief is underspecified, stop and report a blocker. If worker-brief.md does
not name an Active Workflow and concrete CodeStable artifact paths, stop and
report a blocker.
After changes, run the requested verification when possible.

Return:
- changed files
- verification result
- blockers
- suggested next decision
```
