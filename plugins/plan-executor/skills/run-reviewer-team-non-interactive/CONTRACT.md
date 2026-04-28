# Contract: `run-reviewer-team-non-interactive`

This document is the wire-level contract between the Rust plan-executor caller and the
`plan-executor:run-reviewer-team-non-interactive` helper skill. It is normative for
callers, schema validators, and back-testing tools. The full prose semantics live in
`SKILL.md`; this file pins **only the I/O contract**.

The skill operates in two modes (`Dispatch` and `Triage`) and the caller uses the same
input/output envelope for both. Schemas are at `schemas/input.schema.json` and
`schemas/output.schema.json` (JSON Schema 2020-12).

---

## Single Responsibility

**Does:** for one review iteration, freeze the four-reviewer set (Claude required +
Codex/Gemini can-fail + Security required), build per-reviewer prompt files for the
configured reviewers, hand them off via the file-based protocol, and — on resume —
parse and triage the reviewer output blocks into a deduplicated, bucketed finding list.

**Does NOT:**

- decide whether to retry, fix, or escalate a review iteration (caller's job),
- write production code, test code, fix code, or validation-fix code,
- generate fix waves (the parent `review-execution-output-non-interactive` helper
  delegates that to the `plan-executor compile-fix-waves` CLI),
- persist accumulated review state across iterations (caller owns that),
- run validators or PR finalization steps.

---

## Input Shape

| Field | Type | Required | Semantics |
|---|---|---|---|
| `mode` | `"dispatch" \| "triage"` | yes | which mode the caller wants this invocation to run in. |
| `plan_context` | string | yes | absolute plan path or excerpted plan content used as review anchor. Non-empty. |
| `execution_outputs` | string | yes | summary of what execution produced (commits, file deltas, test results). Non-empty. |
| `changed_files` | string[] | yes | absolute or repo-relative file paths created or modified during execution. May be empty only when `prior_review_context` documents an empty diff. |
| `language` | `"typescript" \| "python" \| "go" \| "rust" \| "unknown"` | yes | resolved primary language for recipe loading. `"unknown"` is allowed and skips recipe loading. |
| `recipe_list` | string[] | yes | caller-provided recipe skill names to merge with the language-mapped list. May be `[]`. |
| `prior_review_context` | object | yes | accumulated triage state from previous attempts. `{}` is allowed only on `attempt = 1`. |
| `execution_root` | string | yes | absolute path where prompt files are written. Must exist and be writable. |
| `attempt` | integer ≥ 1 | yes | 1-based retry counter — used in prompt-file names to prevent clobbering. |
| `reviewer_outputs` | object | only in `triage` mode | parsed reviewer output blocks. Required keys: `claude` (string), `security` (string). Optional: `codex`, `gemini`. |

`additionalProperties: false` on the input.

---

## Output Shape

Every invocation returns the four-field envelope:

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
| `success` | Triage complete; no `FIX_REQUIRED` items remain. Caller may advance. |
| `fix_required` | Triage complete; one or more `FIX_REQUIRED` items remain. Caller must dispatch a fix wave. |
| `blocked` | Helper cannot continue: missing input, security reviewer slot empty, prompt files unwritable, missing required reviewer output, or duplicated/out-of-order output index. |
| `abort` | Terminal stop — reviewer set cannot be frozen at all (e.g. neither `security:big-toni` nor `plan-executor:lite-security-reviewer` is available **and** the caller has no fallback policy). |

Note: the dispatch-mode `waiting_for_handoffs` semantics from `SKILL.md` are mapped onto
`status: success` + `next_step: proceed` in this contract, because the contract surface
exposed to the Rust caller does not distinguish "waiting for handoffs" from "done" — the
caller inspects the emitted `call sub-agent` lines on stdout and decides whether to wait.
Translation table:

| `SKILL.md` internal status | Contract `status` | Contract `next_step` |
|---|---|---|
| `waiting_for_handoffs` (dispatch mode) | `success` | `proceed` |
| `complete` with no FIX_REQUIRED | `success` | `proceed` |
| `complete` with FIX_REQUIRED | `fix_required` | `dispatch_fix_wave` |
| `blocked` (recoverable) | `blocked` | `escalate` |
| terminal (no security reviewer at all) | `abort` | `terminate` |

### `next_step` (allowed tokens)

| Token | Meaning for the caller |
|---|---|
| `proceed` | Either the dispatch batch was emitted (caller must consume the four output blocks and re-invoke in `triage` mode), or triage finished cleanly (caller advances the parent loop). |
| `dispatch_fix_wave` | Triage produced unresolved `FIX_REQUIRED` items. Caller's review-loop helper must serialize findings, invoke `compile-fix-waves`, and dispatch new fix-waves. |
| `escalate` | Recoverable blocker — caller should surface the blocker to the orchestrator's blocked-input handler and re-enter once corrected. |
| `terminate` | Unrecoverable — caller stops the parent loop. |

### `state_updates` (helper-owned fields)

| Key | Type | Required | Semantics |
|---|---|---|---|
| `findings_path` | string | yes | absolute path to the JSON serialization of the triaged findings list for this attempt. Written under `execution_root`. In dispatch mode this points to a placeholder file the helper creates with `findings: []`. |
| `reviewer_runs` | array | yes | one entry per reviewer slot in the frozen set. Each entry: `{ reviewer: "claude" \| "codex" \| "gemini" \| "security", exit_code: integer, findings_count: integer ≥ 0 }`. In dispatch mode all `exit_code` values are `0` and `findings_count` values are `0`. |

`additionalProperties: false` on `state_updates`.

---

## Failure-Mode Mapping

| Failure scenario | Taxonomy bucket | Contract `status` | `next_step` |
|---|---|---|---|
| `execution_root` not writable / `EROFS` / `ENOSPC` | HardInfra | `blocked` | `escalate` |
| Prompt-file write fails on transient I/O (`EAGAIN`) | TransientInfra | `blocked` | `escalate` |
| Required input missing (e.g. `plan_context = ""`) | ProtocolViolation | `blocked` | `escalate` |
| Required `reviewer_outputs.claude` missing in triage mode | ProtocolViolation | `blocked` | `escalate` |
| Duplicated `# output sub-agent N:` block index | ProtocolViolation | `blocked` | `escalate` |
| Reviewer raised valid `FIX_REQUIRED` finding | SemanticFailure | `fix_required` | `dispatch_fix_wave` |
| Triage finds no `FIX_REQUIRED` items | (success) | `success` | `proceed` |
| Neither `security:big-toni` nor `lite-security-reviewer` available | HardInfra | `abort` | `terminate` |

`HardInfra` and `TransientInfra` always surface as `blocked` so the caller's job-runner
can route them to its retry/backoff policy. Only the genuinely unrecoverable case (no
security reviewer skill at all) maps to `abort`.

---

## Examples

### Happy path — dispatch (no findings yet to triage)

**Input:**

```json
{
  "mode": "dispatch",
  "plan_context": "/abs/path/to/plan.md",
  "execution_outputs": "Wave 2 produced 4 commits across crates/foo and crates/bar.",
  "changed_files": ["crates/foo/src/lib.rs", "crates/bar/src/api.rs"],
  "language": "rust",
  "recipe_list": [],
  "prior_review_context": {},
  "execution_root": "/abs/exec-root",
  "attempt": 1
}
```

**Output:**

```json
{
  "status": "success",
  "next_step": "proceed",
  "notes": "dispatch attempt 1: 4 reviewer prompt files written to /abs/exec-root; security slot = security:big-toni; recipes = [rust-services:production-code-recipe, rust-services:test-code-recipe]",
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
```

### Fix-required path — triage

**Input:**

```json
{
  "mode": "triage",
  "plan_context": "/abs/path/to/plan.md",
  "execution_outputs": "Wave 2 produced 4 commits.",
  "changed_files": ["crates/foo/src/lib.rs"],
  "language": "rust",
  "recipe_list": [],
  "prior_review_context": { "attempts": [], "findings": [] },
  "execution_root": "/abs/exec-root",
  "attempt": 1,
  "reviewer_outputs": {
    "claude":   "FIX_REQUIRED: crates/foo/src/lib.rs:42 — unwrap on Result; replace with ? propagation.",
    "codex":    "no findings",
    "gemini":   "no findings",
    "security": "FIX_REQUIRED: crates/foo/src/lib.rs:58 — secret hardcoded in const."
  }
}
```

**Output:**

```json
{
  "status": "fix_required",
  "next_step": "dispatch_fix_wave",
  "notes": "attempt 1: 2 FIX_REQUIRED findings (1 from claude, 1 from security); 0 verified, 0 rejected, 0 deferred; recipes = [rust-services:production-code-recipe, rust-services:test-code-recipe]",
  "state_updates": {
    "findings_path": "/abs/exec-root/.tmp-subtask-review-attempt-1-findings.json",
    "reviewer_runs": [
      { "reviewer": "claude",   "exit_code": 0, "findings_count": 1 },
      { "reviewer": "codex",    "exit_code": 0, "findings_count": 0 },
      { "reviewer": "gemini",   "exit_code": 0, "findings_count": 0 },
      { "reviewer": "security", "exit_code": 0, "findings_count": 1 }
    ]
  }
}
```

---

## Wire-Format Invariants

These invariants are part of the contract and downstream tasks (D2.1, D2.2) depend on them:

1. The output envelope has exactly four top-level keys (`status`, `next_step`, `notes`, `state_updates`).
2. `status` is one of: `success`, `fix_required`, `blocked`, `abort`. No others.
3. `next_step` is one of: `proceed`, `dispatch_fix_wave`, `escalate`, `terminate`. No others.
4. `state_updates.reviewer_runs` always has length 4 — one entry per frozen slot — even when a can-fail reviewer was missing (its `exit_code` will be non-zero and `findings_count = 0`).
5. `state_updates.findings_path` is always present. In dispatch mode it points to a freshly created empty findings file so the caller can `stat` it unconditionally.

---

## Back-test results

**Sampled runs:** 1 real (`da39f0e5-attempt-1-dispatch` — claude-code-proxy CCP-0 plan,
`rust`, dispatch mode, attempt 1) + 2 synthetic (one `triage` mode `fix_required`,
one `triage` mode `blocked` for missing security reviewer output).

**Validation:** all 3 fixtures pass `schemas/input.schema.json` and
`schemas/output.schema.json` with `information_loss: "none"`. Fixture files live
under `back-test/`.

**Schema deltas applied during back-test:** none. The D1.1 schemas accommodated
all observed and synthesized payloads on the first pass.

**Pre-existing contract drift documented:** historical helper invocations in
`~/.plan-executor/jobs/` were issued in a kv-string form
(`changed_files=a.rs,b.rs attempt=1 prior_review_context=none`) — those raw
strings would fail the new structured schema with at least four type-mismatch
violations:

- `changed_files`: comma-joined string, schema requires `array`.
- `recipe_list`: comma-joined string, schema requires `array`.
- `attempt`: string `"1"`, schema requires `integer`.
- `prior_review_context`: string `"none"`, schema requires `object`.

This drift is **intentional**. The new schemas are the contract for the Rust
caller in the structured-I/O envelope. The natural-language kv form survives
only as a transitional fixture source; downstream tasks (D2.x) own the
serialization layer that produces strictly-typed payloads. Real fixtures in
`back-test/` are the kv-form values **deserialized to typed equivalents** so the
schema covers the information actually present in historical runs.

**Back-test gaps:** only one real historical run (`da39f0e5`) invoked this
helper as a `Skill` tool call in the surveyed `~/.plan-executor/jobs/` corpus.
Two of the three fixtures are therefore marked `"synthetic": true` to cover
`triage` and `blocked` paths the real run did not exercise. The synthetic
fixtures are derived from the structure of the real input and the
`SKILL.md` semantics, not fabricated wholesale.
