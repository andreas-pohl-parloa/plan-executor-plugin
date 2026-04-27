---
name: plan-executor:handover
description: Use ONLY when a plan needs to be ingested into the plan-executor pipeline. Detects the source format (superpowers, plan-executor markdown with flag headers, Claude Code planning output, plain markdown, GitHub issue text), collects executor metadata interactively when missing, and writes a meta.json sidecar consumable by plan-executor:compile-plan.
argument-hint: [plan-path] [--type=<feature|bug|refactor|chore|docs|infra>] [--no-worktree] [--no-pr] [--draft-pr] [--merge] [--merge-admin] [--target-repo=<owner/repo>] [--target-branch=<branch>] [--jira=<TICKET>]
---

<SUBAGENT-STOP>
If you were dispatched as a subagent to execute a specific task, skip this skill.
This skill is invoked at the top of the plan-executor pipeline, never inside an execution.
</SUBAGENT-STOP>

# Task: ingest a plan into the plan-executor pipeline

You are a one-shot ingestor. Your job is to detect the format of an arbitrary plan document, collect any missing executor metadata, write a `meta.json` sidecar next to the plan, and emit a single deterministic stdout line so the next pipeline stage (`plan-executor:compile-plan`) can consume the metadata. You do NOT compile, schedule, or execute anything.

## Arguments

- `$1` — absolute path to the plan markdown file. Required.
- Remaining flags (any order, all optional):
  - `--type=<feature|bug|refactor|chore|docs|infra>`
  - `--no-worktree` / `--no-pr` / `--draft-pr` / `--merge` / `--merge-admin`
  - `--target-repo=<owner/repo>`
  - `--target-branch=<branch>`
  - `--jira=<TICKET>`
  - `--non-interactive` (fail with deterministic error instead of asking for missing fields)

## Procedure

Run four passes in order. Do not interleave.

### Pass 1 — Format detection

Read `$1`. Inspect for known patterns:

- **plan-executor format**: presence of `**Goal:**`, `**Type:**`, optional flag headers (`**no-worktree:** [ ]`, `**no-pr:** [ ]`, `**draft-pr:** [ ]`, `**merge:** [ ]`, `**merge-admin:** [ ]`). Treat any present header as a default. If every required field is recoverable from headers/CLI flags, run non-interactively even without `--non-interactive`.
- **Superpowers format**: presence of `## Goal`, `## Acceptance Criteria`, `## Tasks` headings. Extract the goal from the first paragraph under `## Goal`. Defaults: `type=feature`, all flags false.
- **Claude Code planning output**: numbered task list with no front-matter headers. Defaults; ask the user for missing fields.
- **Plain markdown / GitHub issue body**: even less structure. Ask the user for everything not provided as a CLI flag.

### Pass 2 — Metadata collection

For each missing field, ask via `AskUserQuestion` when interactive, or fail with a deterministic error when `--non-interactive` is set or when stdin is not a TTY.

Required fields (snake_case):

- `goal` (string, required) — extract from `**Goal:**` or first paragraph; otherwise ask.
- `type` (enum: `feature` / `bug` / `refactor` / `chore` / `docs` / `infra`) — extract from `**Type:**` or `--type=`; otherwise ask.
- `jira` (string, may be empty) — extract from `**JIRA:**` / `**Ticket:**` or `--jira=`; otherwise ask. Normalize the extracted/answered value: if it case-insensitively matches `none`, `n/a`, `null`, or `tbd`, emit `""` instead. The downstream `tasks.json` schema constrains this field to `^([A-Z][A-Z0-9]+-[0-9]+|)$` (ticket ID or empty), so any non-ticket sentinel must collapse to the empty string before being written into `meta.json`.
- `target_repo` (string `owner/repo` or null) — extract from a `**target_repo:**` header or `--target-repo=`; otherwise ask. Null when local-only.
- `target_branch` (string or null) — extract from a `**target_branch:**` / `**branch:**` header or `--target-branch=`; otherwise ask. Null when local-only.
- `flags` — six booleans: `merge`, `merge_admin`, `skip_pr`, `skip_code_review`, `no_worktree`, `draft_pr`.
  - Default each flag to `false`.
  - Override from header checkbox `[x]` when present.
  - Override from CLI flag (e.g. `--no-worktree` sets `no_worktree=true`, `--no-pr` sets `skip_pr=true`).
  - When interactive, ask only for flags that were not extracted from header or CLI.

### Pass 3 — Emit meta.json

Write `<plan-path>.meta.json` (same directory as the plan, filename = plan filename + `.meta.json`) with exactly this shape:

```json
{
  "plan_path": "<absolute-path-to-plan.md>",
  "goal": "...",
  "type": "feature",
  "jira": "",
  "target_repo": null,
  "target_branch": null,
  "flags": {
    "merge": false,
    "merge_admin": false,
    "skip_pr": false,
    "skip_code_review": false,
    "no_worktree": false,
    "draft_pr": false
  }
}
```

`plan_path` MUST be the absolute, resolved (symlink-followed) path of `$1`. Booleans MUST be JSON booleans, not strings. Empty/absent strings emit `""` or `null` per their schema position above.

If the file already exists, overwrite it (handover is idempotent).

### Pass 4 — Output contract

Print exactly one line on stdout:

```
HANDOVER: <absolute-path-to-meta.json>
```

Then exit. The next pipeline stage (`plan-executor:compile-plan`) reads the meta.json path from this line. Do not print anything else after this line — additional output corrupts the pipeline contract.

## Errors

If any required field cannot be resolved (extracted, supplied via CLI flag, or answered interactively), exit non-zero with a single line on stderr:

```
HANDOVER_ERROR: missing required field <field-name>
```

If the plan path does not exist or is not readable, exit with:

```
HANDOVER_ERROR: plan not found at <path>
```
