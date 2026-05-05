---
name: plan-executor:run-reviewer-team-non-interactive
description: "EXECUTOR ONLY — do NOT use in direct user conversations or interactive sessions. Called exclusively by plan-executor:execute-plan-non-interactive and plan-executor:review-execution-output-non-interactive orchestrators. Launches Claude + Codex + Gemini + Security reviewers (security:big-toni when available, plan-executor:lite-security-reviewer as fallback). For interactive reviewer runs use plan-executor:run-reviewer-team instead."
---

**CRITICAL — FORBIDDEN TOOLS: You MUST NOT use the `Agent` tool, `Task` tool, or any sub-agent spawning tool under any circumstances. You MUST NOT use `AskUserQuestion`. All sub-agent work MUST go through the file-based handoff protocol: write prompt files, update state, print `call sub-agent` lines, and STOP. The external executor dispatches sub-agents — you never do. Using the Agent tool is an execution failure that corrupts the handoff protocol.**

# Run Reviewer Team Non-Interactive

Non-interactive counterpart of `plan-executor:run-reviewer-team`. It does the same work — freeze four reviewers, build prompts, collect outputs, triage — but uses the file-based handoff protocol instead of launching sub-agents directly.

It does NOT decide whether to fix, retry, or escalate. That logic belongs to the caller.

## Required Inputs

The full input contract lives at `schemas/input.schema.json` (next to this SKILL). Required fields:

- `plan_context` — plan path or relevant plan excerpts that define the expected implementation
- `execution_outputs` — description or summary of what was built or changed during execution
- `changed_files` — list of files created or modified
- `language` — detected primary language of the changed files
- `recipe_list` — recipe skills relevant to the changed code (used to build reviewer prompts)
- `prior_review_context` — prior triage history for this review loop; must include already-fixed, rejected, and deferred findings so reviewers do not re-raise resolved items; pass empty object `{}` on the first run
- `execution_root` — absolute path to the directory where prompt files are written (worktree root or repo root)
- `attempt` — 1-based integer; used in prompt-file names to prevent clobbering across retry loops

Optional (set by the orchestrator on triage re-entry, absent / empty string on first invocation):

- `prior_handoff_outputs_path` — absolute path to the JSON sidecar the orchestrator wrote after dispatching the four reviewers. Each entry is `{ "index": <N>, "exit_code": <int>, "output": "<stdout>", "stderr": "<stderr>" }`. Non-empty value means **triage mode**.

If any required input is missing, stop immediately and return `status: blocked` with the missing field in `notes`.

## Mode Detection

This skill operates in two modes:

**Dispatch mode** — `prior_handoff_outputs_path` is empty or absent: write prompt files, return `status: waiting_for_handoffs` with `state_updates.handoffs[]` matching `../../schemas/handoffs.schema.json`. The orchestrator dispatches the listed sub-agents, persists their outputs to a sidecar, and re-invokes this skill with the sidecar path filled in.

**Triage mode** — `prior_handoff_outputs_path` is a non-empty absolute path: read the JSON sidecar at that path (array of `{ index, exit_code, output, stderr }`), triage findings, return `status: success` (or `fix_required` / `blocked` / `abort`).

Required handoffs are Claude (index 1) and Security (index 4); a missing entry for either in the sidecar means `status: blocked`. Codex (index 2) and Gemini (index 3) are can-fail; missing entries contribute zero findings.

## Reviewer Set

The frozen reviewer set for every invocation is exactly four reviewers:

1. **Claude** — handoff type `claude` — **required** (job fails if this reviewer fails)
2. **Codex** — handoff type `codex` — **can-fail** (job continues without output if this reviewer fails)
3. **Gemini** — handoff type `gemini` — **can-fail** (job continues without output if this reviewer fails)
4. **Security** — handoff type `claude`. Skill selection follows "Security reviewer skill selection" below. **required** (job fails if this reviewer fails)

Reducing the set below four or replacing a reviewer with a generic (non-security) fallback is forbidden. If any reviewer prompt file cannot be written, return `status: blocked` with the reason in `notes`.

The security reviewer skill is the one documented substitution point: when `security:big-toni` is not available, `plan-executor:lite-security-reviewer` is used instead. Both skills satisfy the security slot — neither is a "generic fallback".

## Security reviewer skill selection

Before writing the security reviewer prompt file, decide which skill its slash-command entry line will invoke.

