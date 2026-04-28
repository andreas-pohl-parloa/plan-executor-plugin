---
name: plan-executor:pr-finalize
description: Fix bug comments on a PR
argument-hint: [pr-link] [--fix] [--foreground] [--remote] [--pr N] [--merge] [--merge-admin]
---

# PR Finalizer

Finalizes PRs by fixing ALL issues — Bugbot comments, compliance checks, CI failures,
lint errors, SonarCloud findings, and any other failing check.

## Mode Detection

This skill operates in four modes based on arguments:

- No `--fix`, no `--foreground`, no `--remote` → **Launcher mode** (background bash monitor; default).
- `--foreground` → **Foreground mode** (sync bash monitor; same as Launcher but blocking).
- `--remote` → **Remote mode** (submit to GHA execution repo; non-blocking, runs on a runner).
- `--fix` → **Fixer mode** (internal: called by the monitor for individual fix work).

Optional merge flags (Launcher, Foreground, Remote modes):
- `--merge` → merge after finalization via `gh pr merge --merge`
- `--merge-admin` → merge with admin override via `gh pr merge --merge --admin`
- NEVER merge unless one of these flags was explicitly passed.

---

## Launcher Mode (default)

### Step 1: Identify the PR

Parse the PR link from $1. If not provided, detect from current branch:
```
gh pr view --json number,headRefName,url
```

Extract owner, repo, PR number, HEAD SHA:
```
PR_NUMBER=$(gh pr view --json number --jq '.number')
HEAD_SHA=$(gh pr view --json headRefOid --jq '.headRefOid')
OWNER=$(gh repo view --json owner --jq '.owner.login')
REPO=$(gh repo view --json name --jq '.name')
```

### Step 2: Mark draft PRs ready for review first

Before launching the monitor, inspect whether the PR is still a draft:
```bash
gh pr view "$PR_NUMBER" --repo "$OWNER/$REPO" --json isDraft --jq '.isDraft'
```

If the PR is a draft:
```bash
gh pr ready "$PR_NUMBER" --repo "$OWNER/$REPO"
```

Rules:
- Launcher mode MUST mark a draft PR ready for review before monitoring begins.
- If the PR is already ready, do nothing and continue.
- If `gh pr ready` fails, stop and report the error. Do NOT launch the monitor.

### Step 3: Launch the monitor script

The monitor script is in the same directory as this skill. Locate it:
```
SKILL_DIR — find via the plugin cache path for plan-executor:pr-finalize
```

Create temp files for summary and log:
```
SUMMARY_FILE=$(mktemp /tmp/pr-finalize-summary-XXXXX.md)
LOG_FILE=$(mktemp /tmp/pr-finalize-log-XXXXX.txt)
```

Launch the monitor as a background Bash job:
```bash
bash <skill-dir>/pr-monitor.sh \
  --owner "$OWNER" \
  --repo "$REPO" \
  --pr "$PR_NUMBER" \
  --head-sha "$HEAD_SHA" \
  --push-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --workdir "$(pwd)" \
  --summary-file "$SUMMARY_FILE" \
  --log-file "$LOG_FILE"
```

Run this via `Bash` tool with `run_in_background: true`.

### Step 4: Respond immediately — do NOT wait

After launching the background Bash job, **stop and respond to the user right now**:

> "Monitor running for PR #N. Waiting for it to finish."

Then go idle. **Do NOT call `TaskOutput`. Do NOT sleep. Do NOT poll.**
You will receive a `<task-notification>` when the job completes.

**Red flags — if you find yourself doing any of these, stop immediately:**
- Calling `TaskOutput` with `block: true`
- Calling `TaskOutput` at all before receiving a notification
- Adding a sleep or delay
- Saying "let me check the status"

The monitor handles all polling internally. Your job ends at launching it.

**What "truly done" means (the monitor handles this, not you):**
1. All CI checks passing.
2. No new Bugbot comments since the last push.
3. No unresolved review threads.
4. At least 6 minutes elapsed since the last fix push.

### Step 5: Report results — only after receiving task-notification

When you receive a `<task-notification>` for the background job:
1. Check the exit code. 0 = all checks green, truly done.
2. Read `$SUMMARY_FILE` and display its contents to the user.
3. If exit code is non-zero, inform the user that the PR still has issues and
   show the summary of what was attempted.
4. Clean up temp files.
5. **Merge (only if exit code is 0 and a merge flag was passed):**
   - `--merge` → `gh pr merge --merge <PR_NUMBER> --repo <OWNER>/<REPO>`
   - `--merge-admin` → `gh pr merge --merge --admin <PR_NUMBER> --repo <OWNER>/<REPO>`
   - If neither flag was passed: do NOT merge, even if checks are green.
   - If merge fails, report the error but do not retry automatically.

