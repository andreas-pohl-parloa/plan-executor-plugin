# Execute-Plan Deviation Journal Integration Design

## Context

The deviation-journal protocol shipped in `plan-executor` (the binary repo) via PRs #71 (entry types + validator), #73 (schemas, dispatch injection, helper digest, summary), and #74 (foreground integration test). Every executor that funnels sub-agents through `handoff::dispatch_agent` — the daemon, the foreground binary, and the GHA-runner remote — now writes the deviation block into per-task prompts at dispatch time and digests the journal between waves.

The interactive in-session orchestrator `plan-executor:execute-plan` (in this plugin repo) does not. It dispatches sub-agents through the Claude Agent tool, builds its own `.tmp-subtask-<N>.md` files, and never reads `<execution_root>/.plan-executor/deviations.jsonl`. As a result, runs driven by that skill have no cross-task agent communication and no record of intentional skips, substitutions, or scope changes.

This spec extends `plan-executor:execute-plan` to participate in the deviation-journal contract. It also makes the skill consume the canonical `<plan-stem>/tasks/task-<id>.md` files compile-plan already produces, instead of re-extracting task bodies into temp files.

## Non-goals

- Modify the `plan-executor` binary or any of its dispatch paths.
- Change the manifest schema, helper input schemas, or compile-plan output layout.
- Re-design the in-session orchestrator's pipeline phases. Phase 1, 4, 5, 6, 7, 8 are unchanged in shape; only the data passed in/out of them grows.
- Touch `superpowers:subagent-driven-development` or any non-`plan-executor` orchestrator.

## Coverage statement

After this work, every plan-executor execution path inherits the deviation-journal contract:

- **Daemon** (`plan-executor execute <tasks.json>`): via `handoff::dispatch_agent` (already done).
- **Foreground binary** (`plan-executor execute --foreground <tasks.json>`): via the same path (already done).
- **Remote GHA runner**: via the foreground binary on the runner (already done).
- **Interactive in-session** (`plan-executor:execute-plan` skill): via the changes in this spec.

`superpowers:subagent-driven-development` and any future hand-rolled in-session orchestrator remain out of scope.

## Phase 3 — Wave-based execution changes

Today the orchestrator builds `.tmp-subtask-<N>.md` files per sub-agent, embedding a Sub-Agent Instructions banner and the task body it copied from the plan markdown. After this change:

1. The orchestrator reads the canonical `<plan-stem>/tasks/task-<id>.md` produced by compile-plan. It never modifies that file.
2. The orchestrator writes a wrapper file at `<execution_root>/.tmp-subtask-wave<W>-<id>.md` (one per task per wave). The naming includes the wave id so resume mid-wave does not collide with completed waves' wrappers.
3. The wrapper file's content, in order:
   1. **Sub-Agent Instructions banner** (existing role / recipes / workdir / report contract).
   2. **Deviation journal protocol** block — same shape as the binary's `handoff::deviation_block`. Header `> **Deviation journal (plan-executor enforced — do not remove):**` (used as the idempotency marker), constants table (journal_path, job_id, phase, wave_id, task_id, agent_index), and the four-step protocol (build entry → validate via `plan-executor validate --schema=deviation-journal-entry -` → append, plus the do-not-ask-the-user clause).
   3. **Prior deviation digest** block — present only when the previous wave produced entries. Header `> Prior deviation digest for context:` followed by the digest lines.
   4. **Body** — verbatim contents of the canonical `tasks/task-<id>.md`. Copied with a `> --- task body below ---` separator so the wrapper preamble is clearly bounded.
4. Sub-agents are dispatched against the wrapper file. The Agent-tool prompt tells them to read only that file.
5. After the wave succeeds, wrapper files are deleted. On wave failure they are left in place so resume can reuse them.

Because the canonical `tasks/task-<id>.md` is never edited, repeated dispatches and resumes always start from a known-good source.

### job_id derivation

The interactive skill has no daemon job id. It synthesizes one as `interactive-<short-sha>-<UTC-yyyymmdd-hhmmss>` where `<short-sha>` is the first 7 chars of the manifest's plan path SHA-1. The id is computed once per orchestrator invocation and reused for every wrapper preamble. It only needs to be unique enough to disambiguate concurrent runs; the deviation-journal entry validator does not enforce a format beyond non-empty.

### Idempotency

The deviation block uses the same marker the binary uses (`Deviation journal (plan-executor enforced`). When a wrapper file already exists from a prior attempt, the orchestrator checks for the marker before prepending. Resume re-uses existing wrappers as-is.

## Between-wave digest read

Between every wave, before launching the next wave's sub-agents:

1. Run `plan-executor validate --schema=deviation-journal <execution_root>/.plan-executor/deviations.jsonl`.
   - File missing → digest is empty; skip the next two steps.
   - Validator returns non-zero → log the `ERROR:` lines into the orchestrator's display output and continue with an empty digest. Malformed entries are advisory; they never abort the run.
2. Read each non-empty line as JSON.
3. Render the digest with the same per-entry format the binary's `digest()` function emits for `DigestScope::All`:

