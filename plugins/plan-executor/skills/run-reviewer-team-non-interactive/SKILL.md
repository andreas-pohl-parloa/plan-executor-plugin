---
name: plan-executor:run-reviewer-team-non-interactive
description: "EXECUTOR ONLY — do NOT use in direct user conversations or interactive sessions. Called exclusively by plan-executor:execute-plan-non-interactive and plan-executor:review-execution-output-non-interactive orchestrators. For interactive reviewer runs use plan-executor:run-reviewer-team instead."
---

**CRITICAL — FORBIDDEN TOOLS: You MUST NOT use the `Agent` tool, `Task` tool, or any sub-agent spawning tool under any circumstances. You MUST NOT use `AskUserQuestion`. All sub-agent work MUST go through the file-based handoff protocol: write prompt files, update state, print `call sub-agent` lines, and STOP. The external executor dispatches sub-agents — you never do. Using the Agent tool is an execution failure that corrupts the handoff protocol.**

# Run Reviewer Team Non-Interactive

Non-interactive counterpart of `plan-executor:run-reviewer-team`. It does the same work — freeze four reviewers, build prompts, collect outputs, triage — but uses the file-based handoff protocol instead of launching sub-agents directly.

It does NOT decide whether to fix, retry, or escalate. That logic belongs to the caller.

## Required Inputs

- `plan_context` — plan path or relevant plan excerpts that define the expected implementation
- `execution_outputs` — description or summary of what was built or changed during execution
- `changed_files` — list of files created or modified
- `language` — detected primary language of the changed files
- `recipe_list` — recipe skills relevant to the changed code (used to build reviewer prompts)
- `prior_review_context` — prior triage history for this review loop; must include already-fixed, rejected, and deferred findings so reviewers do not re-raise resolved items; pass empty object `{}` on the first run
- `execution_root` — absolute path to the directory where prompt files are written (worktree root or repo root)
- `attempt` — 1-based integer; used in prompt-file names to prevent clobbering across retry loops

If any required input is missing, stop immediately and return `status: blocked` with the missing field in `notes`.

## Mode Detection

This skill operates in two modes depending on whether reviewer outputs have been provided.

**Dispatch mode** — no reviewer outputs present: write prompt files, emit handoffs, return `status: waiting_for_handoffs`.

**Triage mode** — the Claude output block (required) is present: parse outputs, triage findings, return `status: complete`. Can-fail reviewer blocks (Codex, Gemini, Security) are optional.

Do not enter triage mode if the required Claude output block is missing; return `status: blocked` in that case.

## Reviewer Set

The frozen reviewer set for every invocation is exactly four reviewers:

1. **Claude** — handoff type `claude` — **required** (job fails if this reviewer fails)
2. **Codex** — handoff type `codex` — **can-fail** (job continues without output if this reviewer fails)
3. **Gemini** — handoff type `gemini` — **can-fail** (job continues without output if this reviewer fails)
4. **Security** — handoff type `claude`, uses `security:big-toni` — **required** (job fails if this reviewer fails)

Reducing the set below four or replacing a reviewer with a generic fallback is forbidden. If any reviewer prompt file cannot be written, return `status: blocked` with the reason in `notes`.

## Prompt-File Naming

Write exactly one prompt file per reviewer using the review naming pattern from the handoff protocol:

- `.tmp-subtask-review-attempt-<attempt>-claude.md`
- `.tmp-subtask-review-attempt-<attempt>-codex.md`
- `.tmp-subtask-review-attempt-<attempt>-gemini.md`
- `.tmp-subtask-review-attempt-<attempt>-security.md`

All files are written to `execution_root`.

## Reviewer Prompt Contract

Build one prompt per reviewer. Each prompt must include:

- the review scope: changed files, plan context, execution summary
- language and recipe context
- prior review context: already-fixed findings, rejected findings, deferred findings
- the reporting contract below

**Security reviewer prompt exception:** The security reviewer prompt (index 4) MUST begin with `/security:big-toni` as the first line, followed by the review scope and changed files. It does NOT receive the standard recipe list or language context — `security:big-toni` determines its own methodology. It MUST still receive the prior review context and the reporting contract below so it does not re-raise already-resolved findings.

**Reporting contract to include in every reviewer prompt:**

