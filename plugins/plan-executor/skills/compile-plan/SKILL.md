---
name: plan-executor:compile-plan
description: Use ONLY when the orchestrator or a tooling subprocess needs to transform a plan-executor plan markdown file into a schema-validated `tasks.json` manifest + per-task prompt files. One-shot compiler. No phase transitions, no state management, no handoff emission.
argument-hint: [plan-path] [schema-path] [output-dir] [meta-json-path]
---

<SUBAGENT-STOP>
If you were dispatched as a subagent to execute a specific task, skip this skill.
This skill is ONLY invoked by the plan-executor `execute` command as a pre-compile step.
</SUBAGENT-STOP>

## Arguments

- `$1` — absolute path to the plan markdown file. Required.
- `$2` — absolute path to `tasks.schema.json`. Required.
- `$3` — absolute output directory for `tasks.json` and `tasks/*.md`. Required. Created if missing.
- `$4` — absolute path to the `meta.json` sidecar produced by `plan-executor:handover`. Required.

# Task: compile a plan-executor plan into a tasks.json manifest

You are a compiler. Your only job is to transform a plan markdown document into a structured manifest plus one prompt file per task, then exit. You do not execute anything. You do not track state. You do not invoke helpers. You are not an orchestrator.

## Inputs

Three files are provided:

1. `<plan-path>` — a plan-executor plan markdown file. Contains a header with metadata and numbered tasks in prose.
2. `<schema-path>` — the JSON Schema for the output manifest (`tasks.schema.json`).
3. `<meta-json-path>` — the metadata sidecar produced by `plan-executor:handover`. Authoritative source for `goal`, `type`, `jira`, `target_repo`, `target_branch`, `flags`, and `plan.path`.

Your output directory is `<output-dir>`. Create it if it does not exist. Write:

- `<output-dir>/tasks.json` — the manifest.
- `<output-dir>/tasks/task-<id>.md` — one prompt file per task, one file per entry in `tasks` of the manifest.

## Procedure

Work in four passes over the plan. Do not interleave them.

### Pass 1 — Load metadata from `meta.json`

Read `$4` (the meta-json-path passed by `plan-executor:handover`). Parse it and verify required fields are present: `plan_path`, `goal`, `type`, `flags` (all six booleans). If any required field is missing, exit with a deterministic error of the form:

```
COMPILE_ERROR: meta.json missing required field <field-name>
```

Use `meta.json` as the authoritative source for: `goal`, `type`, `jira`, `target_repo`, `target_branch`, `flags`. Do NOT re-parse plan markdown headers — `handover` already collected this metadata. Do NOT ask for any clarification — this is a one-shot transformer.

The `plan_path` value becomes the manifest's `plan.path` field. The manifest's `plan.status` is initialized to `"READY"`.

### Pass 2 — Task extraction

Walk the plan body. For each numbered task you find, create an entry in the `tasks` object:

- **task_id** — use the plan's own numbering if present (`1.1`, `2.3`, `7.1`), otherwise assign sequential strings `"1"`, `"2"`, … Preserve the plan's numbering exactly.
- **prompt_file** — `tasks/task-<id>.md` (relative path).
- **agent_type** — `claude` by default. Use `codex` or `gemini` ONLY if the plan explicitly names them for a task (e.g. a reviewer task that says "run codex"). Use `bash` ONLY if the task is purely a shell script (no LLM reasoning). Valid values: `claude`, `codex`, `gemini`, `bash`. No other values are accepted — the Rust scheduler will reject unknowns.
- **can_fail** — `false` by default. `true` only for reviewer-diversity tasks where plan explicitly marks the task as optional.
- **description** — a one-line human summary of what the task does. Used by humans inspecting the compiled manifest.

For each task, also write `<output-dir>/tasks/task-<id>.md`. The prompt file content is the TASK'S OWN BODY — the implementation instructions, acceptance criteria, and any prescribed code blocks from the plan. Copy verbatim from the plan where possible. Do not summarize. Do not add your own framing. Do not strip code blocks. The sub-agent receiving this file must be able to execute the task from this file alone, without re-reading the plan.

Tasks that are pure orchestrator-responsibilities (e.g. "create the worktree", "open the PR", "write the summary") must NOT appear in `tasks`. Those are handled by the Rust scheduler and helper skills, not by sub-agents. Skip them silently.

### Pass 3 — Wave decomposition

Group tasks into waves. A wave is a set of task_ids that run in parallel. Waves are ordered; a wave starts only when every wave in its `depends_on` list has completed.

Decomposition rules, in priority order:

1. If the plan declares explicit deps (`**depends:** 1.1, 1.2` or similar), honor them verbatim.
2. Otherwise, infer deps from the plan's prose:
   - A task that reads/modifies the same file as another task in the same phase → put them in separate waves, earlier one first.
   - A task that references "after X completes" or "once X is in place" → add X's wave to its `depends_on`.
   - A task that explicitly says "in parallel with Y" → put them in the same wave.
3. When in doubt, prefer fewer waves with more parallelism. Don't over-sequence.
4. A single wave should not exceed 5 parallel tasks. If a wave would have >5 tasks, split into two sibling waves with matching `depends_on`.

Wave IDs start at 1 and are dense (1, 2, 3, …). Use IDs >= 100 ONLY for fix waves appended in later compile passes (not applicable here — this is the initial compile).

### Pass 4 — Emit + validate

Write `<output-dir>/tasks.json` with the full manifest.

The `plan` object inside the manifest now carries the new fields:

```json
{
  "version": 1,
  "plan": {
    "goal": "...",
    "type": "feature",
    "jira": "",
    "target_repo": null,
    "target_branch": null,
    "path": "<absolute-plan-path-from-meta.json>",
    "status": "READY",
    "flags": { /* six booleans */ }
  },
  "waves": [...],
  "tasks": {...}
}
```

`plan.path` MUST be the `plan_path` value read from `meta.json`. `plan.status` MUST be the literal string `"READY"`. The schema rejects manifests that omit either field.

Before exiting, verify:

- The JSON parses.
- Every `task_id` in `waves[].task_ids` exists in `tasks`.
- Every `depends_on` ID references an existing wave.
- The wave DAG is acyclic.
- Every `tasks[].agent_type` is in `{claude, codex, gemini, bash}`.
- Every `tasks[].prompt_file` path exists on disk under `<output-dir>/`.
- `version` is `1`.
- `plan.path` is a non-empty string and `plan.status` is `"READY"`.

If any check fails, fix it and rewrite the manifest. Do not exit with an invalid manifest.

## Output contract

When done, print ONE line to stdout:

```
COMPILED: <output-dir>/tasks.json
```

Then exit. Do not print the manifest content, do not narrate, do not summarize. The scheduler reads the file itself.

## What you MUST NOT do

- Do not execute any task.
- Do not run `cargo`, `npm`, `gh`, or any command from the plan.
- Do not write a state file (`.tmp-execute-plan-state.json`).
- Do not emit `call sub-agent` lines.
- Do not invoke any `plan-executor:*` skill.
- Do not reason about phases beyond wave decomposition. Phase 5 code-review, Phase 6 validation, Phase 7 PR creation are the Rust scheduler's concern, not yours.
- Do not include orchestrator-only tasks (worktree setup, PR creation, summary writing) in `tasks`.