```text
- Task <task_id> / <category> / <severity>:
  Claim: <claim>
  Evidence: <path>:<lines> — <summary>      # for file_line
  Evidence: <path> — <summary>              # for command_log / test_result
  Evidence: commit <commit> — <summary>     # for commit
  Impact: <impact>
```

`<task_id>` falls back to `repo-wide` when absent. `<category>` and `<severity>` are rendered using the binary's Debug-format casing for parity (e.g. `ScopeChange`, `Critical`).

4. Cap the digest at 200 lines / 32 KiB. If truncation is required, prefer entries in this order:
   1. severity = `critical`,
   2. entries whose `path` matches a file the upcoming wave will edit (orchestrator can derive this from the wave's task bodies), then
   3. most recent entries by `created_at`.

   Append `[deviation digest truncated]` and continue.

The digest text is held in memory only; it is regenerated each wave.

## Phase 5 — code review integration

When invoking `plan-executor:review-execution-output`, the orchestrator passes two additional input fields:

- `deviation_journal_path`: absolute path to `<execution_root>/.plan-executor/deviations.jsonl`. Omit the field when the file does not exist.
- `deviation_digest`: the rendered digest from the most recent between-wave read. Empty string when no entries.

Both are documented as optional in the helper's input contract; runs without a journal continue to work.

The `plan-executor:review-execution-output` SKILL.md is updated:

- Required-inputs section adds the two fields with `optional` annotation.
- Reviewer-prompt section adds one paragraph: *"Use deviation entries as leads. Re-read evidence before accepting the claim. Do not suppress a finding solely because a deviation exists."*
- A note clarifies that an empty digest is normal, not a contract violation.

The fix-loop branch (`fix_required` from the reviewer team) extends fix-task prompts with a file-scoped digest. The orchestrator filters digest entries whose evidence `path` matches the fix target file, so each fix-agent sees only the deviations relevant to its file.

## Phase 6 — validation integration

Same field plumbing as Phase 5: `deviation_journal_path` and `deviation_digest` flow into `plan-executor:validate-execution-plan` as optional inputs. The validator helper's SKILL.md is updated with one paragraph in the validator-prompt section:

> "Deviation journal entries are advisory. PASS only if the plan requirement is implemented in code or the deviation's evidence still verifies. If the evidence is stale, missing, or free-text only, treat the requirement as unmet."

The validator's `gaps` array is unaffected. The `validation_report_path` field remains optional (per the binary fix in PR #72).

## Phase 8 — execution summary

The summary the orchestrator prints at the end of a run gains a `## Plan deviations` section when the journal contains any entry whose category is `skip`, `substitute`, `scope_change`, or any unresolved `blocker` (severity `critical`). The format mirrors the binary's `notable_summary`:

```text
## Plan deviations

- Task <task_id>: <category> / <severity> — <claim>
  Evidence: <first evidence rendered as in the digest>
```

Routine `discovery` entries are omitted. When the journal has no notable entries, the section is omitted entirely.

After the summary is printed, the orchestrator copies the journal file to a stable archive location:

- When the orchestrator knows a daemon `job_dir` (rare for interactive runs, but possible if the skill was launched as a follow-up to a daemon job), it copies to `<job_dir>/deviations.jsonl`.
- Otherwise it copies to `<plan-stem>/deviations.jsonl` so the run's artifacts stay co-located with the manifest.

Archive failures are logged and ignored.

## Failure handling

- **Journal validation failure** during between-wave read: log validator output, drop malformed lines from the digest, continue with the surviving entries. Never abort the run.
- **Wrapper write failure**: bubble up as a hard infra error and stop the run; the wrapper file is the only contract sub-agents see, so a missing wrapper is not recoverable mid-wave.
- **Skip-flags**: `flags.skip_code_review = true` skips Phase 5 as today; the digest plumbing is simply unused for that phase. Phase 6 still runs and consumes the digest.
- **Resume**: existing wrapper files are reused. The deviation marker prevents duplicate injection.

## Trust model

Same as the binary's deviation-journal trust model: journal entries are advisory until later stages re-verify their evidence. Reviewers must re-check the evidence; validators must not pass a requirement solely because a deviation exists.

## Acceptance criteria

- The interactive `plan-executor:execute-plan` skill reads `<plan-stem>/tasks/task-<id>.md` for every task and never modifies the canonical file.
- Each dispatched sub-agent prompt contains a deviation-journal protocol block with the marker `Deviation journal (plan-executor enforced`.
- After every wave, the orchestrator validates the journal via `plan-executor validate --schema=deviation-journal`, renders a `DigestScope::All`-format digest, and feeds it into the next wave's wrapper prompts plus Phase 5/6 helper inputs.
- The reviewer-team and validator helper SKILL.md files surface the digest in reviewer/validator prompts and state the trust contract.
- Phase 8's summary includes a `## Plan deviations` section when notable entries exist; routine `discovery` entries are omitted.
- The journal is archived to a stable location after Phase 8.
- Resume mid-wave is idempotent: wrapper files are reused, the deviation block is not duplicated, and an existing journal is consumed correctly.
- A run that produces no deviations behaves identically to today's flow except for one optional "no deviations" line in the summary.
