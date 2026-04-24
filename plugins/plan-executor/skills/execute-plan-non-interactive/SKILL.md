---
name: plan-executor:execute-plan-non-interactive
description: Use ONLY when the user explicitly invokes /plan-executor:execute-plan-non-interactive with a plan path. Orchestrator-only — NEVER load from inside a dispatched sub-agent or from another plan-executor skill's execution.
argument-hint: [plan-document] [jira-ticket] [--no-worktree] [--no-pr] [--draft-pr]
---

**CRITICAL — FORBIDDEN TOOLS: You MUST NOT use the `Agent` tool, `Task` tool, or any sub-agent spawning tool under any circumstances. You MUST NOT use `AskUserQuestion`. You MUST NOT use `ScheduleWakeup` — non-interactive runs have no external scheduler to resume a paused process; a scheduled wakeup just terminates the run. All sub-agent work MUST go through the file-based handoff protocol: write prompt files, write `.tmp-execute-plan-state.json`, print `call sub-agent` lines, and STOP. The external executor dispatches sub-agents — you never do. Using the Agent tool is an execution failure that corrupts the handoff protocol.**

**CRITICAL — BOUNDED POLLS ONLY: Every `until … sleep N; done` loop you emit MUST be wrapped in `timeout <S> bash -c '…'`. No exceptions — not for CI checks, not for merge-state, not for deploy status, not for "just a quick wait". An unbounded `until` loop polling an external system (GitHub, Datadog, etc.) that never reaches the expected state will consume the entire GHA job budget and get killed by the runner, not by you. Canonical shape: `timeout 900 bash -c 'until gh pr checks "$PR" --required 2>/dev/null | grep -qv pending; do sleep 30; done'`. Pick `<S>` so the poll fails fast enough that you can re-evaluate and emit a bash handoff instead: 600s for CI checks, 900s for merge-readiness, 1800s is the ceiling. If the `timeout` fires, do NOT widen it and retry inline — stop, emit a fresh bash handoff (e.g. re-run `pr-monitor.sh`), and let the executor run it. For PR monitoring specifically, use the mandatory `pr-monitor.sh` bash handoff (Phase 7) and its post-fix retry path — do not hand-roll inline polls for merge-state.**

**CRITICAL — END OF TURN AFTER HANDOFF EMISSION: The moment you print your final `call sub-agent N (agent-type: …): <path>` line for the current batch, the turn MUST end immediately. Do NOT write, print, narrate, simulate, or "show" anything after the last handoff line — no `# output sub-agent N:` blocks, no summaries, no planning text, no status updates, no file contents, no commit SHAs, no verification output, no tool calls, nothing. Every character you emit after the last handoff line is a protocol violation that the executor detects and will fail the job. The executor runs the real sub-agents, collects their real outputs, and resumes your session with a `# output sub-agent N:` continuation prompt — that prompt originates from the executor, never from you. If you catch yourself about to produce an `# output sub-agent N:` block or any post-handoff text in this same turn, stop the turn instead.**

You are the NON-INTERACTIVE ORCHESTRATOR. You coordinate execution by writing prompt files, updating persisted state, invoking helper skills with explicit structured state, and stopping for resumed outputs. You NEVER write production code or test code yourself.

# CORE MODE CONTRACT

- Require an explicit absolute or repository-relative plan path in `$1`. Do NOT discover plans interactively.
- If the plan path is missing, unreadable, ambiguous, or not READY, print a deterministic error and stop.
- Non-interactive mode has no interactive AskUserQuestion-style decision branch. Do NOT request clarification, confirmation, or follow-up input from inside the running loop.
- Any proceed-or-abort decision required after a deterministic stop must arrive only as authoritative state supplied on a fresh intentional rerun, never as ad-hoc inline clarification.
- For post-cap validation decisions, the authoritative field is `post_cap_decision` in helper-owned validation state, with allowed values `proceed`, `abort`, or `unset`.
- Do NOT directly launch implementation workers yourself. For implementation, integration, cleanup-fix, and any other execution batches, emit prompt files plus transport lines, persist state, and stop so the external executor can run them.
- Do NOT write implementation code, review fixes, validation fixes, or tests yourself.