1. Check whether `security:big-toni` appears in the current session's available-skills list (the list provided in system-reminders by the harness).
2. If `security:big-toni` is present, the security prompt file MUST begin with `/security:big-toni` as the first line.
3. If `security:big-toni` is NOT present, the security prompt file MUST begin with `/plan-executor:lite-security-reviewer` as the first line. Record this substitution in the run's `notes` (e.g. `"security reviewer: lite fallback (security:big-toni not installed)"`).
4. If neither skill is available, return `status: blocked` with `security reviewer unavailable` in `notes`. Do not emit handoffs in this case.

Do NOT emit a security handoff without one of these two slash-command lines. The security slot must always be filled by one of the two named skills.

## Language detection and Claude recipe skill loading

Before writing the Claude reviewer prompt file, determine the project language and the matching production-code / test-code recipe skills. The Claude reviewer MUST invoke those skills at the start of its run so the review is anchored to the project's documented code standards.

### Language resolution

1. If the caller passed a non-empty `language` input, use it verbatim (lower-case it for lookup).
2. If `language` is missing, empty, or `unknown`, infer it from the extensions of `changed_files` using this precedence (first match wins):
   - `.ts`, `.tsx`, `.mts`, `.cts` → `typescript`
   - `.py`, `.pyi` → `python`
   - `.go` → `go`
   - `.rs` → `rust`
3. If neither the caller nor the extension check yields a known language, record `language: unknown` and skip recipe loading — do NOT block the run.

### Recipe skill mapping

| Language | Production skill | Test skill |
|----------|------------------|------------|
| `typescript` | `typescript-services:production-code-recipe` | `typescript-services:test-code-recipe` |
| `python` | `python-services:production-code-recipe` | `python-services:test-code-recipe` |
| `go` | `go-services:go-expert-recipe` | `go-services:go-reviewer-recipe` |
| `rust` | `rust-services:production-code-recipe` | `rust-services:test-code-recipe` |

### Availability check

For each mapped skill, check whether it appears in the current session's available-skills list (the list provided in system-reminders by the harness).

- If a mapped skill is present, include it in the Claude recipe load list.
- If a mapped skill is missing, omit it and add a note to the run (e.g. `"claude recipe: typescript-services:test-code-recipe not installed, skipped"`). Do NOT block.
- If both the production-code and test-code skills for the detected language are missing, record `claude recipe: no project recipes available for <language>` and proceed without recipe loading.

### Merging with caller-provided recipes

If the caller passed a non-empty `recipe_list`, merge the caller's list with the mapped list. Deduplicate by skill name. The Claude recipe load list is the union.

### Claude prompt file obligation

The Claude prompt file MUST include a preamble that tells Claude to invoke every skill in the resolved recipe load list via the Skill tool BEFORE running any review step. Each invocation is for standards context — Claude should treat the returned content as the authoritative rules for its review. If the resolved list is empty, the preamble states that no project recipes were resolved and Claude proceeds without recipe context.

This obligation applies only to the Claude prompt file. Codex, Gemini, and the security prompt files do NOT receive the Skill-tool preamble.

The Codex prompt file has its own exception — see the "Codex prompt file exception (brevity contract)" block in "Reviewer Prompt Contract" below.

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
- **the inlined unified diff** (see "Diff embedding" below) so reviewers do NOT have to re-discover the diff from `git` on every iteration
- prior review context: already-fixed findings, rejected findings, deferred findings
- the reporting contract below
- the subprocess hygiene block below (reviewers that run commands must not hang the orchestrator)
- the diff-focus instruction (see "Diff embedding" below) so reviewers anchor on the inlined diff rather than spawning their own exploration tools

### Diff embedding

Compute the unified diff once before writing the reviewer prompt files and embed it inline in every prompt (Claude / Codex / Gemini / Security). The diff is the authoritative scope for the review — reviewers should not need `git diff`, `git log`, `git rev-parse`, or `git branch` calls just to discover what changed.

**Computing the diff:**

