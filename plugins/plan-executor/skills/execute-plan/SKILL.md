---
name: plan-executor:execute-plan
description: Use ONLY when the user explicitly invokes /plan-executor:execute-plan in an interactive session. Orchestrator-only — NEVER load from inside a dispatched sub-agent, a subtask prompt file, or another plan-executor skill's execution.
argument-hint: [plan-document] [jira-ticket] [--no-worktree] [--no-pr] [--draft-pr]
---

Execute the explicitly provided plan path, or resolve a single READY plan during setup.

You are the INTERACTIVE ORCHESTRATOR. You coordinate execution of a development plan by delegating implementation, review, validation, and fix work to focused sub-agents or helper skills. You NEVER write production code or test code yourself.

# PHASE 1: LOAD COMPILED MANIFEST

Before the orchestrator is invoked, the `plan-executor execute` CLI has already resolved the plan path and pre-compiled the plan into a schema-validated `tasks.json` manifest via the `plan-executor:compile-plan` skill. You MUST:

1. Read the compiled manifest at the path given in `--compiled-manifest` (default fallback: `<execution-root>/.tmp-plan-compiled/<hash>/tasks.json`). Parse it as JSON.
2. Trust the manifest. Schema shape and semantic rules have already been enforced by the Rust validator. Do NOT re-parse the plan markdown. Do NOT re-decompose tasks.
3. Flip the plan file's header `**Status:** READY` to `**Status:** EXECUTING`. THIS IS NOT OPTIONAL.
4. Use the manifest's `waves` array as the authoritative decomposition. Use each wave's `task_ids` in order and dispatch up to 5 parallel sub-agents per wave.
5. Proceed directly to Phase 3 (WAVE-BASED EXECUTION).

If `--compiled-manifest` is missing from the invocation, emit a deterministic error and stop.

When Phase 1 completes, continue directly into Phase 3 in the SAME turn. Phase 1 completion is not a checkpoint.

# PHASE 3: WAVE-BASED EXECUTION

**For each wave: mark its task `in_progress` before launching sub-agents, and `completed` once all sub-agents in that wave finish and the wave review passes.**

Execute sub-tasks wave by wave. Within each wave, run independent sub-tasks in parallel, up to 5 concurrent sub-agents. Wait for the entire wave to complete before starting the next wave.

**For each sub-task in the current wave:**

1. **Create a temporary sub-task file** at `.tmp-subtask-<N>.md` in the execution root. The file MUST begin with a standard agent preamble before any task content:
   - State the agent's role: "You are a focused implementation agent. Implement exactly what this prompt describes. Nothing more, nothing less. Do NOT read or reference any other plan document, roadmap, or task files."
   - Name each code standard recipe to load using the Skill tool before writing any code, using the exact skill name (e.g. `rust-services:production-code-recipe`). Include this even when the task body mentions the same skills.
   - State the working directory (execution root).
   - End the file with: "After completing the task, report: all files you created or modified, any exported types or function signatures later tasks may depend on, and the result of any verification commands you ran."
2. **Launch an implementation sub-agent** using the Agent tool with a general-purpose agent and the following prompt contract:
   - Read only the assigned sub-task file.
   - Implement exactly what it describes. Nothing more, nothing less.
   - Do NOT read or reference any full plan document, roadmap, or other task files.
   - If the sub-task was derived from a plan task section, treat the sub-task file as the sole source of truth for that task's copied code snippets, commands, and acceptance criteria.
   - Load the listed code standard recipes using the Skill tool before writing any code.
   - Write tests only when the sub-task says to write them.
   - Report files created or modified and any exports/interfaces later tasks might need.
   - Work in the execution root.
   - Explicitly set the Agent `model` parameter to match the orchestrator's current model on every Agent call.
3. **Run independent sub-tasks in parallel when safe.** Tasks with shared files or shared dependencies MUST run sequentially.

**After all sub-agents in the current wave complete:**

4. **Review each sub-agent output:**
   - Verify each sub-agent stayed in scope and did not modify unrelated files.
   - Check for unexpected file conflicts. If two parallel sub-agents modified the same file unexpectedly, stop direct orchestration for that conflict and dispatch a dedicated follow-up fix sub-agent or rerun the affected tasks with corrected scope.
   - Run existing linter, type-check, build, and test commands to catch regressions early.
   - Record what was produced so later waves can receive dependency context.
   - If a sub-agent failed or produced incorrect output, fix the sub-task description and rerun it before moving to the next wave.
