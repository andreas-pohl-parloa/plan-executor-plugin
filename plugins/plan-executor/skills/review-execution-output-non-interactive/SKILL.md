---
name: plan-executor:review-execution-output-non-interactive
description: "EXECUTOR ONLY — do NOT use in direct user conversations or interactive sessions. Called exclusively by plan-executor:execute-plan-non-interactive orchestrator during Phase 5 code review. For interactive review use plan-executor:review-execution-output instead."
---

**CRITICAL — FORBIDDEN TOOLS: You MUST NOT use the `Agent` tool, `Task` tool, or any sub-agent spawning tool under any circumstances. You MUST NOT use `AskUserQuestion`. All sub-agent work MUST go through the file-based handoff protocol: write prompt files, update state, print `call sub-agent` lines, and STOP. The external executor dispatches sub-agents — you never do. Using the Agent tool is an execution failure that corrupts the handoff protocol.**

# Review Execution Output Non-Interactive

This helper runs the non-interactive execute-plan Phase 5 review loop.

It runs in the same agent as the non-interactive orchestrator. It owns review-state persistence, the review loop, fix-handoff generation, regression verification requirements, and review-cap enforcement. Reviewer dispatch and per-batch triage are fully delegated to `plan-executor:run-reviewer-team-non-interactive`.

Execution orchestration state remains orchestrator-owned. Review state remains helper-owned and separate from execution orchestration state and helper-owned validation state.

## Required Inputs

The orchestrator must pass, at minimum:

- `plan_path` — absolute plan path
- `execution_root` — absolute execution root
- `changed_files` — files created or modified during execution
- `language` — detected language for the changed code
- `recipe_list` — recipe skills relevant to the changed code
- `skip_code_review` — explicit review-skip flag
- `state_file_path` — absolute path to `.tmp-execute-plan-state.json`
- `execution_state` — current persisted orchestrator state
- `review_state` — current persisted helper-owned review state, if any
- `review_state_path` — persisted helper-owned review-state path when review state is stored outside the immediate payload
- `prior_review_notes` — prior review findings, triage notes, and fix history

If any required input is missing, unreadable, or inconsistent with persisted state, stop and return `status: blocked`.

## Core Mode Contract

- This helper runs only in the same agent as `plan-executor:execute-plan-non-interactive`.
- This helper never writes implementation code, test code, review fixes, or validation fixes.
- This helper owns all Phase 5 review-state decisions, the loop structure, fix-handoff generation, and the retry cap.
- Reviewer dispatch (prompt-file writing, handoff emission) and per-batch triage are fully delegated to `plan-executor:run-reviewer-team-non-interactive` — do not duplicate its reviewer prompt contract, reviewer-set freezing, or triage logic here.
- `execute-plan-non-interactive/HANDOFF_PROTOCOL.md` remains transport-only. This helper must follow its naming and continuation rules without redefining transport semantics.
- Persist helper-owned state before every stop that waits for external handoff output.
- Reread helper-owned state and orchestrator state before parsing resumed outputs.
- Persisted review metadata must include, when relevant, `skill_version`, `current_phase`, `current_attempt`, and the frozen reviewer set (as returned by `plan-executor:run-reviewer-team-non-interactive`).

## Responsibilities

1. **Own review-state initialization and persistence.**
   - Initialize helper-owned review state on first entry.
   - Persist state before every stop. Reread state before every resume.
   - State must include: current attempt, frozen reviewer set (once available), triage history, fix-handoff metadata, and regression-verification status.