1. Resolve the base branch from caller-supplied inputs in this order: explicit `target_branch` input → `manifest.plan.target_branch` → fall back to `origin/HEAD` → finally `main`. Use the first non-empty value.
2. Run `git diff <base>...HEAD --no-color` (three-dot — diff against the merge-base, not the tip) once and capture stdout.
3. Cap the embedded diff at **5000 lines** OR **200 KB**, whichever is smaller. When the cap is exceeded, embed the first chunk up to the cap, append a single line `[diff truncated: <total-lines> lines / <bytes> bytes; reviewers may inspect remaining files via Read]`, and note in `notes` that the diff was truncated.
4. When the `git diff` invocation fails (no base branch, detached HEAD, etc.), embed a single-line placeholder `[diff unavailable: <error>]` and rely on `changed_files` + reviewer tool calls instead. Do not fail the skill on diff-compute errors.

**Embedding shape (verbatim in every reviewer prompt, after the changed-files list):**

> ## Unified diff (review scope)
>
> The diff below is the authoritative scope of this review. Anchor your analysis on it. The line ranges in `WHERE:` references should map onto file:line in this diff, OR onto the post-fix file content (after applying the diff). Use the diff to find issues; reach for `Read` / `Grep` / `Bash` only when a finding's reasoning genuinely requires file context the diff does not show.
>
> ```diff
> <unified diff bytes here, truncated per the rule above>
> ```

**Diff-focus instruction (verbatim in every reviewer prompt, after the diff and before the reporting contract):**

> **Focus on the diff above.** It carries the authoritative review scope. Do NOT spawn `git diff`, `git log`, `git branch`, `git rev-parse`, or full-file `Read` / `cat` / `sed` / `nl` chunks just to re-discover what changed — that information is already inline. You MAY read additional files when a finding's reasoning genuinely requires context the diff does not show (e.g. a function signature referenced by changed code, the surrounding state-machine, the test that exercises the changed path). When you do, prefer targeted `Read` with explicit line ranges over enumeration.

**Claude prompt file exception:** The Claude prompt file (index 1) MUST begin with a "Load project recipe skills first" preamble that lists the resolved recipe load list from "Language detection and Claude recipe skill loading" and instructs Claude to invoke each one via the Skill tool before running any review step. If the resolved list is empty, the preamble states that no project recipes were resolved and Claude proceeds without recipe context.

**Codex prompt file exception (brevity contract):** The Codex prompt file (index 2) MUST end with a verbatim brevity block — Codex left to its own pacing emits 100k-250k chars per review, drowns the triage prompt's context window, and stretches the review-fix loop into multi-hour runs. Add this block as the last section of the Codex prompt, after the reporting contract and the subprocess hygiene block:

> **Output discipline (MANDATORY).**
>
> 1. **Cap your total output at 500 lines.** If you have more findings than fit, prioritize: severity high → low; in-scope → out-of-scope. Drop the tail.
> 2. **No prose between findings.** No headers like "## File X", no transitions like "Now examining…". Findings list only.
> 3. **No code re-pasting.** Reference by `path:line`. The triage agent has the diff.
> 4. **No file enumeration.** Do not output a "Reviewed files" preamble; the orchestrator already has the changed-files list.
> 5. **One sentence per field.** Description ≤ 20 words. Reasoning ≤ 20 words. Concrete fix ≤ 20 words.
> 6. **If clean, exit with `STATUS: OK`** as the only output line. No "no findings detected" prose.
>
> Format every finding as exactly four lines:
>
> ```
> SEVERITY: <FIX_REQUIRED|VERIFIED_FIX|REJECTED|DEFERRED>
> WHERE: <relative/path>:<line>
> ISSUE: <≤20 words>
> FIX: <≤20 words>
> ```
>
> Skip extra blank lines between findings. The triage agent parses the four-line block; anything else is dropped.

This block applies only to Codex. Claude (recipe-driven), Gemini (concise by default), and Security (skill-driven) keep their existing prompt shapes.

**Security reviewer prompt exception:** The security reviewer prompt (index 4) MUST begin with the slash command chosen in "Security reviewer skill selection" — `/security:big-toni` when big-toni is available, otherwise `/plan-executor:lite-security-reviewer`. The first line is followed by the review scope and changed files. When big-toni is used it does NOT receive the standard recipe list or language context — `security:big-toni` determines its own methodology. When the lite fallback is used it receives the review scope, changed files, prior review context, and the reporting contract directly (it has its own built-in checklist, so no recipe list is needed). In both cases the security reviewer MUST receive the prior review context and the reporting contract so it does not re-raise already-resolved findings.

**Reporting contract to include in every reviewer prompt:**