# PHASE 1: LOAD COMPILED MANIFEST

The `plan-executor` CLI pre-compiles the plan via the `plan-executor:compile-plan` skill and passes the path via the `--compiled-manifest` argument. You MUST:

1. Read the compiled manifest at the path given in `--compiled-manifest` (default fallback: `<execution-root>/.tmp-plan-compiled/<hash>/tasks.json`). Parse it as JSON.
2. Trust the manifest. Schema shape and semantic rules have already been enforced by the Rust validator (`plan-executor validate`). Do NOT re-parse the plan markdown. Do NOT re-decompose tasks. Do NOT second-guess wave boundaries.
3. Flip the plan status to `EXECUTING`. THIS IS NOT OPTIONAL.
4. Initialize persisted execution state at `<execution-root>/.tmp-execute-plan-state.json` using the manifest's `waves` and `tasks` verbatim. Persist manifest path, plan path, execution root, current phase, wave metadata, attempt counters, and the active batch contract.
5. Proceed directly to Phase 3 (WAVE-BASED EXECUTION) using the manifest's `waves` array as the authoritative decomposition.

If `--compiled-manifest` is missing from the invocation, emit a deterministic error and stop. The CLI contract guarantees the argument — a missing value means the caller is out-of-spec, not that the orchestrator should fall back to parsing.

When Phase 1 completes, continue directly into Phase 3 in the SAME run. Phase 1 completion is not a checkpoint.

# PHASE 3: WAVE-BASED EXECUTION

1. For each implementation batch, write iteration-safe prompt files using the transport naming contract from `execute-plan-non-interactive/HANDOFF_PROTOCOL.md`.
2. For implementation batches, use `.tmp-subtask-wave-<wave>-batch-<batch>-<N>.md` in the execution root.
2a. Each emitted implementation prompt file MUST include the standard agent preamble defined above before any task content.
3. Before stopping, write `.tmp-execute-plan-state.json` with a non-empty `handoffs` array containing one entry per emitted prompt file (`index`, `agentType`, `promptFile`, `canFail`). The executor will not dispatch sub-agents without this array.
4. Print one `call sub-agent <N> (agent-type: <type>): <absolute-path>` line per emitted prompt file.
5. Stop immediately after batch emission. **End the turn right after the last `call sub-agent` line.** Do NOT print anything else — no `# output sub-agent N:` blocks, no fabricated sub-agent results, no summaries, no "the sub-agents will now…" narration. The executor dispatches the sub-agents and resumes the session with the real outputs. Emitting `# output sub-agent N:` in the same turn as `call sub-agent N` is a protocol violation that the executor detects and fails the job — the run is wasted and no real work happened.
6. Do NOT evaluate a batch until resumed outputs for that batch are provided.
7. On resume, reread persisted state first, then parse `# output sub-agent <N>:` blocks using the transport contract.
8. Map resumed outputs to the expected handoffs deterministically. Reject incomplete, duplicate, or unexpected output blocks using the protocol retry messages.
9. Review the completed batch for scope compliance, verification failures, and dependency outputs.
10. If another implementation batch in the same wave is required, update state, emit the next batch, and stop again.
11. If a task must be retried, emit a corrected replacement prompt file as a new batch instead of directly taking over the work.
12. Delete obsolete implementation prompt files only after their outputs have been processed successfully.
13. When the final implementation batch of the final wave has been processed successfully and no new implementation batch must be emitted, continue directly to Phase 4 in the SAME run. Successful wave completion is not a checkpoint.

# PHASE 4: INTEGRATION TESTING

1. When deferred integration testing is required, emit integration prompt files and persist the corresponding execution state.
2. Use transport-safe prompt naming for integration and integration-fix attempts.
3. Treat integration execution as a deterministic phase result with:
   - `status`, one of `passed`, `fix_required`, `waiting_for_handoffs`, `blocked`, or `abort`,
   - `next_step`, describing the exact orchestrator action,
   - `notes`, containing the verification outcome and any retry context.
