---
name: plan-executor:handover
description: Use ONLY when a plan needs to be ingested into the plan-executor pipeline. Detects the source format (superpowers, plan-executor markdown with flag headers, Claude Code planning output, plain markdown, GitHub issue text), collects executor metadata interactively when missing, writes a meta.json sidecar consumable by plan-executor:compile-plan, and finally asks the user how to run the plan in two short passes (engine — plan-executor or superpowers — then mode within that engine) before dispatching to the chosen executor.
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

`execution_mode` is intentionally NOT collected here. Pass 5's mode question (in-session sub-agents / non-interactive local / non-interactive remote / superpowers variants) covers the same information; collecting it twice would be redundant. The compiled manifest defaults `plan.execution_mode` to `"local"`, and Pass 5's Mode 3 dispatch flips it to `"remote"` directly in `tasks.json` after compile-plan runs.

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

This line is the contract for any downstream consumer parsing handover output (e.g. an automation that pipes `plan-executor:handover` into `plan-executor:compile-plan` directly). Do not print other text on the same line.

After printing the contract line, continue into Pass 5.

### Pass 5 — Choose execution mode

Handover ingestion is done; the plan is ready to execute. Choose the executor in two short passes (engine, then mode), then dispatch. Splitting the question keeps every `AskUserQuestion` call comfortably under the tool's 4-option cap and lets each pass surface mode-specific descriptions instead of cramming five disparate options into one prompt.

**5a. Detect whether `superpowers` is available.**

Use `Glob` to check for `~/.claude/plugins/cache/claude-plugins-official/superpowers/*/skills/subagent-driven-development/SKILL.md`. The result decides whether Pass 5b runs at all.

**5b. Ask which engine to use (skip when superpowers is not installed).**

If superpowers was detected, ask via `AskUserQuestion`:

> *"Which executor should run this plan?"*
>
> 1. **plan-executor** — the executor for this skill family; offers in-session sub-agent orchestration, daemon-driven local runs, and GHA-based remote runs.
> 2. **superpowers** — Anthropic's general-purpose plan executor; offers inline-serial and sub-agent-driven variants.

If superpowers was NOT detected, skip this pass entirely and treat the engine as `plan-executor`.

**5c. Ask the mode within the chosen engine.**

If the engine is `plan-executor`, ask:

> *"How do you want to run this plan with plan-executor?"*
>
> 1. **In-Session** — `plan-executor:execute-plan` runs inside this Claude session; the orchestrator dispatches focused sub-agents per task wave.
> 2. **Daemon** — submits to the local plan-executor daemon. The daemon owns scheduling, persistence, and output streaming; tail with `plan-executor output -f <job-id>`.
> 3. **Remote** — submits to the configured remote execution repo. GitHub Actions runs the plan on a runner; the user tracks progress via the execution PR.

If the engine is `superpowers`, ask:

> *"How do you want to run this plan with superpowers?"*
>
> 1. **subagent-driven-development** (recommended) — dispatches focused sub-agents per task. Recommended on Claude Code where sub-agents are always available.
> 2. **executing-plans** — runs serially in this session. Choose this only when sub-agent dispatch would interfere with another in-flight workflow.

Use the verbatim superpowers skill names (`subagent-driven-development`, `executing-plans`) as labels — they're how superpowers identifies its own skills, and matching them keeps the dispatch step (which calls those skills by exact name) unambiguous.

**5d. Dispatch based on the engine + mode pair.**

For every plan-executor mode you MUST first compile the plan: invoke the `plan-executor:compile-plan` skill with the meta.json path written in Pass 3. It produces `<plan-dir>/tasks/tasks.json`. The compiled manifest carries `plan.execution_mode` (always `"local"` from compile-plan); the remote mode flips it to `"remote"` after compile. The plan markdown is NOT read for execution flags any more.

Binary command convention:
  - `plan-executor execute <tasks.json>` (no `--foreground`) → submits to the local daemon for normal execution.
  - `plan-executor execute <tasks.json> --foreground` → reads `plan.execution_mode` from the manifest; when `"remote"` the binary routes to `trigger_remote` (push plan + job-spec to the configured `remote_repo`, open execution PR; GHA runs `plan-executor execute` on a runner). The `--foreground` flag is the dispatch path used for remote submission, NOT a local-execution alternative.

- **plan-executor / In-Session** — Invoke the `plan-executor:execute-plan` skill, passing `--compiled-manifest <tasks.json>`. That skill becomes the orchestrator and takes over from here.
- **plan-executor / Daemon** — Run `plan-executor execute <tasks.json>` via `Bash`. The CLI submits to the daemon and returns the job id; tail with `plan-executor output -f <job-id>` if live output is wanted. Daemon must be running — if not, `plan-executor ensure` starts it.
- **plan-executor / Remote** — After compile-plan finishes, flip the manifest's execution mode to remote, then run via the foreground dispatch path:
  - Edit `tasks.json` to set `"execution_mode": "remote"` inside the `plan` object. Find the line `"execution_mode": "local"` (compile-plan wrote it) and replace `"local"` with `"remote"`. Use the `Edit` tool.
  - Run `plan-executor execute <tasks.json> --foreground` synchronously via `Bash`. The binary reads `plan.execution_mode = "remote"` and submits to the configured execution repo.

  Prerequisite: `~/.plan-executor/config.json` must contain `remote_repo`. If absent, the binary exits with `remote execution requires 'remote_repo' in config — run 'plan-executor remote-setup'`. Surface that error to the user verbatim.

- **superpowers / subagent-driven-development** — Invoke the `superpowers:subagent-driven-development` skill, passing the original plan markdown path (NOT meta.json — superpowers reads the plan directly).
- **superpowers / executing-plans** — Invoke the `superpowers:executing-plans` skill, passing the original plan markdown path.

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