> Report only findings within the current review scope. For each finding include: file path, line reference if applicable, a concrete description, and your reasoning. Classify every finding as one of:
> - `FIX_REQUIRED` — real, in-scope, must be fixed
> - `VERIFIED_FIX` — a prior FIX_REQUIRED issue that is now correctly fixed
> - `REJECTED` — invalid, out of scope, or based on incorrect assumptions
> - `DEFERRED` — real but intentionally left unresolved (must state reason)
>
> Do not re-raise findings already marked fixed, rejected, or deferred in prior review context unless you have new evidence that invalidates the prior decision. Do not make code changes directly.

**Subprocess hygiene block to include in every reviewer prompt (verbatim — identical across all plan-executor non-interactive skills):**

> **Subprocess hygiene (MANDATORY — the daemon watchdog kills the job after prolonged silence).**
>
> Any Bash command that starts a long-running or backgrounded process MUST follow these rules:
> 1. Wrap every invocation in `timeout N` (N ≤ 600 seconds). Example: `timeout 120 ./run-tests`.
> 2. Never call bare `wait "$PID"` on a backgrounded process. Use `timeout N wait "$PID"` or a bounded `kill -0 "$PID"` poll with a max iteration count instead.
> 3. Escalate signals on cleanup: `kill -TERM "$PID" 2>/dev/null; sleep 1; kill -KILL "$PID" 2>/dev/null || true`. `SIGTERM` alone may be ignored.
> 4. Before exiting any script that spawned children, reap the group: `pkill -P $$ 2>/dev/null || true`.

## Execution

### Dispatch Mode

1. Validate all required inputs are present.
2. Run the security reviewer skill-selection check (see "Security reviewer skill selection"). Record the chosen skill and, if the lite fallback was selected, add a note for the run so the completion report can surface it.
3. Run the language detection and Claude recipe load-list resolution (see "Language detection and Claude recipe skill loading"). Record the detected language and the final recipe load list. Add notes for any missing mapped skills.
4. **Compute the unified diff** per "Diff embedding". Capture stdout once; cache it for every reviewer prompt in this dispatch. Truncation, embedding shape, and fallback on `git diff` failure are all covered in that section.
5. Build one reviewer prompt per reviewer using the contract above. The security prompt's first line uses the slash command chosen in step 2. The Claude prompt's preamble uses the recipe load list from step 3. **Every prompt embeds the diff from step 4 between the changed-files list and the reporting contract**, followed by the diff-focus instruction.
6. Write the four prompt files to `execution_root`.
7. Return `status: waiting_for_handoffs` with the structured handoff list in `state_updates.handoffs[]` (see Completion Contract). The orchestrator (plan-executor binary) reads that array, dispatches the four reviewers via its built-in dispatcher, persists each sub-agent's stdout/exit_code to a sidecar file, and re-invokes this skill with `prior_handoff_outputs_path` pointing at that sidecar — at which point you re-enter in triage mode.

**Self-validation is MANDATORY before emitting the envelope.** Pipe the full envelope through `plan-executor validate --schema=helper-output:run-reviewer-team -` (exits `0` with `VALID:` on success, `1` with one or more `ERROR:` lines on stderr on schema violation).

Iterate until clean:

1. Build the envelope per this SKILL.md.
2. Pipe it through the validator.
3. On exit `0`: emit the envelope on stdout — that is the protocol path.
4. On exit `1`: read the `ERROR:` lines, fix the offending fields, and re-validate. Common causes: a `status` value not in the schema's enum, a required field missing under `state_updates`, a malformed nested shape, or extra closed-shape keys (the dispatch `state_updates` is closed; the triage `state_updates` accepts additional helper-owned persistence fields).
5. If repeated iterations cannot produce a schema-clean envelope, that is a SKILL ↔ schema drift bug. Emit a `status: blocked` envelope whose `notes` carry the validator's `ERROR:` lines verbatim plus the offending envelope inline (use placeholder values like `"/dev/null"` for any required `minLength`-constrained string fields). Do NOT emit a known-broken envelope — the orchestrator fails fast on `blocked` with the diagnostic, while a broken envelope wastes the protocol-violation retry budget repeating the same shape.

When self-checking only the handoffs sub-array (e.g. before nesting it under `state_updates.handoffs`), pipe just that array through `plan-executor validate --schema=handoffs -`.

The legacy `call sub-agent N (...)` text markers are NOT consumed by the Rust orchestrator — only `state_updates.handoffs[]` is. Do not emit those markers.