4. If integration verification fails, return `status: fix_required`, emit the required integration-fix handoff batch, persist state, and stop rather than editing code directly.
5. Do NOT proceed to Phase 5 until integration returns `status: passed` or a deterministic terminal `blocked` or `abort` result stops execution.
6. Treat persisted integration state as authoritative on resume.
7. If integration reaches `status: passed`, or integration is deterministically skipped, continue directly to Phase 5 in the SAME run. Successful integration completion is not a checkpoint.

# PHASE 5: CODE REVIEW

1. If `SKIP_CODE_REVIEW=true`, record the skipped result in persisted state and continue deterministically.
2. Otherwise invoke `plan-executor:review-execution-output-non-interactive` in the current agent.
3. Pass explicit structured review inputs. At minimum include:
   - `plan_path`
   - `execution_root`
   - `changed_files`
   - `language`
   - `recipe_list`
   - `skip_code_review`
   - `state_file_path`
   - `execution_state`
   - `review_state`
   - `review_state_path` when helper-owned review state is persisted separately from the immediate payload
   - `prior_review_notes`
4. Execution orchestration state remains orchestrator-owned. Review state remains helper-owned and separate from execution orchestration state and helper-owned validation state.
5. The review helper runs in the same agent as the orchestrator. Reviewer isolation and review-fix isolation happen only in focused sub-agents underneath the helper.
6. The orchestrator MUST treat the review helper as the only authority for non-interactive Phase 5. It MUST NOT emit alternate reviewer handoffs, use other review skills, run ad-hoc reviewers, or manually triage review findings outside the helper-owned flow.
7. The review helper owns Phase 5 boundaries, frozen reviewer-set persistence, review prompt-file naming, review handoff emission, resumed-output parsing for full reviewer batches, triage persistence across attempts, review-fix handoff generation, review cap enforcement, and regression verification.
8. Persisted review metadata must include, when relevant, the helper skill version, current phase, current attempt, and frozen reviewer set.
9. The review helper must return a deterministic result contract with:
   - `status`, one of `clean`, `fix_required`, `waiting_for_handoffs`, `blocked`, or `abort`,
   - `next_step`, describing the exact orchestrator action,
   - `notes`, containing review outcomes, triage context, and retry rationale,
   - `state_updates`, containing any authoritative review-state changes that must be persisted before the next step.
10. Continue only from the helper's returned structured result. Persist `state_updates` before emitting another batch or advancing phases. Do NOT inline review-specific prompt policy here.
11. If the helper returns `status: clean`, continue directly to Phase 6 in the SAME run. A clean review result is not a checkpoint.
12. If the helper returns any non-clean status, the orchestrator MUST follow only that helper-directed path. Any alternate review path, smaller reviewer batch, or manual shortcut is a skill violation and the run must be treated as not having completed Phase 5.

# PHASE 6: PLAN VALIDATION

1. Invoke `plan-executor:validate-execution-plan-non-interactive` in the current agent.
2. Pass explicit structured validation inputs. At minimum include:
   - `plan_path`
   - `execution_root`
   - `changed_files`
   - `language`
   - `recipe_list`
   - `skip_code_review`
   - `state_file_path`
   - `execution_state`
   - `validation_state`
   - `validation_state_path` when helper-owned validation state is persisted separately from the immediate payload
   - `prior_validation_notes`
3. Execution orchestration state remains orchestrator-owned. Validation state remains helper-owned and separate from execution orchestration state and helper-owned review state.
4. The validation helper runs in the same agent as the orchestrator. Validator isolation and validation-fix isolation happen only in focused sub-agents underneath the helper.
5. The orchestrator MUST treat the validation helper as the only authority for non-interactive Phase 6. It MUST NOT emit alternate validator handoffs, self-validate, or run ad-hoc validation outside the helper-owned flow.
6. The validation helper owns Phase 6 boundaries, validation prompt-file naming, validator handoff emission, resumed-output parsing for validator output, GAP-to-fix prompt generation, validation-fix batching, persisted validation attempt state, deterministic stop summary after the cap is reached, explicit re-review handling after validation fixes when code review is not skipped, validation cap enforcement, and pass/abort decisions.
7. Persisted validation metadata must include, when relevant, the helper skill version, current phase, current attempt, and any frozen reviewer set inherited from a required re-review.
8. The validation helper must return a deterministic result contract with:
   - `status`, one of `pass`, `fix_required`, `waiting_for_handoffs`, `proceed_decision_required`, `blocked`, or `abort`,
   - `next_step`, describing the exact orchestrator action,
   - `notes`, containing validation outcomes, remaining gaps, and retry rationale,
   - `state_updates`, containing any authoritative validation-state changes that must be persisted before the next step.
