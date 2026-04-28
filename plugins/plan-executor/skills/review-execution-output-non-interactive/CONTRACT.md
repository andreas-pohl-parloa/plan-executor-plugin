# Contract: `review-execution-output-non-interactive`

This document is the wire-level contract between the Rust plan-executor caller and the
`plan-executor:review-execution-output-non-interactive` helper skill. It pins the I/O
contract used by the Rust phase-controller; full prose semantics live in `SKILL.md`.

Schemas: `schemas/input.schema.json` and `schemas/output.schema.json` (JSON Schema 2020-12).

---

## Single Responsibility

**Does:** own the Phase 5 review loop — initialize/persist helper-owned review state,
delegate per-attempt reviewer dispatch and triage to
`plan-executor:run-reviewer-team-non-interactive`, accumulate triage history, request
fix-wave generation through `plan-executor compile-fix-waves`, enforce the 3-attempt
review cap, and return a single deterministic verdict to the caller per invocation.

**Does NOT:**

- write production, test, fix, or validation-fix code,
- duplicate the per-batch triage logic of `run-reviewer-team-non-interactive`,
- emit per-finding fix prompt files (fix waves come from `compile-fix-waves`),
- own validation state or PR finalization,
- decide the next phase — it returns a verdict; the orchestrator decides the next phase.

---

## Input Shape

| Field | Type | Required | Semantics |
|---|---|---|---|
| `plan_path` | string | yes | absolute plan path. |
| `execution_root` | string | yes | absolute execution root. Must exist and be writable. |
| `changed_files` | string[] | yes | files created or modified during execution. May be empty. |
| `language` | `"typescript" \| "python" \| "go" \| "rust" \| "unknown"` | yes | resolved language for the changed code. |
| `recipe_list` | string[] | yes | recipe skills relevant to the changed code. May be `[]`. |
| `skip_code_review` | boolean | yes | when `true`, the caller must bypass this helper entirely; when this helper is invoked with `true` it returns `blocked` (orchestrator bypass violation). |
| `state_file_path` | string | yes | absolute path to the orchestrator's `.tmp-execute-plan-state.json`. |
| `execution_state` | object | yes | current persisted orchestrator state snapshot. |
| `review_state` | object \| null | yes | current persisted helper-owned review state. `null` on the first entry. |
| `review_state_path` | string | yes | absolute path where helper-owned review state is persisted. |
| `prior_review_notes` | object | yes | accumulated triage history, fix history, and reviewer set from prior attempts. `{}` on first entry. |
| `reviewer_team_result` | object | no | only present on resume after a sub-call to `run-reviewer-team-non-interactive` returned. The verbatim output of that helper. |
| `compile_fix_waves_result` | object | no | only present on resume after invoking the `plan-executor compile-fix-waves` CLI. Contains `exit_code: integer` and `appended_fix_wave_ids: integer[]` and `stderr: string`. |

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
| `success` | Review finished cleanly: no unresolved `FIX_REQUIRED` items at the end of an attempt. Caller advances to validation. |
| `fix_required` | Findings remain. Caller must dispatch the appended fix-waves through standard wave execution and re-enter this helper. |
| `blocked` | Helper cannot continue: missing input, inconsistent persisted state, missing required reviewer outputs, `compile-fix-waves` CLI failed, regression-verification missing, or orchestrator bypass violation. |
| `abort` | Terminal: review cap (3 attempts) exhausted with unresolved `FIX_REQUIRED` items. |

The internal `waiting_for_handoffs` state from `SKILL.md` is mapped onto `success`+`proceed_to_validation`
**only after** triage completes. Mid-loop `waiting_for_handoffs` propagates to the caller as
`status: blocked` + `next_step: escalate` because the Rust caller drives sub-call
dispatch synchronously through `reviewer_team_result`/`compile_fix_waves_result` re-entry.

### `next_step` (allowed tokens)

