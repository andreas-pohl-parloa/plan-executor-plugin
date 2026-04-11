---
name: plan-executor:superpowers-plan-handover
description: Use when a Superpowers plan should be handed over into the my-plugin execution flow.
argument-hint: [superpowers-plan-path]
---

# superpowers-plan-handover

You hand over a Superpowers plan to the chosen execution mode. For Superpowers execution, you hand off directly without migration. For Plan-Executor mode, you convert the plan into a `.my/plans/` execution-ready plan and then offer execution options.

You do NOT implement product code. You only migrate the plan (when applicable), preserve its content, add the required execution flags, and hand off to the correct executor.

The initial plan input is: $ARGUMENTS

## Required outcome — Superpowers execution path

1. Resolve the source Superpowers plan file.
2. Ask the user which Superpowers executor to use (Subagent-Driven or Inline Execution).
3. Report the handoff and stop.

## Required outcome — Plan-Executor path

1. Resolve the source Superpowers plan file.
2. Ask about the JIRA ticket using the same approach as `my:plan`.
3. Convert it into a plan file under `.my/plans/`.
4. Preserve the existing plan title, goal, architecture, tech stack, and plan body as much as possible.
5. Ensure the migrated plan contains these execution headers near the top of the file:
   - `**Status:** READY`
   - `**no-worktree:** [ ]`
   - `**no-pr:** [ ]`
   - `**draft-pr:** [ ]`
   - `**merge:** [ ]`
   - `**merge-admin:** [ ]`
6. Offer these execution options after the migrated plan is written:
   - Plan-Executor Interactive (in session with sub-agents)
   - Plan-Executor Local (on this machine)
   - Plan-Executor Remote (via GitHub Actions)

## Execution mode decision

After resolving the source plan file, you MUST ask the user which execution mode to use before any migration or JIRA handling.

Use `AskUserQuestion` with:
- Question: "How do you want to execute this plan?"
- Options:
  - `Superpowers execution` — Run directly via Superpowers skills (no migration)
  - `Plan-Executor` — Migrate the plan and run via plan-executor pipeline

### Superpowers execution path

If the user selects `Superpowers execution`:

1. Do NOT migrate the plan. Do NOT ask about JIRA. Do NOT ask about execution flags.
2. Ask the user which Superpowers executor to use with `AskUserQuestion`:
   - Question: "Which Superpowers executor?"
   - Options:
     - `Subagent-Driven` — Use `superpowers:subagent-driven-development`
     - `Inline Execution` — Use `superpowers:executing-plans`
3. Report the handoff and stop. Follow the executor handoff rules below.

### Plan-Executor path

If the user selects `Plan-Executor`:

Continue with JIRA handling, plan migration, execution flags, and execution options as described in the sections below.

## JIRA ticket

JIRA handling is mandatory. It only applies to the Plan-Executor path.

Before execution flags or execution choices, you MUST ask the user about JIRA using the same approach as `my:plan`.

Use `AskUserQuestion` with:
- Question: "Do you have a JIRA ticket for this work?"
- Options:
  - `Yes, I have a ticket`
  - `Create one after planning`
  - `No ticket needed`

Rules:
- Never trust or reuse the source Superpowers plan's JIRA field without asking the user.
- If the user has a ticket, ask for the exact ticket value and write `**JIRA:** <ticket>`.
- If the user chose `Create one after planning`, write `**JIRA:** TO-BE-CREATED`.
- If the user chose `No ticket needed`, write `**JIRA:** none`.
- After updating the migrated plan, re-read it and verify the header contains the exact chosen JIRA value.
- Do not continue until JIRA has been written and verified.
- Do not ask execution-flag questions or execution-choice questions before JIRA verification passes.

The migrated plan header must contain exactly one of these outcomes before the next phase starts:
- `**JIRA:** <ticket>`
- `**JIRA:** TO-BE-CREATED`
- `**JIRA:** none`

If verification fails, fix the migrated file before continuing.

JIRA handling always happens after source-plan resolution and before execution-flag handling.

Skipping the JIRA step is not allowed.

If the JIRA step has not completed, the handover is not complete.

Do not proceed with stale, inferred, copied, or ambiguous JIRA state.

That behavior is required.
## Plan migration rules

### Source plan resolution

- If `$ARGUMENTS` contains a plan path, use it.
- If no path is provided, search `docs/superpowers/plans/` for candidate plan files.
- If exactly one plausible plan exists, use it.
- If multiple plausible plans exist, ask the user to choose with `AskUserQuestion`.
- Stop with a deterministic error if the chosen source file does not exist or cannot be read.

### Target path

- The migrated file MUST live in `.my/plans/`.
- Reuse the source filename stem when possible.
- Prefer a path of the form `.my/plans/plan-<normalized-source-name>.md`.
- If that exact target path already exists and is not the intended file for this run, create a unique suffixed filename instead of overwriting silently.

### Migration format

