# Contract: `pr-finalize`

This document is the wire-level contract between the Rust plan-executor caller and the
`plan-executor:pr-finalize` skill **when the skill is invoked from the non-interactive
job framework**. It pins the I/O envelope for that machine-driven path.

The interactive launcher / foreground / fixer modes documented in `SKILL.md` remain
unchanged for human users. This contract describes the **structured-I/O wrapper** the
Rust caller uses to invoke `pr-finalize` and to consume its result.

Schemas: `schemas/input.schema.json` and `schemas/output.schema.json` (JSON Schema 2020-12).

---

## Single Responsibility

**Does:** drive a PR to a finalizable state — mark draft PRs ready, run the
PR-monitor loop (Bugbot replies, CI fixes, SonarCloud / Semgrep / Compliance fixes,
unresolved-thread closure, optional rebase on merge conflicts), and — when the caller
opted in — merge the PR. Returns a deterministic structured verdict per invocation.

**Does NOT:**

- write or commit code outside the scope of fixing the issues raised on the PR,
- run plan-execution code review or validation (those are separate helpers),
- create new PRs (the caller passes an existing PR link or `gh pr view`-resolvable branch),
- merge unless `merge_mode` is `"merge"` or `"merge_admin"` AND all checks are green,
- block on human input — `AskUserQuestion`/interactive prompts are forbidden in this mode.

---

## Input Shape

| Field | Type | Required | Semantics |
|---|---|---|---|
| `pr_link` | string \| null | yes | PR URL (e.g. `https://github.com/owner/repo/pull/N`) or `null` to auto-detect from current branch via `gh pr view`. |
| `working_dir` | string | yes | absolute path to the worktree where the PR's branch is checked out. |
| `merge_mode` | `"none" \| "merge" \| "merge_admin"` | yes | post-finalization merge policy. `"none"` never merges. |
| `mode` | `"foreground" \| "fixer"` | yes | which sub-mode of the skill to run. The Rust caller always uses `"foreground"`; `"fixer"` is reserved for the monitor's internal recursion. |
| `fixer_payload` | object | only when `mode = "fixer"` | the issue-description JSON the monitor passes to a fixer Claude session. Mirrors the `merge_conflicts` / `failed_checks` / `new_bugbot_comments` / `unresolved_threads` shape from `SKILL.md` § Fixer Mode. |
| `summary_file` | string | yes | absolute path where the skill writes its human-readable summary. The skill creates this file. |
| `log_file` | string | yes | absolute path where the skill streams its monitor log. The skill creates this file. |
| `max_runtime_secs` | integer ≥ 60 | yes | upper bound on the monitor's wall-clock runtime. The watchdog terminates the monitor at this limit and the skill returns `blocked`. |

`additionalProperties: false` on the input.

---

## Output Shape

```json
{
  "status": "success | fix_required | blocked | abort",
  "next_step": "<one of the per-skill tokens below>",
  "notes": "free-form multi-line summary",
  "state_updates": { "...": "..." }
}
```

### Status semantics

| `status` | Meaning |
|---|---|
| `success` | PR is in the finalized state the caller asked for: all checks green, all unresolved threads resolved, and (when `merge_mode != "none"`) merged. |
| `fix_required` | Monitor produced fixes that landed on the PR but new Bugbot/CI complaints arrived (or were never resolved). Caller should re-invoke after the next push settles, or escalate to human review. |
| `blocked` | Monitor cannot proceed deterministically: PR not found, draft-promotion failed, merge conflict that the fixer could not resolve, watchdog timeout, or `gh` auth failure. |
| `abort` | Terminal: explicit unrelated-failure or no-progress signal from the fixer, or `merge_admin` requested but not allowed by repo policy. |

### `next_step` (allowed tokens)

| Token | Meaning for the caller |
|---|---|
| `done` | Workflow complete. Caller may release the worktree. |
| `address_findings` | Caller should re-enter `pr-finalize` after a cool-down (or escalate to a human reviewer) — there are still active findings that the monitor could not auto-resolve. |
| `wait_for_review` | A human review or required approval is the only remaining gate. Caller stops auto-finalizing and waits. |
| `terminate` | Unrecoverable — caller stops the parent workflow. |

### `state_updates` (helper-owned fields)

| Key | Type | Required | Semantics |
|---|---|---|---|
| `pr_state` | string | yes | latest observed PR state from `gh pr view --json state`: one of `"OPEN"`, `"MERGED"`, `"CLOSED"`, or — when GitHub returns no state because the PR could not be resolved — `"UNKNOWN"`. |
| `merge_sha` | string | optional | the merge commit SHA when the skill performed a merge. Omitted when no merge occurred. 40-char lowercase hex. |
| `bugbot_comments_addressed` | integer ≥ 0 | yes | count of Bugbot comments the monitor resolved (FIX_REQUIRED applied + REJECTED/DEFERRED replied) during this invocation. `0` when no Bugbot comments were touched. |

`additionalProperties: false` on `state_updates`.

---

## Failure-Mode Mapping

| Failure scenario | Taxonomy bucket | Contract `status` | `next_step` |
|---|---|---|---|
| `gh` CLI not on PATH / not authenticated | HardInfra | `blocked` | `address_findings` |
| GitHub API 5xx / rate limit | TransientInfra | `blocked` | `address_findings` |
| Watchdog timeout (`max_runtime_secs` exceeded) | TransientInfra | `blocked` | `address_findings` |
| Required input missing or empty | ProtocolViolation | `blocked` | `address_findings` |
| `pr_link` resolves to non-existent PR | ProtocolViolation | `blocked` | `address_findings` |
| `mode = "fixer"` without `fixer_payload` | ProtocolViolation | `blocked` | `address_findings` |
| Merge conflict the fixer cannot resolve | SemanticFailure | `blocked` | `wait_for_review` |
| Required reviewer approvals missing | SemanticFailure | `blocked` | `wait_for_review` |
| Unrelated-failure detected by fixer (no progress) | SemanticFailure (terminal) | `abort` | `terminate` |
| `merge_mode = "merge_admin"` rejected by repo policy | HardInfra (terminal) | `abort` | `terminate` |
| New Bugbot/CI complaints landed but `max_runtime_secs` not exceeded and progress was made | SemanticFailure | `fix_required` | `address_findings` |
| All checks green, all threads resolved, optional merge succeeded (or `merge_mode = "none"`) | (success) | `success` | `done` |