5. **Delete all temporary sub-task files** for the completed wave.
6. **Proceed to the next wave** with updated dependency context in the SAME turn unless there is no next wave.
7. When the final wave completes, continue directly to Phase 4 in the SAME turn. Do not stop after a wave-completion report. Do not wait for acknowledgment unless blocked by a missing user decision, missing permission, or a risky action that needs confirmation.

# PHASE 4: INTEGRATION TESTING

**Mark the Integration Testing task `in_progress` if integration tests are needed; otherwise mark it `completed` immediately. Mark it `completed` when done.**

If any sub-tasks had `tests deferred to integration test task`, create a dedicated integration-test sub-agent.

1. Write an integration test prompt file describing:
   - which modules or functions need integration tests,
   - the interfaces and file paths of all relevant modules,
   - the scenarios that validate the modules working together,
   - the test-code recipe to load.
2. Launch the integration-test sub-agent with the Agent tool.
3. After completion, run the full test suite to verify everything passes.
   - If verification passes, continue.
   - If verification fails, dispatch a dedicated fix sub-agent; do NOT fix code yourself.
   - After the integration-fix pass completes, rerun integration verification and the full test suite.
   - Do NOT proceed to Phase 5 until integration verification passes or execution stops for another explicit reason.
4. Delete temporary integration-test files once no longer needed.
5. Continue directly to Phase 5 in the SAME turn once integration testing is complete or skipped. Do not stop after reporting integration results unless blocked by a missing user decision, missing permission, or a risky action that needs confirmation.

# PHASE 5: CODE REVIEW

**Mark the Code Review task `in_progress` before starting. Mark it `completed` when the helper exits clean.**

- If `SKIP_CODE_REVIEW=true`, mark the task `completed` immediately and continue to Phase 6.
- Otherwise, Phase 5 is mandatory. Do NOT proceed to Phase 6 or Phase 7 without completing it.
- Invoke `plan-executor:review-execution-output` in the same agent as the orchestrator.
- The orchestrator MUST treat the helper as the only authority for review execution. It MUST NOT substitute any other review skill, ad-hoc reviewer, manual triage, or single-reviewer shortcut for any part of Phase 5.
- The orchestrator MUST NOT call `superpowers:requesting-code-review`, `superpowers:code-reviewer`, or any other direct reviewer outside the helper-owned flow while Phase 5 is active.
- Pass the review helper explicit structured inputs, at minimum:
  - `plan_path`
  - `execution_root`
  - `changed_files`
  - `language`
  - `recipe_list`
  - `skip_code_review`
  - `prior_review_notes`
  - `review_state_path` when review state is persisted outside the immediate helper result
  - `review_state` when prior helper-owned review state already exists
- Execution orchestration state remains orchestrator-owned. Review state remains helper-owned and separate from execution orchestration state and validation state.
- The review helper owns Phase 5 boundaries, reviewer prompt content, review temp-file naming, frozen reviewer-set selection, review triage persistence, retry accounting, and review-fix isolation.
- Phase 5 reviewer selection is helper-owned and fixed. The orchestrator must not choose, reduce, expand, or replace the reviewer set.
- Reviewers and review-fix workers must run as focused sub-agents underneath the helper. The orchestrator must not bypass the helper and must not collapse reviewer isolation into the orchestrator itself.
- If the helper returns a non-clean result, the orchestrator MUST follow only the helper's `next_step`. It MUST NOT improvise an alternate review path, partial fix loop, or direct re-review outside the helper.
- Any direct review action taken outside the helper-owned Phase 5 flow is a skill violation and the run must be treated as having failed Phase 5 until the helper re-runs the full required review loop cleanly.
- Persisted review metadata must include, when relevant, the helper skill version, current phase, current attempt, and frozen reviewer set.
- The review helper must return a deterministic result contract with:
  - `status`, one of `clean`, `fix_required`, `blocked`, or `user_decision_required`,
  - `next_step`, describing the exact required orchestrator action,
  - `notes`, containing review outcomes and any rationale the next iteration needs, including `FIX_REQUIRED`, `VERIFIED_FIX`, `REJECTED`, and `DEFERRED` review-state details,
  - `state_updates`, containing authoritative review-state updates when the helper persists or advances review state.
