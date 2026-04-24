---
name: plan-executor:run-reviewer-team
description: Use when a single parallel reviewer-team run is needed — launches the frozen Claude + Codex + Gemini + Security reviewer set (security:big-toni when available, plan-executor:lite-security-reviewer as fallback), collects all outputs, triages findings, and returns a structured review report.
---

# Run Reviewer Team

This skill executes one reviewer-team run: it freezes the four-reviewer set, builds reviewer prompts, dispatches all four reviewers in parallel as sub-agents, collects every output, triages findings, and returns a self-contained review report.

It does NOT decide whether to fix, retry, or escalate. That logic belongs to the caller.

## Required Inputs

- `plan_context` — plan path or relevant plan excerpts that define the expected implementation
- `execution_outputs` — description or summary of what was built or changed during execution
- `changed_files` — list of files created or modified
- `language` — detected primary language of the changed files
- `recipe_list` — recipe skills relevant to the changed code (used to build reviewer prompts)
- `prior_review_context` — prior triage history for this review loop; must include already-fixed, rejected, and deferred findings so reviewers do not re-raise resolved items; pass empty object `{}` on the first run

If any required input is missing, stop immediately and return `status: blocked` with the missing field in `notes`.

## Reviewer Set

The frozen reviewer set for every invocation is exactly four reviewers:

1. **Claude** — launched as a focused sub-agent via the Agent tool
2. **Codex** — launched via `mcp__codex__codex`
3. **Gemini** — launched via `mcp__gemini-cli__ask-gemini`
4. **Security** — launched as a focused sub-agent via the Agent tool. Skill selection follows the availability check in "Security reviewer skill selection" below.

All four must be launched in the same parallel batch. Do not launch them sequentially.

A run is not complete until all four reviewer outputs have been collected. Do not produce a triage report from a partial batch.

If a reviewer tool (Claude sub-agent, `mcp__codex__codex`, or `mcp__gemini-cli__ask-gemini`) is unavailable, return `status: blocked` with the tool name and a concrete availability error in `notes`. Do not substitute a different reviewer or reduce the set below four.

The security reviewer is the one exception: if `security:big-toni` is not available, the orchestrator substitutes `plan-executor:lite-security-reviewer` as described below. This substitution is NOT a block — it is the documented fallback.

## Security reviewer skill selection

Before building the four reviewer prompts, decide which skill the security reviewer will use.

1. Check whether `security:big-toni` appears in the current session's available-skills list (the list provided in system-reminders by the harness).
2. If `security:big-toni` is present, use it. This is the preferred path.
3. If `security:big-toni` is NOT present, use `plan-executor:lite-security-reviewer` instead. Record this substitution in the run's `notes` field (e.g. `"security reviewer: lite fallback (security:big-toni not installed)"`).
4. If neither skill is available, return `status: blocked` with `security reviewer unavailable` in `notes`.

Do NOT fall back to a generic sub-agent without a security skill. The security slot must always be filled by one of the two named skills.

## Language detection and Claude recipe skill loading

Before building the Claude reviewer prompt, determine the project language and the matching production-code / test-code recipe skills. The Claude reviewer MUST invoke those skills at the start of its run so the review is anchored to the project's documented code standards.

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

### Claude reviewer prompt obligation

The Claude reviewer prompt MUST include a preamble that tells Claude to invoke every skill in the resolved recipe load list via the Skill tool BEFORE running any review step. Each invocation is for standards context — Claude should treat the returned content as the authoritative rules for its review.

This obligation applies only to the Claude reviewer. Codex, Gemini, and the security reviewer receive recipe context per their existing contracts and do NOT receive the Skill-tool preamble.

## Reviewer Prompt Contract

Build one prompt per reviewer. Each prompt must include:

- the review scope: changed files, plan context, execution summary
- language and recipe context
- prior review context: already-fixed findings, rejected findings, deferred findings
- the reporting contract below

**Claude prompt exception:** The Claude prompt MUST begin with a "Load project recipe skills first" preamble that lists the resolved recipe load list from "Language detection and Claude recipe skill loading" and instructs Claude to invoke each one via the Skill tool before running any review step. If the resolved list is empty (unknown language, or no recipes available for the language), the preamble states that no project recipes were resolved and Claude proceeds without recipe context. Claude reviews the changed files against those loaded standards.