---

## Examples

### Happy path — finalize and merge

**Input:**

```json
{
  "pr_link": "https://github.com/parloa/plan-executor/pull/42",
  "working_dir": "/abs/worktrees/feat-x",
  "merge_mode": "merge",
  "mode": "foreground",
  "summary_file": "/tmp/pr-finalize-summary-42.md",
  "log_file": "/tmp/pr-finalize-log-42.txt",
  "max_runtime_secs": 1800
}
```

**Output:**

```json
{
  "status": "success",
  "next_step": "done",
  "notes": "PR #42: 3 Bugbot comments resolved (2 fixed, 1 rejected with reasoning); CI green; SonarCloud green; merged via gh pr merge --merge",
  "state_updates": {
    "pr_state": "MERGED",
    "merge_sha": "1c2689c0a1b2d3e4f5a6b7c8d9e0f1a2b3c4d5e6",
    "bugbot_comments_addressed": 3
  }
}
```

### Fix-required path — monitor produced fixes, new Bugbot complaints arrived

**Input:**

```json
{
  "pr_link": "https://github.com/parloa/plan-executor/pull/42",
  "working_dir": "/abs/worktrees/feat-x",
  "merge_mode": "merge",
  "mode": "foreground",
  "summary_file": "/tmp/pr-finalize-summary-42.md",
  "log_file": "/tmp/pr-finalize-log-42.txt",
  "max_runtime_secs": 1800
}
```

**Output:**

```json
{
  "status": "fix_required",
  "next_step": "address_findings",
  "notes": "PR #42: monitor pushed 2 fix commits; 1 new Bugbot finding posted after the last push (PR-LINE 87, unresolved); CI green; re-invoke after cool-down or escalate",
  "state_updates": {
    "pr_state": "OPEN",
    "bugbot_comments_addressed": 2
  }
}
```

---

## Wire-Format Invariants

1. The output envelope has exactly four top-level keys.
2. `status` ∈ {`success`, `fix_required`, `blocked`, `abort`}.
3. `next_step` ∈ {`done`, `address_findings`, `wait_for_review`, `terminate`}.
4. `state_updates.pr_state` is always present and is one of `"OPEN"`, `"MERGED"`, `"CLOSED"`, `"UNKNOWN"`.
5. `state_updates.bugbot_comments_addressed` is always present and `≥ 0`.
6. `state_updates.merge_sha` is present **iff** the skill actually performed a merge in this invocation (regardless of `pr_state` — a `MERGED` PR that was already merged before this invocation does NOT carry `merge_sha`).

---

## Back-test results

**Sampled runs:** 1 real (`773749ab-pr-105-merged` — `parloa/claude-code-proxy#105`,
`merge_mode = "merge"`, `mode = "foreground"`, observed result: `pr_state = MERGED`,
`merge_sha = 5deb4b291875bfaf15c785008695b2e8d76d0ed3`, watchdog poll: 7 waiting
+ 3 clean polls in a row, no Bugbot comments addressed) + 2 synthetic (one
`mode = fixer` payload exercising the bugbot/failed-checks/unresolved-threads
shape, one `blocked` foreground path for an unresolvable merge conflict).

**Validation:** all 3 fixtures pass `schemas/input.schema.json` and
`schemas/output.schema.json` with `information_loss: "none"`. Fixture files live
under `back-test/`.

**Schema deltas applied during back-test:** none. The D1.1 schemas accommodated
all observed and synthesized payloads on the first pass.

**Pre-existing contract drift documented:** in the surveyed
`~/.plan-executor/jobs/` corpus, `pr-finalize` was **never** invoked as a
`Skill` tool call. It was always invoked indirectly via a wrapper shell script
(`.tmp-subtask-pr-finalize.sh`) that forked a sub-agent process and produced a
human-readable summary at `.tmp-pr-finalize-summary.md`. Today's invocation
form has no structured input or output — the summary file is plain markdown
and the caller polls `gh pr view --json state,mergeCommit` separately.

The new schema is a forward-only contract: the structured-I/O envelope is the
target for the non-interactive job framework, not a description of how
`pr-finalize` was invoked historically. The real fixture under
`back-test/773749ab-pr-105-merged.json` records the **structured equivalent**
of the legacy invocation:

- `pr_link`, `working_dir`, `summary_file`, `log_file`, `merge_mode`,
  `max_runtime_secs` are all extractable from the wrapper's environment.
- `mode = "foreground"` — the wrapper always ran the foreground monitor.
- The output is reconstructed from `gh pr view` results captured in the
  job's `output.jsonl` (`state = MERGED`, `mergeCommit.oid = 5deb4b29…`,
  `bugbot_comments_addressed = 0` because the monitor's Clean-Poll path
  never entered Bugbot triage).

**Back-test gaps:** zero real historical runs invoked this helper as a `Skill`
call. The single "real" fixture is reconstructed from a wrapper-script
invocation; the other two are synthetic. Once the structured-I/O wrapper
ships (D2.x) the back-test corpus will grow naturally and the synthetic
fixtures should be replaced with real ones.
