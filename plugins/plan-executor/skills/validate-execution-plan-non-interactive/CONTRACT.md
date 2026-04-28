# Contract: `validate-execution-plan-non-interactive`

This document is the wire-level contract between the Rust plan-executor caller and the
`plan-executor:validate-execution-plan-non-interactive` helper skill. It pins the I/O
contract used by the Rust phase-controller; full prose semantics live in `SKILL.md`.

Schemas: `schemas/input.schema.json` and `schemas/output.schema.json` (JSON Schema 2020-12).

---

## Single Responsibility

**Does:** own the Phase 6 validation loop — emit validator handoffs, parse the
deterministic validator report, extract GAPS and required DEVIATIONS, batch
validation-fix handoffs (≤ 5 per batch), persist helper-owned validation state,
require regression re-review after fix passes, enforce the 5-attempt validation cap,
and return a deterministic verdict to the caller per invocation.

**Does NOT:**

- write production, test, or fix code directly,
- re-implement code review (it delegates to `review-execution-output-non-interactive`
  for required re-reviews),
- own orchestration state or PR finalization,
- decide the next phase — it returns a verdict; the orchestrator decides next phase.

---

## Input Shape

| Field | Type | Required | Semantics |
|---|---|---|---|
| `plan_path` | string | yes | absolute plan path. |
| `execution_root` | string | yes | absolute execution root. Must exist and be writable. |
| `changed_files` | string[] | yes | files created or modified during execution. May be empty. |
| `language` | `"typescript" \| "python" \| "go" \| "rust" \| "unknown"` | yes | resolved language. |
| `recipe_list` | string[] | yes | recipe skills relevant to the changed code. May be `[]`. |
| `skip_code_review` | boolean | yes | if `true`, the helper skips the post-fix re-review step. |
| `state_file_path` | string | yes | absolute path to the orchestrator's `.tmp-execute-plan-state.json`. |
| `execution_state` | object | yes | current persisted orchestrator state snapshot. |
| `validation_state` | object \| null | yes | current persisted helper-owned validation state. `null` on first entry. |
| `validation_state_path` | string | yes | absolute path where helper-owned validation state is persisted. |
| `current_validation_attempt` | integer ≥ 1 | yes | 1-based validation attempt counter. |
| `prior_validation_notes` | object | yes | prior validation notes including prior GAPS and DEVIATIONS. `{}` on first entry. |
| `prior_helper_outcomes` | object | yes | prior helper outcomes needed to continue the same validation loop deterministically. `{}` on first entry. |
| `validator_output` | string | no | only present on resume after a validator handoff. Verbatim validator report body. |
| `validation_fix_outputs` | string[] | no | only present on resume after a validation-fix batch. One entry per batch handoff in emission order. |
| `review_rerun_result` | object | no | only present on resume after a delegated re-review. The verbatim output of `review-execution-output-non-interactive`. |
| `post_cap_decision` | `"unset" \| "proceed" \| "abort"` | no | required only after the cap is reached; encodes the operator's decision. Defaults to `unset`. |

`additionalProperties: false` on the input.

---

## Output Shape

```json
{
  "status": "success | fix_required | blocked | abort",
  "next_step": "<one of the per-skill tokens below>",
  "notes": "free-form multi-line summary",
  "state_updates": { "...": "..." }
}
```

### Status semantics

| `status` | Meaning |
|---|---|
| `success` | Validator returned `STATUS: PASS` and all prerequisites are satisfied. Caller advances to PR finalization. |
| `fix_required` | `STATUS: FAIL` with actionable GAPS or DEVIATIONS, cap not exhausted. Caller dispatches the validation-fix batch and re-enters with the resumed outputs. |
| `blocked` | Helper cannot continue: missing input, malformed validator report, missing resumed outputs, no actionable fixes for a FAIL report, missing required re-review, or `proceed_decision_required` (post-cap) state. |
| `abort` | Terminal: cap exhausted with `post_cap_decision = abort`, or `post_cap_decision = proceed` (which forces a fresh rerun boundary). |

The internal `waiting_for_handoffs` and `proceed_decision_required` states from `SKILL.md`
are normalized for the Rust caller: `waiting_for_handoffs` is surfaced as `blocked` +
`escalate` (because the Rust caller drives the sub-call dispatch synchronously through
`validator_output`/`validation_fix_outputs`/`review_rerun_result`), and
`proceed_decision_required` is surfaced as `blocked` + `escalate` until
`post_cap_decision` is set, then it deterministically transitions to `abort` +
`terminate`.