**Gemini prompt exception:** Gemini is invoked via `mcp__gemini-cli__ask-gemini`, a single-shot text-in/text-out MCP call with no filesystem access. The Gemini prompt MUST include the **full diff of every changed file** inline (run `git diff` or equivalent and embed the output). Without the inline diff, Gemini will hallucinate or review stale base content instead of the actual changes. Claude, Codex, and Security sub-agents have filesystem access and can run `git diff` themselves — do NOT embed the diff in their prompts.

**Security reviewer exception:** The security reviewer prompt MUST invoke the skill selected in "Security reviewer skill selection" above as its entry point (use the Skill tool with `skill: "security:big-toni"` or `skill: "plan-executor:lite-security-reviewer"`, depending on availability), providing the review scope and changed files as arguments. When `security:big-toni` is used it does NOT receive the standard recipe list or language context — `security:big-toni` determines its own methodology. When `plan-executor:lite-security-reviewer` is used it receives the review scope, changed files, prior review context, and the reporting contract directly (it has its own built-in checklist, so no recipe list is needed). In both cases the security reviewer MUST receive the prior review context and the reporting contract below so it does not re-raise already-resolved findings.

**Reporting contract to include in every reviewer prompt:**

> Report only findings within the current review scope. For each finding include: file path, line reference if applicable, a concrete description, and your reasoning. Classify every finding as one of:
> - `FIX_REQUIRED` — real, in-scope, must be fixed
> - `VERIFIED_FIX` — a prior FIX_REQUIRED issue that is now correctly fixed
> - `REJECTED` — invalid, out of scope, or based on incorrect assumptions
> - `DEFERRED` — real but intentionally left unresolved (must state reason)
>
> Do not re-raise findings already marked fixed, rejected, or deferred in prior review context unless you have new evidence that invalidates the prior decision. Do not make code changes directly.

## Execution

1. Validate all required inputs are present.
2. Run the security reviewer skill-selection check (see "Security reviewer skill selection"). Record the chosen skill and, if the fallback was selected, add a note to the run for later inclusion in the report.
3. Run the language detection and Claude recipe load-list resolution (see "Language detection and Claude recipe skill loading"). Record the detected language and the final recipe load list. Add notes for any missing mapped skills.
4. Build one reviewer prompt per reviewer using the contract above.
5. Launch all four reviewers in a single parallel batch:
   - Claude sub-agent via Agent tool (subagent_type: general-purpose)
   - Codex via `mcp__codex__codex`
   - Gemini via `mcp__gemini-cli__ask-gemini`
   - Security sub-agent via Agent tool (subagent_type: general-purpose), invoking either `security:big-toni` or `plan-executor:lite-security-reviewer` based on the skill-selection check
6. Wait for all four outputs before proceeding.
7. Triage every finding from every reviewer into exactly one bucket:
   - `FIX_REQUIRED`
   - `VERIFIED_FIX`
   - `REJECTED`
   - `DEFERRED`
   - Deduplicate across reviewers: if multiple reviewers raise the same issue, merge into one finding and note that N reviewers agreed.
8. Produce the review report (see Completion Contract).

## Completion Contract

Return one structured report with these fields:

- `status` — `complete` | `blocked`
- `reviewer_set` — list of the four reviewers used. For the security reviewer entry, record the actual skill used (`security:big-toni` or `plan-executor:lite-security-reviewer`).
- `attempt_note` — free-text note about this run (e.g. first attempt, retry N). MUST mention the lite fallback when it was selected, the detected language, and any skipped Claude recipes.
- `detected_language` — the resolved project language (`typescript` | `python` | `go` | `rust` | `unknown`).
- `claude_recipes_loaded` — list of recipe skill names actually included in the Claude preamble.
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

### `status: complete`
All four reviewers ran and produced output. Triage is complete. `findings` and `triage_summary` are populated.

### `status: blocked`
A required tool was unavailable or a required input was missing. `findings` and `triage_summary` may be empty or partial. `notes` must contain the exact blocker.
