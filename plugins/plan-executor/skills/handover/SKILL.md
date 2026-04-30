---
name: plan-executor:handover
description: Use ONLY when a plan needs to be ingested into the plan-executor pipeline. Detects the source format (superpowers, plan-executor markdown with flag headers, Claude Code planning output, plain markdown, GitHub issue text), collects executor metadata interactively when missing, writes a meta.json sidecar consumable by plan-executor:compile-plan, and finally asks the user which execution mode to dispatch (in-session sub-agents / non-interactive local / non-interactive remote, plus superpowers inline / sub-agent modes when superpowers is installed).
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
- `execution_mode` (enum: `local` / `remote`, default `local`) — determines whether the Rust binary executes the plan in-process or submits it to the configured `remote_repo` for GitHub Actions to run. Default to `local`. Pass 5 may flip it to `remote` based on the user's mode selection. Do NOT extract this from the plan markdown — `**execution:**` plan-markdown headers are no longer read by the binary; the manifest is the source of truth.

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
  "execution_mode": "local",
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

This line is the contract for any downstream consumer parsing handover output (e.g. an automation that pipes `plan-executor:handover` into `plan-executor:compile-plan` directly). Do not print other text on the same line.

After printing the contract line, continue into Pass 5.

### Pass 5 — Choose execution mode

Handover ingestion is done; the plan is ready to execute. Ask the user how they want to run it, then dispatch.

**5a. Detect whether `superpowers` is available.**

Use `Glob` to check for the path pattern `~/.claude/plugins/cache/claude-plugins-official/superpowers/*/skills/executing-plans/SKILL.md`. If at least one match exists, superpowers is available and you must offer modes 4 + 5. Otherwise restrict the question to modes 1 – 3.

**5b. Ask via `AskUserQuestion`.**

The single question is *"How do you want to run this plan?"*. Options (label / description) — present in this order, including 4 + 5 only when superpowers was detected:

1. **plan-executor (in-session, sub-agents)** — runs `plan-executor:execute-plan` inside this Claude session; the orchestrator dispatches focused sub-agents per task wave.
2. **plan-executor (non-interactive local)** — compiles the plan and runs `plan-executor execute --compiled-manifest <path>` synchronously in a foreground shell. No sub-agents in this session; the Rust scheduler drives the Claude/Codex/Gemini CLIs directly.
3. **plan-executor (non-interactive remote)** — compiles the plan and submits it to the GitHub Actions execution repo via the existing `kind: plan` flow (push `plan.md` + `job-spec.json`, open execution PR, GHA runs `plan-executor execute` on a runner).
4. *(superpowers only)* **superpowers (inline)** — hand the original plan markdown to `superpowers:executing-plans` and let it execute serially in this session.
5. *(superpowers only)* **superpowers (sub-agents)** — hand the original plan markdown to `superpowers:subagent-driven-development` (the sub-agent-driven variant of executing-plans).

**5c. Dispatch based on the answer.**

For every plan-executor mode (1, 2, 3) you MUST first compile the plan: invoke the `plan-executor:compile-plan` skill with the meta.json path written in Pass 3. It produces `<plan-dir>/tasks/tasks.json`. The manifest's `plan.execution_mode` field is the binary's source of truth for local vs. remote dispatch — `compile-plan` propagates that field from `meta.json`. The plan markdown is NOT read for execution flags any more.

For Mode 3, before invoking compile-plan, rewrite `meta.json` to set `"execution_mode": "remote"` (the rest of the document stays as written in Pass 3). Use the `Edit` or `Write` tool. Modes 1 and 2 leave `execution_mode` at its default `"local"`.

How the binary dispatches: `plan-executor execute <tasks.json> --foreground` reads `plan.execution_mode` from the manifest. When it equals `"remote"`, the binary routes to `trigger_remote` (push plan + job-spec to the configured `remote_repo`, open execution PR; GHA runs `plan-executor execute` on a runner). The `PLAN_EXECUTOR_LOCAL=1` env var force-overrides to local for cases where you want to run a remote-tagged manifest locally without rewriting it. Modes 2 and 3 use the **same command** — only the manifest's `execution_mode` differs.

- **Mode 1** — Invoke the `plan-executor:execute-plan` skill, passing `--compiled-manifest <tasks.json>`. That skill becomes the orchestrator and takes over from here.
- **Mode 2 (non-interactive local)** — Run `PLAN_EXECUTOR_LOCAL=1 plan-executor execute <tasks.json> --foreground` synchronously via `Bash`. The env var forces local even if `execution_mode` says remote. Stream output; do not background.
- **Mode 3 (non-interactive remote)** — Edit `meta.json` to set `execution_mode: "remote"`, re-run `plan-executor:compile-plan` so the manifest reflects the change, then run `plan-executor execute <tasks.json> --foreground` synchronously via `Bash`. The binary reads `plan.execution_mode = "remote"` and submits to the configured execution repo.

  Prerequisite: `~/.plan-executor/config.json` must contain `remote_repo`. If absent, the binary exits with `remote execution requires 'remote_repo' in config — run 'plan-executor remote-setup'`. Surface that error to the user verbatim.

- **Mode 4** — Invoke the `superpowers:executing-plans` skill, passing the original plan markdown path (NOT meta.json — superpowers reads the plan directly).
- **Mode 5** — Invoke the `superpowers:subagent-driven-development` skill, passing the original plan markdown path.

In all modes, after dispatching you yield control to the chosen executor. Do not continue with handover-level reporting; the executor's own contract takes over.

## Errors

If any required field cannot be resolved (extracted, supplied via CLI flag, or answered interactively), exit non-zero with a single line on stderr:

```
HANDOVER_ERROR: missing required field <field-name>
```

If the plan path does not exist or is not readable, exit with:

```
HANDOVER_ERROR: plan not found at <path>
```