- Wait for the helper result before continuing to Phase 6.
- Continue only if the helper returns `status: clean`.
- If the helper returns `fix_required`, `blocked`, `user_decision_required`, or any other non-clean outcome, do NOT proceed. Follow `next_step` and re-enter Phase 5 until the helper returns `status: clean`.
- Once the helper returns `status: clean`, continue directly to Phase 6 in the SAME turn. Do not stop after a clean review result. Do not wait for acknowledgment unless blocked by a missing user decision, missing permission, or a risky action that needs confirmation.
- Do NOT define review prompt-body policy in this orchestrator. Concern-specific review prompt content belongs to the review helper.

# PHASE 6: PLAN VALIDATION

**Mark the Plan Validation task `in_progress` before starting. Mark it `completed` only when validation passes, or when an interactive operator explicitly decides to proceed after repeated failed attempts.**

- Phase 6 is mandatory. Do NOT proceed to Phase 7 without completing it.
- The orchestrator MUST use a dedicated validator flow. The orchestrator NEVER validates by itself.
- Invoke `plan-executor:validate-execution-plan` in the same agent as the orchestrator.
- Pass the validation helper explicit structured inputs, at minimum:
  - `plan_path`
  - `execution_root`
  - `changed_files`
  - `language`
  - `recipe_list`
  - `skip_code_review`
  - `prior_validation_notes`
  - `validation_state_path` when validation state is persisted outside the immediate helper result
  - `validation_state` when prior helper-owned validation state already exists
  - `post_cap_decision` when the helper is re-entered after a proceed-or-abort decision at the 5-attempt cap
- Execution orchestration state remains orchestrator-owned. Validation state remains helper-owned and separate from execution orchestration state and review state.
- The validation helper owns Phase 6 boundaries, validation temp-file naming, validator prompt content, validator isolation, retry accounting, validation cap enforcement, and any required review rerun triggered after validation fixes.
- The orchestrator MUST treat the validation helper as the only authority for Phase 6. It MUST NOT run ad-hoc validators, self-validation, or alternate validation skills while Phase 6 is active.
- Validators and validation-fix workers must run as focused sub-agents underneath the helper. The orchestrator must not bypass the helper and must not collapse validator isolation into the orchestrator itself.
- If the helper returns a non-pass result, the orchestrator MUST follow only the helper's `next_step`. It MUST NOT improvise a shortcut validation path or declare success from targeted checks alone.
- Any direct validation action taken outside the helper-owned Phase 6 flow is a skill violation and the run must be treated as having failed Phase 6 until the helper re-runs the full required validation loop cleanly.
- Persisted validation metadata must include, when relevant, the helper skill version, current phase, current attempt, and any frozen reviewer set inherited from a required review rerun.
- The validation helper must return a deterministic result contract with:
  - `status`, one of `pass`, `fix_required`, `proceed_decision_required`, `abort`, or `blocked`,
  - `next_step`, describing the exact required orchestrator action,
  - `notes`, containing validation outcomes, remaining gaps, and any rationale needed for the next step,
  - `state_updates`, containing authoritative validation-state updates when the helper persists or advances validation state.
- Wait for the helper result before continuing to Phase 7 or stopping on an abort path.
- Continue to Phase 7 only if the helper returns `status: pass`, or if the helper is re-entered with `post_cap_decision: proceed` and returns `status: proceed_decision_required` with notes recording that approved proceed decision for final reporting.
- If the helper returns `status: fix_required`, `blocked`, or any other non-terminal non-pass outcome, do NOT proceed. Follow `next_step` and re-enter Phase 6 until the helper returns `status: pass`, `status: proceed_decision_required`, or `status: abort`.
- If the helper returns `status: abort`, print the required validation failure summary, leave this task incomplete, and stop without entering Phase 7 or Phase 8.
- Once validation allows continuation, continue directly to Phase 7 in the SAME turn. Do not stop after a passing validation result or approved proceed decision. Do not wait for acknowledgment unless blocked by a missing user decision, missing permission, or a risky action that needs confirmation.
- Do NOT define validation prompt-body policy in this orchestrator. Concern-specific validation prompt content belongs to the validation helper.

# PHASE 7: CLEANUP AND PR

**Mark the Cleanup and PR task `in_progress` before starting. Mark it `completed` only after final verification passes, PR work is finished, and any required `plan-executor:pr-finalize` run is fully complete.**

1. Clean up temporary files created by this interactive run once they are no longer needed.
2. Run the full build, lint, and test pipeline one final time.
   - If any issues are found, dispatch a dedicated cleanup-fix sub-agent and rerun the pipeline.
   - The orchestrator must not edit code directly.