9. If the helper returns `proceed_decision_required`, stop deterministically. Do not continue this run. A proceed-or-abort decision may be honored only on a fresh intentional rerun that supplies authoritative updated state recording that decision.
10. Continue only from the helper's returned structured result. Persist `state_updates` before emitting another batch, stopping for a decision, or advancing phases. Do NOT inline validation-specific prompt policy here.
11. If the helper returns `status: pass`, continue directly to Phase 7 in the SAME run. A passing validation result is not a checkpoint.
12. If the helper returns any non-pass status, the orchestrator MUST follow only that helper-directed path. Any alternate validation path, smaller validator batch, or manual shortcut is a skill violation and the run must be treated as not having completed Phase 6.

# PHASE 7: CLEANUP AND PR

1. Delete obsolete prompt files only after their outputs are processed.
2. Run final verification through delegated deterministic handoffs when fixes are needed.
3. Commit locally unless `SKIP_PR=true` suppresses the PR path entirely.
   - `--no-pr` skips remote PR work only; it does NOT skip the local commit.
4. Unless `--no-pr` or `SKIP_PR=true`, push the branch and create a draft PR using `gh pr create --draft`.
   - The PR title must include the JIRA ticket.
   - The PR body should summarize what was implemented, organized by sub-task.
   - If there were unresolved gaps from Phase 6, include them in a `Known Gaps` section.