### `next_step` (allowed tokens)

| Token | Meaning for the caller |
|---|---|
| `proceed_to_pr` | Validation passed. Caller advances to PR finalization. |
| `dispatch_validation_fix` | A validation-fix batch is ready. Caller dispatches the (≤ 5) handoffs through standard sub-agent dispatch, then re-enters with the resumed outputs. |
| `escalate` | Recoverable blocker. Caller surfaces the blocker, fixes the precondition, and re-enters. |
| `terminate` | Unrecoverable — caller stops the parent loop (cap exhausted with `abort` decision or post-`proceed` rerun boundary). |

### `state_updates` (helper-owned fields)

| Key | Type | Required | Semantics |
|---|---|---|---|
| `validation_report_path` | string | yes | absolute path to the latest persisted validator report JSON (under `execution_root`). One file per attempt; the path always points to the **latest** attempt. |
| `gaps` | array | yes | one entry per **currently unresolved** GAP. Each entry: `{ goal: string, missing_evidence: string }`. Empty array `[]` when validation passed. |

`additionalProperties: false` on `state_updates`.

---

## Failure-Mode Mapping

| Failure scenario | Taxonomy bucket | Contract `status` | `next_step` |
|---|---|---|---|
| `execution_root` not writable | HardInfra | `blocked` | `escalate` |
| Validator output missing on resume | ProtocolViolation | `blocked` | `escalate` |
| Validator report malformed (missing STATUS / GAPS / DEVIATIONS) | ProtocolViolation | `blocked` | `escalate` |
| Required input missing or empty | ProtocolViolation | `blocked` | `escalate` |
| FAIL report with zero actionable fixes | SemanticFailure (deadlock) | `blocked` | `escalate` |
| Validation-fix batch resume incomplete (missing outputs) | ProtocolViolation | `blocked` | `escalate` |
| Required re-review skipped or returned non-clean | ProtocolViolation | `blocked` | `escalate` |
| Validator returned PASS | (success) | `success` | `proceed_to_pr` |
| Validator returned FAIL with actionable items, cap not exhausted | SemanticFailure | `fix_required` | `dispatch_validation_fix` |
| Cap reached, `post_cap_decision = unset` | SemanticFailure (decision required) | `blocked` | `escalate` |
| Cap reached, `post_cap_decision = abort` | SemanticFailure (terminal) | `abort` | `terminate` |
| Cap reached, `post_cap_decision = proceed` | SemanticFailure (rerun boundary) | `abort` | `terminate` |
| Transient I/O on state persistence | TransientInfra | `blocked` | `escalate` |

---

## Examples

### Happy path — validator returns PASS on first attempt

**Input:**

```json
{
  "plan_path": "/abs/plan.md",
  "execution_root": "/abs/exec-root",
  "changed_files": ["crates/foo/src/lib.rs"],
  "language": "rust",
  "recipe_list": ["rust-services:production-code-recipe"],
  "skip_code_review": false,
  "state_file_path": "/abs/exec-root/.tmp-execute-plan-state.json",
  "execution_state": { "phase": "validation" },
  "validation_state": { "phase": "plan_validation", "validation_attempt": 1, "validator_handoff": ".tmp-subtask-plan-validation-attempt-1.md" },
  "validation_state_path": "/abs/exec-root/.tmp-validation-state.json",
  "current_validation_attempt": 1,
  "prior_validation_notes": {},
  "prior_helper_outcomes": {},
  "validator_output": "STATUS: PASS\nIMPLEMENTED:\n- all goals met\nGAPS:\n- none\nDEVIATIONS:\n- none\nNOTES:\n- attempt 1 clean"
}
```

**Output:**

```json
{
  "status": "success",
  "next_step": "proceed_to_pr",
  "notes": "validation attempt 1: PASS; 0 gaps, 0 deviations; no fix work needed",
  "state_updates": {
    "validation_report_path": "/abs/exec-root/.tmp-subtask-plan-validation-attempt-1-report.json",
    "gaps": []
  }
}
```

### Fix-required path — validator returns FAIL with actionable gaps

**Input:**