Transform the Superpowers plan into a my-plan-compatible header while keeping the existing Superpowers structure and content below the header.

The migrated file MUST begin with this header shape:

```md
# <Original Title>

**Goal:** <goal line from source plan>
**Type:** Feature
**JIRA:** none
**Tech Stack:** <tech stack line from source plan, or "unknown">
**Code Standards:** n/a
**Status:** READY
**no-worktree:** [ ]
**no-pr:** [ ]
**draft-pr:** [ ]
**merge:** [ ]
**merge-admin:** [ ]
**non-interactive:** [ ]

---
```

Migration requirements:

- Preserve the original title.
- Preserve the original `**Goal:**` if present. If missing, derive it from the Superpowers goal section.
- Preserve the original `**Tech Stack:**` if present. If missing, infer a concise value from the plan text when possible, otherwise use `unknown`.
- Set `**Type:** Feature` unless the source plan clearly states a different type in its header. If it does, preserve that type.
- Set `**JIRA:** none` unless the source plan already contains a clear ticket value.
- Set `**Code Standards:** n/a` unless the source plan already contains that field.
- Replace any existing status line with `**Status:** READY`.
- Add any missing execution-flag headers, including `**non-interactive:** [ ]`.
- Remove the Superpowers execution banner block that begins with `> **For agentic workers:** REQUIRED SUB-SKILL:` so the migrated plan no longer instructs execution through Superpowers skills.
- Keep the remaining plan body intact after the header separator.

When removing the execution banner:
- remove the full quoted block, not just the first line
- remove any immediately attached execution-only continuation text that belongs to that banner
- do not remove normal plan content such as goal, architecture, tech stack, tasks, files, or verification steps
- ensure the migrated document does not mention `superpowers:subagent-driven-development` or `superpowers:executing-plans` in the carried-over plan body

If those strings still exist after migration, rewrite the affected carried-over section so execution guidance points to the migrated `.my/plans/...` flow instead of Superpowers execution skills.

The migrated plan must not contain stale Superpowers execution instructions.

If execution-related cleanup changes the carried-over body, re-read the migrated file and verify the remaining plan content is still coherent.

### Validation after migration

After writing the migrated file, read it back and verify:

- it is under `.my/plans/`
- it contains all required execution flags
- it contains `**Status:** READY`
- the original plan body is still present

If validation fails, fix the migrated file before continuing.

After applying the user-selected execution flags, read the migrated file again and verify that the selected flags now use `[x]` and all unselected flags remain `[ ]`. This includes `non-interactive`, which is set to `[x]` only when the user selects "Plan-Executor Local" or "Plan-Executor Remote" in the execution options step. The `**execution:** remote` header is added only when the user selects "Plan-Executor Remote".

If that verification fails, fix the migrated file before presenting execution choices.

## Execution flags

After the migrated plan is validated, you MUST ask about execution flags using the same approach as `my:plan`.

Use **two** `AskUserQuestion` calls:

### Question 1

- Question: "Which execution flags should be enabled?"
- multiSelect: true
- Options:
  - `no-worktree` — Skip creating a git worktree and run directly in the current working directory
  - `no-pr` — Skip creating a pull request after implementation
  - `draft-pr` — Create a draft PR instead of a ready-for-review PR

Rules:
- For each selected flag, update the migrated plan header by replacing `**<flag>:** [ ]` with `**<flag>:** [x]`.
- Leave unselected flags as `[ ]`.

### Question 2

- Skip this question if `no-pr` or `draft-pr` were enabled.
- Question: "Do you want to enable auto-merge?"
- multiSelect: false
- Options:
  - `merge` — Merge after the PR has been finalized
  - `merge-admin` — Merge with `--admin` after the PR has been finalized

Rules:
- If `merge` is selected, update `**merge:** [ ]` to `**merge:** [x]`.
- If `merge-admin` is selected, update `**merge-admin:** [ ]` to `**merge-admin:** [x]`.
- Leave all unselected flags as `[ ]`.

## Execution options

Only after the execution flags have been applied to the migrated `.my/plans/...` file, present these three options with `AskUserQuestion`:

- Question: "Which execution mode?"
- Options:
  1. `Plan-Executor Interactive` — In session with sub-agents
  2. `Plan-Executor Local` — Non-interactive on this machine
  3. `Plan-Executor Remote` — Non-interactive on a remote machine

Option details:

1. **Plan-Executor Interactive**
   - Run `plan-executor:execute-plan` with the converted plan document
2. **Plan-Executor Local**
   - Run via `plan-executor execute <migrated-plan-path>` (the daemon handles execution)
3. **Plan-Executor Remote**
   - Before reporting the handoff, add the header `**execution:** remote` to the migrated plan (after the `**non-interactive:**` line)
   - Re-read the file and verify the header is present
   - Run via `plan-executor execute <migrated-plan-path>` (detects the remote header and triggers GitHub Actions execution)

## Executor handoff rules