| Token | Meaning for the caller |
|---|---|
| `proceed_to_validation` | Review loop is clean. Advance to validation. |
| `dispatch_fix_wave` | One or more fix-waves were appended to `tasks.json`. Caller dispatches them through standard wave execution, then re-enters with refreshed `prior_review_notes` and `review_state`. |
| `escalate` | Recoverable blocker. Caller surfaces the blocker, fixes the precondition, and re-enters. |
| `terminate` | Unrecoverable — caller stops the parent loop (review cap exhausted or terminal blocker). |

### `state_updates` (helper-owned fields)

| Key | Type | Required | Semantics |
|---|---|---|---|
| `triaged_findings_path` | string | yes | absolute path to the JSON file holding the **accumulated** triaged findings list (all attempts). Written under `execution_root`. |
| `wave_id_for_fix` | integer ≥ 100 | optional | when `status = fix_required` and exactly one fix-wave was appended, the wave id. When multiple were appended, this is the **first** id and the `notes` field lists all ids. Omitted when no fix-wave was appended. |

`additionalProperties: false` on `state_updates`.

---

## Failure-Mode Mapping

| Failure scenario | Taxonomy bucket | Contract `status` | `next_step` |
|---|---|---|---|
| `execution_root` not writable | HardInfra | `blocked` | `escalate` |
| `state_file_path` unreadable / corrupt JSON | HardInfra | `blocked` | `escalate` |
| Transient I/O on state persistence | TransientInfra | `blocked` | `escalate` |
| Required input missing or empty | ProtocolViolation | `blocked` | `escalate` |
| `skip_code_review = true` (orchestrator bypass) | ProtocolViolation | `blocked` | `escalate` |
| `reviewer_team_result` returned `status: blocked` | ProtocolViolation | `blocked` | `escalate` |
| `compile_fix_waves_result.exit_code != 0` | TransientInfra | `blocked` | `escalate` |
| Missing regression-verification on resume after fix | ProtocolViolation | `blocked` | `escalate` |
| Triage produced no `FIX_REQUIRED` items | (success) | `success` | `proceed_to_validation` |
| Triage produced `FIX_REQUIRED` items, cap not reached | SemanticFailure | `fix_required` | `dispatch_fix_wave` |
| Cap exhausted with unresolved `FIX_REQUIRED` items | SemanticFailure (terminal) | `abort` | `terminate` |

---

## Examples

### Happy path — review clean on first attempt

**Input:**

```json
{
  "plan_path": "/abs/plan.md",
  "execution_root": "/abs/exec-root",
  "changed_files": ["crates/foo/src/lib.rs"],
  "language": "rust",
  "recipe_list": ["rust-services:production-code-recipe", "rust-services:test-code-recipe"],
  "skip_code_review": false,
  "state_file_path": "/abs/exec-root/.tmp-execute-plan-state.json",
  "execution_state": { "phase": "review", "wave": 2 },
  "review_state": null,
  "review_state_path": "/abs/exec-root/.tmp-review-state.json",
  "prior_review_notes": {},
  "reviewer_team_result": {
    "status": "success",
    "next_step": "proceed",
    "notes": "attempt 1: 0 findings",
    "state_updates": {
      "findings_path": "/abs/exec-root/.tmp-subtask-review-attempt-1-findings.json",
      "reviewer_runs": [
        { "reviewer": "claude",   "exit_code": 0, "findings_count": 0 },
        { "reviewer": "codex",    "exit_code": 0, "findings_count": 0 },
        { "reviewer": "gemini",   "exit_code": 0, "findings_count": 0 },
        { "reviewer": "security", "exit_code": 0, "findings_count": 0 }
      ]
    }
  }
}
```

**Output:**

```json
{
  "status": "success",
  "next_step": "proceed_to_validation",
  "notes": "review attempt 1 clean: 0 FIX_REQUIRED, 0 verified, 0 rejected, 0 deferred; reviewer set frozen as [claude, codex, gemini, security:big-toni]",
  "state_updates": {
    "triaged_findings_path": "/abs/exec-root/.tmp-review-triaged-findings.json"
  }
}
```