> Report only findings within the current review scope. For each finding include: file path, line reference if applicable, a concrete description, and your reasoning. Classify every finding as one of:
> - `FIX_REQUIRED` — real, in-scope, must be fixed
> - `VERIFIED_FIX` — a prior FIX_REQUIRED issue that is now correctly fixed
> - `REJECTED` — invalid, out of scope, or based on incorrect assumptions
> - `DEFERRED` — real but intentionally left unresolved (must state reason)
>
> Do not re-raise findings already marked fixed, rejected, or deferred in prior review context unless you have new evidence that invalidates the prior decision. Do not make code changes directly.

## Execution

### Dispatch Mode

1. Validate all required inputs are present.
2. Build one reviewer prompt per reviewer using the contract above.
3. Write the four prompt files to `execution_root`.
4. Emit exactly four handoff lines in a single batch using the format from the handoff protocol:
   ```
   call sub-agent 1 (agent-type: claude): <execution_root>/.tmp-subtask-review-attempt-<attempt>-claude.md
   call sub-agent 2 (agent-type: codex, can-fail: true): <execution_root>/.tmp-subtask-review-attempt-<attempt>-codex.md
   call sub-agent 3 (agent-type: gemini, can-fail: true): <execution_root>/.tmp-subtask-review-attempt-<attempt>-gemini.md
   call sub-agent 4 (agent-type: claude): <execution_root>/.tmp-subtask-review-attempt-<attempt>-security.md
   ```
5. Return `status: waiting_for_handoffs`.

### Triage Mode

1. Require exactly one `# output sub-agent <N>:` block for Claude (index 1). If this block is missing, return `status: blocked`.
2. Codex (index 2) and Gemini (index 3) output blocks are optional. A missing block for a can-fail reviewer means that reviewer's output is absent — treat it as contributing zero findings. A duplicated or unexpected index still triggers `status: blocked`.
3. Security (index 4) output block is required. If this block is missing, return `status: blocked`.
4. Triage every finding from every reviewer into exactly one bucket:
   - `FIX_REQUIRED`
   - `VERIFIED_FIX`
   - `REJECTED`
   - `DEFERRED`
   - Deduplicate across reviewers: if multiple reviewers raise the same issue, merge into one finding and note that N reviewers agreed.
5. Apply triage rules per bucket:
   - `FIX_REQUIRED` items remain active until promoted to `VERIFIED_FIX`, reclassified to `REJECTED`, or reclassified to `DEFERRED` with documented rationale.
   - `VERIFIED_FIX` items must retain the original finding identity and verification evidence.
   - `REJECTED` items must retain the rejection rationale.
   - `DEFERRED` items must retain the documented owner or follow-up requirement.
6. Produce the review report (see Completion Contract).

## Completion Contract

### `status: waiting_for_handoffs`

Return after emitting the prompt-file batch. Include:

- `status: waiting_for_handoffs`
- `reviewer_set` — the frozen list of four reviewers used for this batch (caller must persist this)
- `next_step`: provide one `# output sub-agent <N>:` block for each emitted handoff, then re-invoke this skill in triage mode
- `notes`: emitted batch metadata, attempt number, and absolute prompt-file paths

### `status: complete`

Return after successful triage. Include:

- `status: complete`
- `reviewer_set` — list of the four reviewers used
- `attempt_note` — free-text note about this run (e.g. first attempt, retry N)
- `findings` — list of triaged findings; each entry:
  - `id` — short unique identifier (e.g. `F1`, `F2`)
  - `category` — one of `FIX_REQUIRED` | `VERIFIED_FIX` | `REJECTED` | `DEFERRED`
  - `file` — affected file path
  - `description` — concrete description of the finding
  - `reasoning` — reviewer reasoning
  - `reviewers` — which reviewer(s) raised this finding
  - `deferred_reason` — populated only for `DEFERRED`
- `triage_summary` — counts per category: `fix_required`, `verified_fix`, `rejected`, `deferred`
- `notes` — any blocker detail, tool errors, or observations

### `status: blocked`

Return when required inputs are missing, prompt files cannot be written, or the resumed batch is incomplete. Include:

- `status: blocked`
- `next_step`: provide the missing input or corrected output blocks, then re-invoke this skill
- `notes`: exact blocker and minimum corrective action required