For skill-based execution paths, this skill MUST automatically invoke the executor skill after reporting the selection. For CLI-based execution paths (plan-executor execute), report the command and stop so the user can launch it themselves.

### Superpowers: Subagent-Driven

Report:
> Selected: **Superpowers — Subagent-Driven**
> Plan: `<source-plan-path>`

Then immediately invoke `superpowers:subagent-driven-development` with the source plan path using the Skill tool.

### Superpowers: Inline Execution

Report:
> Selected: **Superpowers — Inline Execution**
> Plan: `<source-plan-path>`

Then immediately invoke `superpowers:executing-plans` with the source plan path using the Skill tool.

### Plan-Executor Interactive

Report:
> Selected: **Plan-Executor Interactive** (in session with sub-agents)
> Plan: `<migrated-plan-path>`

Then immediately invoke `plan-executor:execute-plan` with the migrated plan path using the Skill tool.

### Plan-Executor Local

Before launching, update the migrated plan by replacing `**non-interactive:** [ ]` with `**non-interactive:** [x]`, then re-read the file and verify the flag is set.

Run `plan-executor execute <migrated-plan-path>` via the Bash tool.

Then report and stop:
> Selected: **Plan-Executor Local**
> Plan: `<migrated-plan-path>`
> Job is running locally. The plan-executor daemon handles execution from here.

Do NOT invoke any skill. Do NOT wait for the job to finish.

### Plan-Executor Remote

Before launching:
1. Update the migrated plan by replacing `**non-interactive:** [ ]` with `**non-interactive:** [x]`.
2. Add the header `**execution:** remote` on the line immediately after `**non-interactive:** [x]`.
3. Discover marketplaces and plugins (see below), then add these headers after the `**execution:** remote` line:
   - `**add-marketplaces:** <comma-separated list>`
   - `**add-plugins:** <comma-separated list>`
4. Re-read the file and verify all four headers are present: `**non-interactive:** [x]`, `**execution:** remote`, `**add-marketplaces:**`, and `**add-plugins:**`.

#### Discovering marketplaces

Run `claude plugin marketplace list` and parse the output. Build a comma-separated list of GitHub slugs:

- For entries with `Source: GitHub (<slug>)`, use the slug directly (e.g., `anthropics/claude-plugins-official`).
- For entries with `Source: Directory (<path>)`, run `git -C <path> remote get-url origin` to extract the GitHub slug. Parse the slug from the remote URL (strip `git@github.com:` or `https://github.com/` prefix and `.git` suffix).
- If a directory source has no git remote, skip it.

The list MUST include at least `andreas-pohl-parloa/plan-executor-plugin`. If it is not already in the discovered list, append it.

#### Discovering plugins

Run `claude plugin list` and parse the output. Build a comma-separated list of `<plugin>@<marketplace>` entries, including only plugins with `Status: ✔ enabled`.

The list MUST include at least `plan-executor@plan-executor`. If it is not already in the discovered list, append it.

#### Header format

Example:
```
**add-marketplaces:** anthropics/claude-plugins-official, andreas-pohl-parloa/plan-executor-plugin, JuliusBrussee/caveman
**add-plugins:** superpowers@claude-plugins-official, plan-executor@plan-executor, security@claudes-kitchen
```

#### Push all local commits before launching

The remote runner clones the repo at the current HEAD. If local commits have not been pushed, the runner will fail with `fatal: unable to read tree`.

Before calling `plan-executor execute`, ensure HEAD is available on the remote:

1. Run `git log @{upstream}..HEAD --oneline 2>/dev/null` to check for unpushed commits.
2. If there are unpushed commits, run `git push` and wait for it to succeed. If the push fails, stop and print the error.
3. Only after the push succeeds (or no unpushed commits exist), proceed to launch.

Run `plan-executor execute <migrated-plan-path>` via the Bash tool.

Then report and stop:
> Selected: **Plan-Executor Remote**
> Plan: `<migrated-plan-path>`
> Job is running remotely via GitHub Actions. The plan-executor daemon handles execution from here.

Do NOT invoke any skill. Do NOT wait for the job to finish.

## Constraints

- Do NOT write implementation code.
- Do NOT leave the migrated plan outside `.my/plans/` (Plan-Executor path only).
- Do NOT omit the execution flags required by `my:plan` (Plan-Executor path only).
- Do NOT keep the migrated plan in WIP state.
- Do NOT offer execution choices until the migrated plan has been validated (Plan-Executor path only).
- Do NOT offer execution choices until the user has answered the execution-flag questions and the migrated plan has been updated and re-verified (Plan-Executor path only).
- Do NOT skip the execution-flag questions (Plan-Executor path only).
- Do NOT migrate the plan when the user selects Superpowers execution.
- Do NOT ask about JIRA or execution flags when the user selects Superpowers execution.

## Final response pattern

When migration succeeds, report:

- source plan path
- migrated plan path
- verification result
- selected execution path or the fact that execution choice is needed