```json
{
  "plan_path": "/abs/plan.md",
  "execution_root": "/abs/exec-root",
  "changed_files": ["crates/foo/src/lib.rs"],
  "language": "rust",
  "recipe_list": [],
  "skip_code_review": false,
  "state_file_path": "/abs/exec-root/.tmp-execute-plan-state.json",
  "execution_state": { "phase": "validation" },
  "validation_state": { "phase": "plan_validation", "validation_attempt": 1, "validator_handoff": ".tmp-subtask-plan-validation-attempt-1.md" },
  "validation_state_path": "/abs/exec-root/.tmp-validation-state.json",
  "current_validation_attempt": 1,
  "prior_validation_notes": {},
  "prior_helper_outcomes": {},
  "validator_output": "STATUS: FAIL\nIMPLEMENTED:\n- handler wired up\nGAPS:\n- G1: plan goal 'expose /healthz' has no implementation evidence\n- G2: plan goal 'emit otel span on auth failure' has no test evidence\nDEVIATIONS:\n- none\nNOTES:\n- attempt 1 found 2 gaps"
}
```

**Output:**

```json
{
  "status": "fix_required",
  "next_step": "dispatch_validation_fix",
  "notes": "validation attempt 1: FAIL with 2 actionable GAPS; emitting batch of 2 validation-fix handoffs (.tmp-subtask-validation-fix-attempt-1-1.md, .tmp-subtask-validation-fix-attempt-1-2.md); re-review will be required after fix pass",
  "state_updates": {
    "validation_report_path": "/abs/exec-root/.tmp-subtask-plan-validation-attempt-1-report.json",
    "gaps": [
      { "goal": "expose /healthz", "missing_evidence": "no implementation in changed files" },
      { "goal": "emit otel span on auth failure", "missing_evidence": "no test asserts on span" }
    ]
  }
}
```

---

## Wire-Format Invariants

1. The output envelope has exactly four top-level keys.
2. `status` ∈ {`success`, `fix_required`, `blocked`, `abort`}.
3. `next_step` ∈ {`proceed_to_pr`, `dispatch_validation_fix`, `escalate`, `terminate`}.
4. `state_updates.validation_report_path` is always present and absolute.
5. `state_updates.gaps` is always present (possibly empty).
6. Each `gaps[]` entry has exactly two keys: `goal`, `missing_evidence`. Both non-empty strings.

---

## Back-test results

**Sampled runs:** 1 real (`773749ab-validation-attempt-1-pass` —
claude-code-proxy CCP-0 plan, `rust`, attempt 1, validator returned `STATUS: PASS`,
pr-finalize was subsequently invoked) + 2 synthetic (one `fix_required` with
2 actionable GAPS, one terminal `abort` after cap exhaustion with
`post_cap_decision = abort`).

**Validation:** all 3 fixtures pass `schemas/input.schema.json` and
`schemas/output.schema.json` with `information_loss: "none"`. Fixture files live
under `back-test/`.

**Schema deltas applied during back-test:** none. The D1.1 schemas accommodated
all observed and synthesized payloads on the first pass.

**Pre-existing contract drift documented:** the historical helper invocation in
`~/.plan-executor/jobs/773749ab-…/output.jsonl` was issued in JSON form (good)
but lacked two fields the new schema marks `required`:

- `current_validation_attempt` (`integer ≥ 1`) — was not passed at all; the
  attempt counter lived inside the natural-language `prior_validation_notes`
  prose string instead of as a typed field.
- `prior_helper_outcomes` (object) — was not passed; review-handoff status was
  also encoded in the prose `prior_validation_notes` string.

In addition, `prior_validation_notes` was passed as a free-form string
(`"Phase 5 code review completed clean on attempt 1 …"`) where the new schema
requires an `object`.

This drift is **intentional**. The new schema makes the validation-attempt
counter and the prior-helper-outcome graph first-class typed inputs so the
Rust caller does not have to parse English prose to drive the loop. The
fixture under `back-test/773749ab-validation-attempt-1-pass.json` records the
typed-equivalent payload: the prose was decomposed into
`current_validation_attempt = 1`, `prior_validation_notes = {prior_phase: "review", review_outcome: "clean"}`,
and `prior_helper_outcomes = {review: {status: "success", attempts: 1}}` —
preserving every piece of information the original run carried.

**Back-test gaps:** only one real historical run invoked this helper as a
`Skill` call in the surveyed corpus. Two of three fixtures are therefore
synthetic and exercise the FAIL-with-gaps path and the post-cap abort path the
real run did not.