3. Unless `SKIP_PR=true`, commit all changes with a meaningful commit message referencing the resolved JIRA ticket.
   - `--no-pr` skips remote PR work only; it does NOT skip the local commit.
4. Unless `--no-pr` or `SKIP_PR=true`, push the branch and create a draft PR using `gh pr create --draft`.
   - The PR title must include the jira ticket.
   - The PR body should summarize what was implemented, organized by sub-task.
   - If there were unresolved gaps from Phase 6, include them in a `Known Gaps` section.
5. Unless `--no-pr`, `--draft-pr`, or `SKIP_PR=true`, mark the PR ready and invoke `plan-executor:pr-finalize`.
   - This step is mandatory whenever the normal PR path is enabled.
   - Do NOT mark Phase 7 complete, mark the plan `COMPLETED`, or print the execution summary until `plan-executor:pr-finalize` has fully completed.
6. Only after all required Phase 7 work is truly finished, if the plan file is in `.my/plans/`, update its header by replacing `**Status:** EXECUTING` with `**Status:** COMPLETED`.
7. Only after step 6 succeeds, mark the Phase 7 task `completed`.
8. Continue directly to Phase 8 in the SAME turn. Do not stop after cleanup, commit, push, PR creation, or PR finalization unless blocked by a missing user decision, missing permission, or a risky action that needs confirmation.

# PHASE 8: EXECUTION SUMMARY

**Mark the Execution Summary task `in_progress` before preparing the summary. Mark it `completed` after the summary is printed.**

After Phase 7 completes, print a structured execution summary in markdown format that covers:

- **Phase 1: Load Compiled Manifest** — manifest path, execution root or worktree location, total sub-tasks and waves from the manifest, and any load issues.
- **Phase 3: Wave-Based Execution** — per wave: sub-tasks run, outcomes, files changed, and verification results.
- **Phase 4: Integration Testing** — whether integration tests were needed, what ran, and results.
- **Phase 5: Code Review** — whether review ran or was skipped, and high-level review outcomes from `plan-executor:review-execution-output`.
- **Phase 6: Plan Validation** — validation outcome, attempt count, and any remaining gaps or deviations.
- **Phase 7: Cleanup and PR** — final verification status, commit hash, PR URL, and any known gaps included in the PR.
- **Totals** — files changed, lines added/removed, interactive sub-agent dispatch count, validation attempt count, and final result.

If a phase in the summary template was skipped, keep that phase heading and include a single explicit line saying it was skipped and why.

# CRITICAL RULES

- You are the ORCHESTRATOR. You do NOT write production code or test code.
- Sub-agents must NEVER see the full plan document. They only see their individual sub-task file. The only exception is the validation helper flow in Phase 6, which may pass the full plan to its dedicated validator.
- Sub-task files must be comprehensive. The sub-agent cannot ask follow-up questions about the plan.
- Execute phases in strict order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8.
- Phase 5 may be skipped only when `SKIP_CODE_REVIEW=true`.
- PR creation in Phase 7 may be skipped only when `SKIP_PR=true` or the relevant PR flags require it.
- The orchestrator MUST NOT self-review or self-validate. Independent review and validation are mandatory through helper skills and delegated sub-agents.
- The orchestrator MUST NOT reinterpret helper instructions as optional guidance. Helper-owned phase contracts are mandatory execution rules.
- If a helper-owned phase specifies a required reviewer set, validator set, retry loop, or helper-owned sub-agent fan-out, the orchestrator MUST wait for that helper to execute it. No smaller, faster, or apparently equivalent substitute is allowed.
- Shortcutting a helper-owned phase by using a direct skill call, a single reviewer, manual triage, or a hand-written substitute path is an execution failure, not an acceptable optimization.
- When in doubt, the orchestrator must stop and re-enter the helper, not invent a fallback.
- If a delegated implementation, review-fix, validation-fix, integration-fix, or cleanup-fix result is unsatisfactory, rerun it with corrected instructions. Do NOT take over and write the code yourself.
- Always produce the mandatory execution summary when Phase 8 is reached.
- No phase boundary is a checkpoint. Unless the skill explicitly says to stop, or execution is blocked by a missing user decision, missing permission, or a risky action that needs confirmation, continue automatically until the entire plan reaches its terminal state: Phase 8 summary printed, or an explicit abort/block condition reached.