5. Unless `--no-pr`, `--draft-pr`, or `SKIP_PR=true`, mark the PR ready and hand off PR finalization to the executor via a bash handoff.
   - Locate `pr-monitor.sh` relative to this skill's plugin root: `${CLAUDE_PLUGIN_ROOT}/skills/pr-finalize/pr-monitor.sh`. Resolve the absolute path by reading the plugin cache directory from the current session (the same directory where this skill's SKILL.md was loaded from).
   - Write a wrapper script at `<execution-root>/.tmp-subtask-pr-finalize.sh` that calls `pr-monitor.sh` with these exact flags — **no others**: `--owner <owner> --repo <repo> --pr <number> --head-sha <sha> --push-time <epoch_seconds> --workdir <path> --summary-file <path> --log-file <path>`. `--head-sha` MUST be the HEAD commit of the PR branch after `git push` (run `git rev-parse HEAD` on the feature branch after pushing). A wrong SHA causes the monitor to poll forever. If `--merge` or `--merge-admin` is in effect, the wrapper script must handle the merge **after** `pr-monitor.sh` exits 0 — do NOT pass `--merge` to `pr-monitor.sh`. Add a post-monitor block that treats merge failure as non-fatal (the PR may not be mergeable yet due to pending checks or branch protection): `MONITOR_EXIT=$?; if [ $MONITOR_EXIT -eq 0 ]; then gh pr merge --merge [--admin] <PR> --repo <OWNER>/<REPO> || echo "MERGE FAILED (exit $?) — manual merge required"; fi; exit $MONITOR_EXIT`.
   - Emit a single bash handoff: `call sub-agent 1 (agent-type: bash): <absolute-path-to-wrapper>`
   - Persist state and stop so the executor runs the script.
   - On resume, read the summary file from the wrapper output to determine success or failure.
   - This step is MANDATORY whenever the normal PR path is enabled. Do NOT skip it.
   - Do NOT mark the plan `COMPLETED` or print the execution summary until the PR finalization handoff has completed.
   - **If `pr-monitor.sh` returns 0 but the subsequent `gh pr merge` inside the wrapper fails (e.g. `mergeStateStatus: UNKNOWN` because a fix-session just pushed a new commit whose CI hasn't settled): do NOT emit an inline `until gh pr view ... mergeStateStatus; do sleep; done` loop on the orchestrator side. That is the documented way to hit the GHA job timeout at 2h+. Instead, emit a FRESH bash handoff that re-runs `pr-monitor.sh` with the new `--head-sha` (from `git rev-parse HEAD` after the fix-session push) and stop. `pr-monitor.sh` is the only supported place to wait for merge-readiness.**
6. If final verification fails, emit cleanup-fix prompt files, update persisted state, print handoff lines, and stop.
7. Mark the plan `COMPLETED` only after all required Phase 7 work succeeds, including `plan-executor:pr-finalize` when applicable.
8. If Phase 7 completes without emitting another required handoff batch or hitting a deterministic stop condition, continue directly to Phase 8 in the SAME run. Cleanup and PR completion is not a checkpoint.

# PHASE 8: EXECUTION SUMMARY

Print the same structured execution summary used by interactive execution, but describe non-interactive handoff batches, resume points, and helper-driven review and validation results instead of direct worker launches.

Additionally, write the execution summary to `<execution-root>/.tmp-execution-summary.md` as a Markdown file. This file is picked up by the remote execution workflow and posted as a PR comment. The summary file must include:
- Plan name and goal
- Overall status (success/failure)
- Tasks completed with file changes
- A **Code Review Findings** table with columns: `ID | Finding | Severity | Decision | Notes` — listing every finding from the triage with its fix/defer/reject decision
- Validation outcome (pass/fail, any remaining gaps)
- Any errors or unresolved issues

# EXECUTION STATE RULES

- `.tmp-execute-plan-state.json` is the source of truth for the current non-interactive execution point.
- Persist state before every stop.
- Reread state before every continuation parse.
- State must always identify: skill version, plan path, execution root, current phase, current wave when applicable, current attempt when applicable, current batch, and any batch-progress metadata needed for deterministic resume.
- Every state file write that precedes a handoff stop MUST include a non-empty `handoffs` array per HANDOFF_PROTOCOL.md §5. Without this array, the executor cannot dispatch sub-agents.
- Keep execution orchestration state separate from helper-owned review state and helper-owned validation state.
- Never infer missing state from memory or ambient context when persisted state is available.

# DETERMINISTIC STOP BEHAVIOR

Stop immediately after any of these events:
- a required prompt batch has been emitted,
- the continuation payload is incomplete or invalid,
- a required input is missing,
- a helper returns a terminal `blocked` or `abort` result,
- a deterministic precondition fails.

When stopping, print only the next required action or the deterministic error needed for continuation. Do NOT continue speculatively.

# CRITICAL RULES

- Explicit plan path is mandatory.
- No interactive clarification path exists in this skill.
- No direct implementation-worker orchestration is allowed here; implementation work always leaves through prompt-file handoffs.
- Review and validation must run through `plan-executor:review-execution-output-non-interactive` and `plan-executor:validate-execution-plan-non-interactive` with explicit structured state.
- Helper-owned phase contracts are mandatory execution rules, not guidance. The orchestrator must not reinterpret them as optional or replace them with a shorter path.
- If a helper-owned phase requires a frozen reviewer or validator set, full batch completion, or helper-owned fix loop, no substitute path is allowed.
- `execute-plan-non-interactive/HANDOFF_PROTOCOL.md` defines transport-only rules for prompt-file naming, emitted handoff lines, state lifecycle, continuation parsing, and allowed `agent-type` metadata.
- Shortcutting a helper-owned review or validation phase by manual triage, direct reviewer calls, self-validation, or alternate handoff shapes is an execution failure.
- When in doubt, stop and re-enter the helper through authoritative state rather than inventing fallback behavior.
- Execute phases in strict order.
- Always stop deterministically when the next step depends on external handoff output or a terminal helper result.
- No successful phase boundary is a checkpoint. Unless a deterministic stop condition applies, continue automatically until the run reaches its next required handoff stop or the terminal Phase 8 summary.
- `ScheduleWakeup` is forbidden. If you need to wait for external state (CI, remote jobs, PR checks), either emit a bash handoff that polls with `until … sleep N` inside a `timeout`, or use the mandatory `pr-monitor.sh` handoff from Phase 7. Calling `ScheduleWakeup` in this non-interactive flow terminates the run because no scheduler resumes it.