2. **Delegate reviewer dispatch to `plan-executor:run-reviewer-team-non-interactive`.**
   - On each review attempt, invoke `plan-executor:run-reviewer-team-non-interactive` in dispatch mode by passing all required inputs: `plan_context`, `execution_outputs`, `changed_files`, `language`, `recipe_list`, `prior_review_context` (accumulated triage history), `execution_root`, and the current `attempt` number.
   - Store the frozen reviewer set returned by `plan-executor:run-reviewer-team-non-interactive` in helper-owned state on the first attempt.
   - On resume, invoke `plan-executor:run-reviewer-team-non-interactive` in triage mode by providing the three reviewer output blocks. Merge the returned `findings` and `triage_summary` into helper-owned review state.
   - If `plan-executor:run-reviewer-team-non-interactive` returns `status: blocked`, propagate as `status: blocked` with the delegated reason in `notes`.

3. **Delegate fix-wave generation to `plan-executor compile-fix-waves`.**
   - When unresolved `FIX_REQUIRED` findings remain, do NOT write per-finding fix prompt files yourself. Instead:
     1. Serialize the unresolved `FIX_REQUIRED` findings as a JSON document conforming to `findings.schema.json` (one entry per finding; each with `id`, `severity`, `category`, `description`, optional `files`, optional `suggested_fix`). Do NOT include `VERIFIED_FIX`, `REJECTED`, or `DEFERRED` items in the document — those are carried forward only in helper-owned state.
     2. Write the document to `<execution_root>/findings-round-<attempt>.json` using a write-tmp-then-rename pattern when the available tooling supports it.
     3. Invoke the CLI: `plan-executor compile-fix-waves --plan <plan_path> --execution-root <execution_root> --findings-json <findings-path>`. The CLI rewrites `<execution_root>/tasks.json` in place, appending new fix-waves (IDs ≥ 100, `kind: "fix"`) that address the findings. On success the CLI prints the updated manifest path to stdout and exits 0; on failure it prints `ERROR: <message>` to stderr and exits non-zero.
     4. If the CLI exits non-zero, return `status: blocked` with the CLI's stderr captured in `notes` and the corrective action required (typically: re-run after fixing the underlying issue surfaced by the CLI).
     5. On success, parse the rewritten manifest to extract the new fix-wave IDs (those with `id >= 100` and `kind == "fix"` not present in the prior persisted snapshot). Persist them in helper-owned state under `appended_fix_wave_ids` for the current attempt.
   - The orchestrator's standard wave-execution flow (Phase 3) dispatches the new fix-waves. This helper does NOT emit per-finding handoff lines for fix work; it only signals that fix-waves were appended.
   - Subprocess hygiene for fix-task prompts is now embedded by the `plan-executor:compile-plan` skill's APPEND-mode prompt-file generation. This helper no longer inlines the hygiene block.

4. **Own the review cap and deterministic stop behavior.**
   - Maximum review attempts per Phase 5 run: 3.
   - Stop immediately after delegating a review batch or emitting a fix-handoff batch.
   - Stop immediately on missing inputs, invalid persisted state, incomplete continuation payload, or terminal review result.

5. **Own regression verification requirements.**
   - After a delegated fix pass completes, require explicit regression verification before re-entering the next review attempt. Regression verification means rerunning the required review-relevant checks for the touched files or workflow and persisting the verification outcome in `state_updates` before re-invoking `plan-executor:run-reviewer-team-non-interactive`.

## Triage Persistence Contract

This helper owns accumulated triage state across attempts. It does not re-implement per-batch triage — that is `plan-executor:run-reviewer-team-non-interactive`'s responsibility. It does:

- Merge each batch result into the running triage history.
- Never silently resurrect `REJECTED` or `DEFERRED` findings without new evidence recorded in state.
- Pass the full accumulated triage history as `prior_review_context` on every invocation of `plan-executor:run-reviewer-team-non-interactive`.

Each finding persisted in helper-owned state must be in exactly one bucket:

- `FIX_REQUIRED` — accepted, in-scope, unresolved, and must be fixed before review can complete cleanly
- `VERIFIED_FIX` — a prior `FIX_REQUIRED` item is now fixed and verified
- `REJECTED` — invalid, out of scope, duplicate, or based on incorrect assumptions
- `DEFERRED` — real but intentionally left unresolved for a documented follow-up

## Review Loop

