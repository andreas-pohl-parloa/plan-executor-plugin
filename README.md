# plan-executor-plugin

Claude Code plugin marketplace for plan execution pipeline — orchestration, validation, code review, and binary dependency management.

## Install

```bash
bash -c "$(gh api 'repos/andreas-pohl-parloa/plan-executor-plugin/contents/install.sh' --header 'Accept: application/vnd.github.raw')"
```

Requires the [GitHub CLI](https://cli.github.com) (`gh`) authenticated. The `plan-executor` and `sjv` binaries are auto-installed from GitHub releases on first session start.

From a local clone:

```bash
./install.sh
```

The script is idempotent: re-running it does a clean reinstall (removes, clears cache, re-adds).

## Planning and Execution Flow

The typical workflow from idea to running code:

```
                        "build feature X"
                               |
                   +-----------+-----------+
                   |      Brainstorm       |  superpowers:brainstorming
                   +-----------+-----------+
                               |
                   +-----------+-----------+
                   |         Plan          |  superpowers:writing-plans
                   +-----------+-----------+
                               |
                   PostToolUse hook fires
                               |
                   +-----------+-----------+
                   |       Handover        |  plan-executor:superpowers-plan-handover
                   +-----------+-----------+
                               |
       +-----------+-----------+-----------+-----------+
       |           |           |                       |
  +----+-----+ +---+------+ +-+-------------+ +-------+--------+
  | Inline   | | Subagent | | Interactive   | | Local / Remote |
  +----------+ +----------+ +---------------+ +----------------+
  | Current  | | One agent| | Waves + 4-rev | | plan-executor  |
  | session  | | per task | | code review   | | daemon / GH    |
  +----------+ +----------+ +---------------+ +----------------+
```

1. **Brainstorm** — `superpowers:brainstorming` explores the idea through questions, proposes approaches, and writes a design spec.
2. **Plan** — `superpowers:writing-plans` turns the spec into a detailed implementation plan with bite-sized TDD tasks.
3. **Handover** — The `PostToolUse` hook automatically triggers `plan-executor:superpowers-plan-handover` after the plan is written. The user chooses an execution mode.
4. **Execute** — Depending on the mode:
   - **Superpowers** modes execute directly via Superpowers skills.
   - **Plan-Executor Interactive** runs wave-based execution with code review (Phase 5) and plan validation (Phase 6). Code review dispatches a 4-agent reviewer team (Claude + Codex + Gemini + Security) in parallel, triages findings, and drives fix loops.
   - **Plan-Executor Local** submits the plan to the `plan-executor` daemon running on the local machine.
   - **Plan-Executor Remote** submits the plan to be executed via GitHub Actions. The plan includes `add-marketplaces` and `add-plugins` headers so the remote runner installs the same plugin environment.

> [!WARNING]
> Remote execution requires one-time setup — see [Remote Setup](#remote-setup) below.

## Skills

| Skill | Description |
|-------|-------------|
| `/plan-executor:execute-plan` | Execute a READY plan interactively with review checkpoints |
| `/plan-executor:execute-plan-non-interactive` | Execute a plan via deterministic non-interactive handoffs |
| `/plan-executor:pr-finalize` | Fix bug comments on a PR |
| `/plan-executor:review-execution-output` | Review completed execution output in the current agent |
| `/plan-executor:review-execution-output-non-interactive` | Non-interactive code review via prompt-file handoffs |
| `/plan-executor:run-reviewer-team` | Launch parallel Claude + Codex + Gemini + Security reviewer set |
| `/plan-executor:run-reviewer-team-non-interactive` | Non-interactive reviewer dispatch and triage via handoffs |
| `/plan-executor:superpowers-plan-handover` | Hand a Superpowers plan over into the execution flow |
| `/plan-executor:validate-execution-plan` | Validate a plan against implementation output (interactive) |
| `/plan-executor:validate-execution-plan-non-interactive` | Validate a plan with persisted state (non-interactive) |

## Remote Setup

Remote execution dispatches plans to GitHub Actions via a dedicated executions repository. One-time setup is required.

```bash
plan-executor remote-setup
```

The interactive wizard creates a private executions repository on GitHub (you just give it a name), configures `~/.plan-executor/config.json` with the `remote_repo` slug, and stores the required secrets (`ANTHROPIC_API_KEY`, etc.) so runners can authenticate.

After setup, `~/.plan-executor/config.json` contains a `remote_repo` entry:

```json
{
  "remote_repo": "your-org/plan-executions"
}
```

Re-run `plan-executor remote-setup` at any time to update the configuration.

### Agent configuration

The config file also supports an `agents` section that defines the CLI commands used to launch each agent type during execution:

```json
{
  "agents": {
    "main": "claude --dangerously-skip-permissions --verbose --output-format stream-json",
    "claude": "claude --dangerously-skip-permissions -p",
    "codex": "codex --dangerously-bypass-approvals-and-sandbox exec",
    "gemini": "gemini --yolo -p"
  },
  "remote_repo": "your-org/plan-executions"
}
```

- **`main`** — the primary orchestrator agent (streams output)
- **`claude`** — Claude sub-agent for implementation, review, and validation handoffs
- **`codex`** — Codex sub-agent for code review (can-fail)
- **`gemini`** — Gemini sub-agent for code review (can-fail)

## Structure

```
.claude-plugin/marketplace.json        # marketplace manifest
plugins/
  plan-executor/
    .claude-plugin/plugin.json         # plugin manifest
    hooks/
      hooks.json                       # PostToolUse + SessionStart hooks
      post-tool-use-skill.sh           # injects plan-handover reminder after writing-plans
      session-start.sh                 # auto-installs plan-executor and sjv binaries
    skills/<name>/SKILL.md             # one directory per skill
```

## Hooks

The `plan-executor` plugin registers two hooks:

- **PostToolUse** — fires after every `Skill` tool call. When `superpowers:writing-plans` is invoked, injects a mandatory reminder to run `plan-executor:superpowers-plan-handover`.
- **SessionStart** — checks if `plan-executor` and `sjv` binaries are available. Downloads prebuilt binaries from GitHub releases if missing.