---

## Foreground Mode (`--foreground`)

Identical to Launcher mode except the monitor runs synchronously. Use this when background tasks are not wanted (e.g. non-interactive execution).

Steps 1 and 2 are the same as Launcher mode (identify PR, mark draft ready).

### Step 3: Run the monitor in the foreground

Use the same `pr-monitor.sh` command as Launcher mode, but run it via the `Bash` tool **without** `run_in_background`. This blocks until the monitor exits.

```bash
bash <skill-dir>/pr-monitor.sh \
  --owner "$OWNER" \
  --repo "$REPO" \
  --pr "$PR_NUMBER" \
  --head-sha "$HEAD_SHA" \
  --push-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --workdir "$(pwd)" \
  --summary-file "$SUMMARY_FILE" \
  --log-file "$LOG_FILE"
```

Set a generous timeout (e.g. `timeout: 600000`) since the monitor may run for several minutes.

### Step 4: Handle the result

When the command returns:
1. Check the exit code. 0 = all checks green.
2. Read `$SUMMARY_FILE` and report its contents.
3. If exit code is non-zero, report the summary and the failure.
4. Clean up temp files.
5. **Merge (only if exit code is 0 and a merge flag was passed):**
   - `--merge` → `gh pr merge --merge <PR_NUMBER> --repo <OWNER>/<REPO>`
   - `--merge-admin` → `gh pr merge --merge --admin <PR_NUMBER> --repo <OWNER>/<REPO>`
   - If neither flag was passed: do NOT merge.
   - If merge fails, report the error but do not retry automatically.

---

## Remote Mode (`--remote`)

Submits the pr-finalize job to GitHub Actions via the user's execution repo
instead of running locally. Returns immediately with the execution PR URL. No
local monitor, no fixer dispatch, no polling, no blocking.

### Prerequisites

- The user MUST have run `plan-executor remote-setup` first. The execution repo
  must be configured before Remote mode can submit a job.
- The `plan-executor` binary must be on `PATH`.

### Flag rules

- `--merge` and `--merge-admin` are mutually exclusive — same as the local CLI.
  If both are passed, error immediately with a clear message and do not submit
  the job.

### Step 1: Identify the target PR

Same as Launcher mode Step 1: `gh pr view --json number,headRefOid,url` from the
current branch. If `--pr <N>` was explicitly passed in the args, use that instead
(but still verify it exists via `gh pr view <N>`).

### Step 2: Mark draft PRs ready first

Same as Launcher mode Step 2: if the PR is a draft, run `gh pr ready <N>`. The
remote runner will not finalize a draft.

### Step 3: Verify the binary supports `--remote`

Before shelling to the CLI, verify the local `plan-executor` binary is recent
enough to know the `--remote` flag. A PATH check alone is insufficient — an
older binary on PATH will fail with `unexpected argument '--remote'` instead
of a clear error.

```bash
plan-executor run pr-finalize --help 2>&1 | grep -q -- --remote
```

If `command -v plan-executor` fails OR the help output does not contain
`--remote`, error with this message and exit:

> plan-executor binary missing or out of date — does not support `--remote`.
> Reinstall the latest:
>
>   bash -c "$(gh api 'repos/andreas-pohl-parloa/plan-executor/contents/install.sh?ref=main' --header 'Accept: application/vnd.github.raw')"
>
> Then restart the daemon: `plan-executor stop && plan-executor daemon`.

Do NOT invoke `plan-executor --version` — the binary does not implement that
flag.

### Step 4: Shell to the Rust CLI

Run:

    plan-executor run pr-finalize --remote --pr <N> [--merge | --merge-admin]

Capture the stdout — the CLI prints the execution PR URL on success.

### Step 5: Report the execution PR

Print to the user:
- "Submitted pr-finalize for <owner>/<repo>#<N> to remote execution."
- "Execution PR: <URL>"
- "Watch progress: gh pr checks <URL>"

Then exit. The skill is done. The runner takes over from here.

---

## Fixer Mode (`--fix`)

When invoked with `--fix`, you are running inside a non-interactive Claude session
dispatched by the monitor script. The prompt contains the specific issues to fix.

### Preparation

1. Check the language used in this repository

2. Load language specific skills
  - For **Typescript**: production-code, test-code and true-myth
  - For **Python**: production-code, test-code
  - For **Rust**: production-code, test-code

### Workflow

#### Step 1: Parse the issue description

The prompt contains JSON describing:
- `merge_conflicts` — `{"conflicting": true, "base_branch": "main"}` if the PR has merge conflicts
- `failed_checks` — list of check names and their conclusions
- `new_bugbot_comments` — bugbot review comments with path and body
- `unresolved_threads` — unresolved review threads