1. Validate required inputs against persisted orchestrator state.
2. This helper runs only when `skip_code_review=false`. If review is skipped by plan type, the orchestrator must bypass this helper entirely.
3. Initialize or reread helper-owned review state.
4. Invoke `plan-executor:run-reviewer-team-non-interactive` in dispatch mode. Stop and return `status: waiting_for_handoffs`.
5. On resume, reread helper-owned state and orchestrator state before processing reviewer outputs.
6. Invoke `plan-executor:run-reviewer-team-non-interactive` in triage mode with the three reviewer output blocks. Merge the result into helper-owned review state.
7. If no unresolved `FIX_REQUIRED` items remain, return `status: success`.
8. If the helper detects orchestrator bypass or missing required reviewer outputs without a helper-owned blocked reason, return `status: blocked`.
9. If unresolved `FIX_REQUIRED` items remain and the cap is not exhausted, follow Section 3: serialize findings, invoke `plan-executor compile-fix-waves`, persist the appended fix-wave IDs in helper-owned state, and return `status: fix_required`. The orchestrator dispatches the new fix-waves through standard wave execution; this helper does not emit per-finding handoffs.
10. After the delegated fix pass completes, require regression verification before re-entering step 4 for the next attempt.
11. If the helper cannot continue deterministically, return `status: blocked`.
12. If the retry cap is exhausted and unresolved `FIX_REQUIRED` items remain, return `status: abort` with deterministic stop notes.

## Deterministic Result Contract

The helper must return exactly one result object with:

- `status`
- `next_step`
- `notes`
- `state_updates`

Allowed `status` values:

- `success`
- `fix_required`
- `waiting_for_handoffs`
- `blocked`
- `abort`

### `status: success`
Use when review is complete and no unresolved `FIX_REQUIRED` items remain.

- `next_step`: proceed to non-interactive execute-plan Phase 6
- `notes`: reviewer set, attempt count, triage summary, and any non-blocking review notes
- `state_updates`: authoritative review-state persistence, including frozen reviewers and final triage snapshot

### `status: fix_required`
Use when accepted findings require fix work. Fix-wave generation is delegated to `plan-executor compile-fix-waves`; this helper records that fix-waves were appended to the manifest and returns control to the orchestrator.

- `next_step`: dispatch the newly-appended fix-waves through the orchestrator's standard wave-execution flow, persist resulting execution output, then re-enter this helper for the next review attempt
- `notes`: list of new fix-wave IDs appended (e.g. `[100, 101]`), attempt count, and one entry per unresolved `FIX_REQUIRED` finding with its affected files and verification context
- `state_updates`: authoritative review-state persistence, including attempt counters, per-issue active findings, and the appended fix-wave IDs under `appended_fix_wave_ids`

### `status: waiting_for_handoffs`
Use when `plan-executor:run-reviewer-team-non-interactive` has been invoked in dispatch mode and the helper must stop for the full reviewer batch output.

- `next_step`: provide one output block for each emitted reviewer handoff, then continue non-interactive execution
- `notes`: emitted batch metadata, frozen reviewer set, and continuation requirements
- `state_updates`: authoritative review-state persistence, including current attempt, batch metadata, and expected handoffs

### `status: blocked`
Use when the helper cannot continue because required inputs, persisted state, continuation data, or a delegated skill result are insufficient or inconsistent.

- `next_step`: provide the missing or corrected input/state, then re-enter Phase 5
- `notes`: exact blocker and the minimum corrective action required
- `state_updates`: any safe persistence needed to preserve the blocker context without advancing review

### `status: abort`
Use when deterministic review cannot continue, including review-cap exhaustion with unresolved `FIX_REQUIRED` items.

- `next_step`: stop execution or restart Phase 5 from a new orchestrator decision point with explicitly updated state
- `notes`: unresolved findings, attempt count, stop reason, and exact condition that caused termination
- `state_updates`: final authoritative review-state snapshot for the aborted run