### Fix-required path — first attempt, fix-waves appended

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
  "execution_state": { "phase": "review", "wave": 2 },
  "review_state": null,
  "review_state_path": "/abs/exec-root/.tmp-review-state.json",
  "prior_review_notes": {},
  "reviewer_team_result": {
    "status": "fix_required",
    "next_step": "dispatch_fix_wave",
    "notes": "attempt 1: 2 FIX_REQUIRED",
    "state_updates": {
      "findings_path": "/abs/exec-root/.tmp-subtask-review-attempt-1-findings.json",
      "reviewer_runs": [
        { "reviewer": "claude",   "exit_code": 0, "findings_count": 1 },
        { "reviewer": "codex",    "exit_code": 0, "findings_count": 0 },
        { "reviewer": "gemini",   "exit_code": 0, "findings_count": 0 },
        { "reviewer": "security", "exit_code": 0, "findings_count": 1 }
      ]
    }
  },
  "compile_fix_waves_result": {
    "exit_code": 0,
    "appended_fix_wave_ids": [100, 101],
    "stderr": ""
  }
}
```

**Output:**

```json
{
  "status": "fix_required",
  "next_step": "dispatch_fix_wave",
  "notes": "attempt 1: 2 FIX_REQUIRED items appended as fix-waves [100, 101]; reviewer set frozen as [claude, codex, gemini, security:big-toni]",
  "state_updates": {
    "triaged_findings_path": "/abs/exec-root/.tmp-review-triaged-findings.json",
    "wave_id_for_fix": 100
  }
}
```

---

## Wire-Format Invariants

1. The output envelope has exactly four top-level keys.
2. `status` ∈ {`success`, `fix_required`, `blocked`, `abort`}.
3. `next_step` ∈ {`proceed_to_validation`, `dispatch_fix_wave`, `escalate`, `terminate`}.
4. `state_updates.triaged_findings_path` is always present and points to an absolute path under `execution_root`.
5. `state_updates.wave_id_for_fix` is present **only** when `status = fix_required`.
6. The `triaged_findings_path` file is monotonically appended across attempts; it is not truncated between re-entries.

---

## Back-test results

**Sampled runs:** 1 real (`da39f0e5-review-attempt-1-clean` — claude-code-proxy
CCP-0 plan, `rust`, attempt 1, clean) + 2 synthetic (one `fix_required` with
`compile_fix_waves_result` resume, one `abort` for review-cap exhaustion).

**Validation:** all 3 fixtures pass `schemas/input.schema.json` and
`schemas/output.schema.json` with `information_loss: "none"`. Fixture files live
under `back-test/`.

**Schema deltas applied during back-test:** none. The D1.1 schemas accommodated
all observed and synthesized payloads on the first pass.

**Pre-existing contract drift documented:** the historical helper invocation in
`~/.plan-executor/jobs/da39f0e5-…/output.jsonl` was issued in the kv-string form
and lacked four fields the new schema marks `required`:

- `execution_state` (object) — was not passed in the kv form at all.
- `review_state` (`object | null`) — was not passed.
- `review_state_path` (string) — was not passed.
- `prior_review_notes`: passed as `"none"` (string) instead of an object.

In addition, `changed_files` and `recipe_list` were comma-joined strings and
`skip_code_review` was the string `"false"`. Those are type errors against the
new schema.

This drift is **intentional**. The new schema describes the contract for the
Rust caller's structured-I/O envelope, not the legacy natural-language form.
The fixture under `back-test/da39f0e5-review-attempt-1-clean.json` records the
typed-equivalent payload — i.e. the real run normalized to the structured
schema — and keeps the same semantic information that flowed through the
legacy kv invocation plus the additional state-tracking fields the new
contract requires.

**Back-test gaps:** only one real historical run invoked this helper as a
`Skill` call in the surveyed corpus. Two of three fixtures are therefore
synthetic and exercise paths the real run did not (fix-required with
`compile_fix_waves_result`, terminal abort).