#### Step 2: Investigate and fix ALL issues

**Merge conflicts (handle FIRST, before anything else):**

If `merge_conflicts.conflicting` is `true`:
1. Identify the base branch from `merge_conflicts.base_branch`
2. Fetch the base branch and rebase:
   ```bash
   git fetch <remote> <base_branch>
   git rebase <remote>/<base_branch>
   ```
3. If there are conflicts, resolve them:
   - For each conflicted file, inspect the conflict markers and apply the correct resolution
   - Keep the intent of BOTH sides where possible; prefer the PR branch's changes for code it owns
   - `git add <resolved_file>` after resolving each file
   - `git rebase --continue`
4. Force-push the rebased branch:
   ```bash
   git push --force-with-lease
   ```
5. Continue with remaining issues below (failed checks, comments, threads)

For each other issue type:

**Failed checks:**
- Inspect the check's job logs: `gh api repos/{owner}/{repo}/actions/runs/{RUN_ID}/jobs --jq '.jobs[] | select(.conclusion == "failure") | .id'`
- Download logs: `gh api repos/{owner}/{repo}/actions/jobs/{JOB_ID}/logs`
- For Semgrep: download the report artifact
- For SonarCloud: check the bot comment via `gh pr view {PR} --json comments --jq '.comments[] | select(.author.login == "sonarqubecloud") | .body'`
- **Before fixing, determine if the failure is related to this PR's changes.** Check whether the failing test or check touches code changed by this PR. Compare against the base branch:
  ```bash
  # Get files changed by this PR
  gh pr diff {PR} --name-only
  # Compare with the failure — does it reference any of these files/modules?
  ```
  If the failure is clearly unrelated (e.g. an e2e test that fails on the base branch too, a test for a completely different module), do NOT attempt to fix it. Instead, report it as unrelated and exit immediately:
  - Print: `UNRELATED FAILURE: <check-name> — <reason it is unrelated>`
  - Do NOT commit, do NOT push, just exit. The monitor will detect the no-progress and stop.
- If the failure IS related, fix the code

**Bugbot comments (triage before fixing):**

Bugbot comments MUST be triaged individually before any fix is attempted. For each comment, classify it as one of:
- `FIX_REQUIRED` — real, in-scope issue that must be fixed
- `REJECTED` — invalid, out of scope, false positive, or based on incorrect assumptions
- `DEFERRED` — real but intentionally left unresolved (must state reason)

Then act on the classification:
- `FIX_REQUIRED` → fix the code at the indicated path/line, then reply to the thread explaining the fix and resolve the thread.
- `REJECTED` or `DEFERRED` → do NOT fix. Reply to the thread with a comment explaining the reasoning for the classification, then resolve the thread.

All Bugbot threads MUST be resolved after triage — either by fixing or by commenting with the reasoning.

**Unresolved threads:**
- Read each thread's comment to understand the request
- Fix the code

#### Step 3: Run all tests locally and confirm passing

#### Step 4: Push the fixes

Commit and push. Use a conventional commit message describing what was fixed.

#### Step 5: Reply to review comments and resolve threads

**This step is mandatory — unresolved threads cause the monitor to loop forever.**

For every Bugbot comment or review thread you addressed or triaged:
1. Reply to the thread explaining what was fixed, or — for REJECTED/DEFERRED Bugbot findings — the reasoning for not fixing
2. **Resolve the conversation** — use `gh api` to mark it resolved:
   ```bash
   gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "THREAD_ID"}) { thread { isResolved } } }'
   ```
3. Verify it is resolved before finishing — the monitor checks `isResolved == false` to detect remaining issues

- If fixes came from compliance checks, add a PR comment summarizing what was fixed

### Anti-patterns (DO NOT do these)

- Do NOT only check Bugbot and ignore Semgrep/SonarCloud/other checks
- Do NOT dismiss compliance failures without investigating the logs
- Do NOT assume a failing check is "pre-existing" without evidence from the target branch
- Do NOT open any URLs in a browser (Playwright or WebFetch) — use `gh` CLI or the GitHub MCP tools exclusively for all GitHub operations (PR views, check logs, comments, workflow runs)
- Do NOT leave review threads unresolved after fixing — the monitor will re-trigger on the same threads if they stay open
- Do NOT spend time fixing failures unrelated to this PR's changes — check `gh pr diff --name-only` against the failure, and if there is no overlap, exit immediately without committing
- Do NOT run tests repeatedly hoping an unrelated flaky test will pass — if a test fails and is unrelated, report it and exit
