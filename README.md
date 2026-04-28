# plan-executor-plugin

Claude Code plugin marketplace for autonomous plan execution — orchestration, code review, validation, and PR management.

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

<picture>
  <img src="docs/flow.svg" alt="Planning and execution flow" width="900">
</picture>

| Step | What happens |
|------|-------------|
| **Brainstorm** | `superpowers:brainstorming` explores the idea, asks questions, writes a design spec |
| **Plan** | `superpowers:writing-plans` turns the spec into a step-by-step implementation plan |
| **Handover** | `PostToolUse` hook triggers `plan-executor:handover` — collects executor metadata into a `meta.json` sidecar |
| **Inline / Subagent** | Execute directly via Superpowers skills |
| **Interactive** | Wave-based execution with code review (Claude + Codex + Gemini + Security) and plan validation |
| **Local** | Hand off to the `plan-executor` daemon on the local machine |
| **Remote** | Hand off to GitHub Actions for non-interactive execution |

> [!WARNING]
> Remote execution requires one-time setup — see [Remote Setup](#remote-setup) below.

## Skills

| Skill | Description |
|-------|-------------|
| `/plan-executor:pr-finalize` | Fix bug comments on a PR, auto-merge if requested |
| `/plan-executor:review-execution-output` | Review completed execution output in the current agent |
| `/plan-executor:review-execution-output-non-interactive` | Non-interactive code review via prompt-file handoffs |
| `/plan-executor:run-reviewer-team` | Launch parallel Claude + Codex + Gemini + Security reviewer set |
| `/plan-executor:run-reviewer-team-non-interactive` | Non-interactive reviewer dispatch and triage via handoffs |
| `/plan-executor:handover` | Universal plan ingestion — detects format and writes a `meta.json` sidecar for compile-plan |
| `/plan-executor:validate-execution-plan` | Validate a plan against implementation output (interactive) |
| `/plan-executor:validate-execution-plan-non-interactive` | Validate a plan with persisted state (non-interactive) |

## Remote Setup

Remote execution dispatches plans to GitHub Actions via a dedicated executions repository. One-time setup is required.

```bash
plan-executor remote-setup
```

The interactive wizard creates a private executions repository on GitHub (you just give it a name), configures `~/.plan-executor/config.json` with the `remote_repo` slug, and stores the required credentials (`ANTHROPIC_API_KEY`, etc.) as encrypted GitHub repository secrets so runners can authenticate.

After setup, `~/.plan-executor/config.json` contains a `remote_repo` entry:

```json
{
  "remote_repo": "your-org/plan-executions"
}
```

Re-run `plan-executor remote-setup` at any time to update the configuration.

## Planning

This plugin handles execution only. For brainstorming and plan creation, install the [Superpowers plugin](https://github.com/anthropics/claude-plugins-official) which provides `superpowers:brainstorming` and `superpowers:writing-plans`.