### Triage Mode

Triage mode is entered when the input includes a non-empty `prior_handoff_outputs_path`. The orchestrator wrote a JSON sidecar at that path; each entry is `{ "index": <N>, "exit_code": <int>, "output": "<stdout>", "stderr": "<stderr>" }`.

1. Read the sidecar file at `prior_handoff_outputs_path`. Parse it as a JSON array.
2. Require an entry with `index: 1` (Claude). If missing, return `status: blocked`.
3. Codex (index 2) and Gemini (index 3) entries are optional. A missing entry for a can-fail reviewer means that reviewer's output is absent — treat it as contributing zero findings. A duplicated or unexpected index still triggers `status: blocked`.
4. Security (index 4) entry is required. If missing, return `status: blocked`.
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

**Output protocol (strict):** stdout MUST be exactly one JSON envelope object — `{ "status": "...", "next_step": "...", "notes": "...", "state_updates": { ... } }`. Do NOT print any other `{ ... }` block before or after it. Do NOT paraphrase `reviewer_set` entries (or any other field) as a JS-/Python-style object literal in prose; the executor scans for the first balanced `{ ... }` block whose JSON parses and contains `"status"`, and an unparseable descriptor preceding the real envelope risks tripping a `protocol_violation` even with the resilient extractor. If you need to narrate dispatch, use plain sentences — no curly braces.

### `status: waiting_for_handoffs`

Return after emitting the prompt-file batch. The envelope MUST include:

- `status: "waiting_for_handoffs"`
- `next_step` — short string the operator can read (e.g. `"dispatch the four reviewers and re-invoke in triage mode"`)
- `notes` — emitted batch metadata, attempt number, and absolute prompt-file paths
- `state_updates`:
  - `handoffs` — array of four entries the orchestrator dispatches verbatim. Each entry MUST have:
    - `index` — 1-based integer (1=Claude, 2=Codex, 3=Gemini, 4=Security)
    - `agent_type` — `"claude"` | `"codex"` | `"gemini"` (no `"bash"` for review handoffs)
    - `prompt_file` — absolute path to the prompt file you just wrote under `execution_root`
    - `can_fail` — `true` for Codex (index 2) and Gemini (index 3); omit (defaults to `false`) for Claude (index 1) and Security (index 4)
  - `reviewer_set` — frozen list of four reviewers used for this batch (the caller persists this for replay / audit; not consumed by the dispatcher)

Concrete envelope shape:

```json
{
  "status": "waiting_for_handoffs",
  "next_step": "dispatch four reviewers; re-invoke in triage mode",
  "notes": "attempt 1; prompt files written to /…/execution_root/",
  "state_updates": {
    "handoffs": [
      { "index": 1, "agent_type": "claude", "prompt_file": "/abs/path/.tmp-subtask-review-attempt-1-claude.md" },
      { "index": 2, "agent_type": "codex",  "prompt_file": "/abs/path/.tmp-subtask-review-attempt-1-codex.md",  "can_fail": true },
      { "index": 3, "agent_type": "gemini", "prompt_file": "/abs/path/.tmp-subtask-review-attempt-1-gemini.md", "can_fail": true },
      { "index": 4, "agent_type": "claude", "prompt_file": "/abs/path/.tmp-subtask-review-attempt-1-security.md" }
    ],
    "reviewer_set": [ /* four-entry descriptor for replay */ ]
  }
}
```

Self-validate the full envelope before printing — see the **Envelope self-validation** subsection in the Dispatch Mode section above for the iterate-until-clean contract. Briefly: `echo '<your full envelope>' | plan-executor validate --schema=helper-output:run-reviewer-team -` exits `0` + `VALID:` on success or `1` + `ERROR:` lines on schema violation; do not emit a known-broken envelope.

### `status: success`

Return after successful triage. Include:

- `status: success`
- `reviewer_set` — list of the four reviewers used. For the security reviewer entry, record the actual skill used (`security:big-toni` or `plan-executor:lite-security-reviewer`).
- `attempt_note` — free-text note about this run (e.g. first attempt, retry N). MUST mention the lite fallback when it was selected, the detected language, and any skipped Claude recipes.
- `detected_language` — the resolved project language (`typescript` | `python` | `go` | `rust` | `unknown`).
- `claude_recipes_loaded` — list of recipe skill names actually included in the Claude prompt file preamble.
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
