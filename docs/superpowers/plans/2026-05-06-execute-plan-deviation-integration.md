# Execute-Plan Deviation Journal Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach the interactive `plan-executor:execute-plan` skill (and its review/validation helpers) to participate in the deviation-journal protocol so in-session orchestrator runs match daemon and foreground binary runs.

**Architecture:** Edit four SKILL.md files in `plan-executor-plugin/plugins/plan-executor/skills/`. The orchestrator reads canonical `<plan-stem>/tasks/task-<id>.md` prompts, prepends a deviation-journal protocol block (using the same marker the binary uses), digests the journal between waves, threads the digest into review and validation helpers, and adds a "Plan deviations" section to the final summary.

**Tech Stack:** Markdown SKILL.md files. No code, no tests. Verification is markdown lint + manual smoke check that the marker matches the binary's `DEVIATION_MARKER`.

---

## File Structure

**Modify:**

- `plugins/plan-executor/skills/execute-plan/SKILL.md` — Phase 3 wrapper-file refactor; between-wave digest read; Phase 5/6 input plumbing; Phase 8 deviations section + archive.
- `plugins/plan-executor/skills/review-execution-output/SKILL.md` — declare optional `deviation_journal_path` and `deviation_digest` inputs; pass them through to the reviewer team.
- `plugins/plan-executor/skills/validate-execution-plan/SKILL.md` — declare optional `deviation_journal_path` and `deviation_digest` inputs; surface them in the validator-prompt section with the trust contract.
- `plugins/plan-executor/skills/run-reviewer-team/SKILL.md` — accept the optional fields from the calling helper and surface the digest in reviewer prompts with the trust contract.

No code, no tests. Each task touches one file at a time so they can be committed independently and reviewed in isolation.

---

### Task 1: Phase 3 — wrapper file refactor in execute-plan SKILL.md

**Files:**

- Modify: `plugins/plan-executor/skills/execute-plan/SKILL.md` (Phase 3 section, lines 25-60)

- [ ] **Step 1: Replace Phase 3 sub-task creation steps**

In `plugins/plan-executor/skills/execute-plan/SKILL.md`, locate the "For each sub-task in the current wave:" block under "# PHASE 3: WAVE-BASED EXECUTION". Replace items 1 and 2 with:

```markdown
1. **Read the canonical sub-task prompt.** The file lives at `<plan-stem>/tasks/task-<id>.md` where `<plan-stem>` is the manifest directory (e.g. `docs/superpowers/plans/2026-05-05-apply-button/`). Compile-plan already wrote it; the orchestrator MUST NOT modify it.
2. **Build a wrapper file** at `<execution_root>/.tmp-subtask-wave<W>-<task_id>.md` (one per task per wave; the wave id avoids name collisions on resume). The wrapper file content, in this order:

   a. **Sub-Agent Instructions banner.** Verbatim:

      ```
      You are a focused implementation agent. Implement exactly what this prompt describes. Nothing more, nothing less. Do NOT read or reference any other plan document, roadmap, or task files.

      Recipes to load via the Skill tool before writing any code: <recipe-list>.

      Working directory: <execution_root>.

      After completing the task, report: all files you created or modified, any exported types or function signatures later tasks may depend on, and the result of any verification commands you ran.

      ---
      ```

   b. **Deviation journal protocol block.** Verbatim, including the marker that ensures parity with the binary's `handoff::DEVIATION_MARKER`:

      ```
      > **Deviation journal (plan-executor enforced — do not remove):**
      >
      > If you discover a mismatch between this task and the codebase, or you intentionally skip/substitute/scope-change part of the task, write a validated journal entry.
      >
      > Constants for this task:
      > - journal_path: `<execution_root>/.plan-executor/deviations.jsonl`
      > - job_id: `<synthesized-job-id>`
      > - phase: `wave_execution`
      > - wave_id: `<W>`
      > - task_id: `<task_id>`
      > - agent_index: `<1-based-index-within-wave>`
      >
      > Protocol:
      > 1. Create one JSON object matching `plan-executor validate --schema=deviation-journal-entry`.
      > 2. Validate it with `plan-executor validate --schema=deviation-journal-entry -`.
      > 3. Append it as one line to `journal_path` only after validation passes.
      > 4. Do not ask the user. Do not use the journal to justify incomplete work. If a required task cannot be completed, fail explicitly.

      ---
      ```

   c. **Prior deviation digest** (only when the previous wave produced entries; see Phase 3a for how the digest is built). Verbatim header followed by the digest body, then a separator:

      ```
      > Prior deviation digest for context:
      > <digest body — one line per "> " bullet from the digest renderer in Phase 3a>

      --- task body below ---
      ```

   d. **Body.** Read `<plan-stem>/tasks/task-<id>.md` and copy its contents verbatim. Do NOT edit, summarize, or strip any code blocks.

   When the wrapper file already exists from a prior attempt (resume mid-wave), check whether the deviation block marker `Deviation journal (plan-executor enforced` is already present near the top. If present, reuse the wrapper as-is. If absent, regenerate from scratch.
3. **Synthesize the job_id.** Compute it once per orchestrator invocation as `interactive-<short-sha>-<UTC-yyyymmdd-hhmmss>`, where `<short-sha>` is the first 7 chars of `sha1(manifest.plan.path)`. Reuse the same value for every wrapper preamble in this run.
4. **Launch the sub-agent.** Use the Agent tool with a general-purpose agent. The prompt tells the sub-agent:
   - Read only the wrapper file.
   - Treat the wrapper file as the sole source of truth.
   - Load the listed recipes via the Skill tool before writing code.
   - Write tests only when the wrapper says to write them.
   - Report files created/modified and any exports later tasks may depend on.
   - Work in the execution root.
   - Set the Agent `model` parameter to match the orchestrator's current model on every Agent call.
5. **Run independent sub-tasks in parallel when safe.** Tasks with shared files or shared dependencies MUST run sequentially.
```

Update item 5 of the "After all sub-agents in the current wave complete:" block to read:

```markdown
5. **Delete wrapper files for the completed wave** (`<execution_root>/.tmp-subtask-wave<W>-*.md`). Wrapper files for failed waves stay on disk so resume can reuse them.
```

- [ ] **Step 2: Verify deviation marker matches the binary**

The wrapper-block header `> **Deviation journal (plan-executor enforced — do not remove):**` must produce the substring `Deviation journal (plan-executor enforced` because that is the marker the binary's `ensure_deviation_block_in_prompt` checks for.

Run:

```bash
grep -F 'Deviation journal (plan-executor enforced' /Users/andreas.pohl/workspace/code/plan-executor-plugin/plugins/plan-executor/skills/execute-plan/SKILL.md
```

Expected: at least one matching line.

- [ ] **Step 3: Commit**

```bash
git add plugins/plan-executor/skills/execute-plan/SKILL.md
git commit -m "feat(execute-plan): wrapper files with deviation block + canonical task body"
```

---

### Task 2: Between-wave digest read in execute-plan SKILL.md

**Files:**

- Modify: `plugins/plan-executor/skills/execute-plan/SKILL.md` (Phase 3 section)

- [ ] **Step 1: Insert a new "Phase 3a — between-wave digest read" subsection**

Add the following new subsection AFTER the "Delete wrapper files for the completed wave" item and BEFORE the "Proceed to the next wave" item in Phase 3. Insert verbatim:

```markdown
**Between waves — read and digest the deviation journal:**

After a wave completes successfully and before the next wave's wrappers are built:

1. Run the validator on the journal file:

   ```bash
   plan-executor validate --schema=deviation-journal <execution_root>/.plan-executor/deviations.jsonl
   ```

   - If the file does not exist, the digest is empty. Skip the next steps; the next wave's wrapper omits the "Prior deviation digest" block.
   - If the validator returns non-zero (`ERROR:` lines on stderr), log the validator's `ERROR:` lines into the orchestrator's display output and proceed with an empty digest. Malformed entries are advisory; the run never aborts because of a bad journal line.

2. Read each non-empty line of `<execution_root>/.plan-executor/deviations.jsonl` as JSON.

3. Render the digest with this exact per-entry format (matching the binary's `digest()` output for `DigestScope::All`):

   ```
   - Task <task_id> / <category> / <severity>:
     Claim: <claim>
     Evidence: <path>:<lines> — <summary>      # for evidence kind = file_line
     Evidence: <path> — <summary>              # for command_log / test_result
     Evidence: commit <commit> — <summary>     # for commit
     Impact: <impact>
   ```

   - `<task_id>` falls back to `repo-wide` when null/absent.
   - Render `<category>` and `<severity>` with the binary's Debug-format casing (e.g. `ScopeChange`, `Critical`) for parity.
   - One block per entry, separated by a single blank line.

4. Cap the digest. If the rendered digest exceeds 200 lines or 32 KiB, drop entries in this priority order until it fits:
   1. keep all `severity == critical` entries,
   2. keep entries whose evidence `path` matches a file the upcoming wave will edit (orchestrator can derive this from the wave's task bodies),
   3. keep most-recent entries by `created_at`.

   When truncation occurs, append a final line `[deviation digest truncated]`.

5. Hold the digest in memory for the duration of the next wave. It is regenerated each time this subsection runs.

The same digest is also passed into Phase 5 and Phase 6 helper inputs as `deviation_digest`, with the journal file path as `deviation_journal_path`. See Phase 5 and Phase 6 for input details.
```

- [ ] **Step 2: Commit**

```bash
git add plugins/plan-executor/skills/execute-plan/SKILL.md
git commit -m "feat(execute-plan): between-wave deviation journal digest"
```

---

### Task 3: Phase 5 helper input plumbing in execute-plan SKILL.md

**Files:**

- Modify: `plugins/plan-executor/skills/execute-plan/SKILL.md` (Phase 5 section, around lines 91-100)

- [ ] **Step 1: Add deviation fields to the Phase 5 input list**

In Phase 5's "Pass the review helper explicit structured inputs, at minimum:" bullet list, add two items:

```markdown
  - `deviation_journal_path` (optional) — absolute path to `<execution_root>/.plan-executor/deviations.jsonl`. Omit when the file does not exist.
  - `deviation_digest` (optional) — rendered digest from the most recent between-wave read (see Phase 3a). Empty string when the journal is empty.
```

These fields are documented as optional in the helper's input contract so runs without a journal still work.

- [ ] **Step 2: Commit**

```bash
git add plugins/plan-executor/skills/execute-plan/SKILL.md
git commit -m "feat(execute-plan): pass deviation digest into Phase 5 helper"
```

---

### Task 4: Phase 6 helper input plumbing in execute-plan SKILL.md

**Files:**

- Modify: `plugins/plan-executor/skills/execute-plan/SKILL.md` (Phase 6 section, around lines 126-136)

- [ ] **Step 1: Add deviation fields to the Phase 6 input list**

In Phase 6's "Pass the validation helper explicit structured inputs, at minimum:" bullet list, add two items:

```markdown
  - `deviation_journal_path` (optional) — absolute path to `<execution_root>/.plan-executor/deviations.jsonl`. Omit when the file does not exist.
  - `deviation_digest` (optional) — rendered digest from the most recent between-wave read (see Phase 3a). Empty string when the journal is empty.
```

- [ ] **Step 2: Commit**

```bash
git add plugins/plan-executor/skills/execute-plan/SKILL.md
git commit -m "feat(execute-plan): pass deviation digest into Phase 6 helper"
```

---

### Task 5: Phase 8 deviations section + archive in execute-plan SKILL.md

**Files:**

- Modify: `plugins/plan-executor/skills/execute-plan/SKILL.md` (Phase 8 section, lines 177-191)

- [ ] **Step 1: Extend the Phase 8 summary template**

Append the following to Phase 8's summary template, AFTER the **Totals** bullet:

```markdown
- **Plan deviations** — when the deviation journal contains any entry whose category is `skip`, `substitute`, `scope_change`, or any unresolved `blocker` (severity `critical`), include a `## Plan deviations` section. Format each entry as:

  ```
  - Task <task_id>: <category> / <severity> — <claim>
    Evidence: <first evidence rendered as in the digest>
  ```

  Routine `discovery` entries are omitted. When no notable entries exist, omit the section entirely.
```

- [ ] **Step 2: Append a journal-archive step to Phase 8**

After the summary-print step in Phase 8, append:

```markdown
**Archive the deviation journal** after the summary is printed:

- When a daemon `job_dir` is known (interactive runs typically do not have one, but the field may be present when the orchestrator was launched as a daemon follow-up), copy `<execution_root>/.plan-executor/deviations.jsonl` to `<job_dir>/deviations.jsonl`.
- Otherwise copy it to `<plan-stem>/deviations.jsonl` so the artifacts stay co-located with the manifest.

Archive failures are logged and ignored; they do not fail the run.
```

- [ ] **Step 3: Commit**

```bash
git add plugins/plan-executor/skills/execute-plan/SKILL.md
git commit -m "feat(execute-plan): summarize and archive plan deviations"
```

---

### Task 6: review-execution-output digest plumbing

**Files:**

- Modify: `plugins/plan-executor/skills/review-execution-output/SKILL.md`

- [ ] **Step 1: Add optional inputs**

In the "Required Inputs" / inputs section, after the existing inputs, append:

```markdown

### Optional inputs (deviation journal)

- `deviation_journal_path` (optional) — absolute path to `<execution_root>/.plan-executor/deviations.jsonl`. May be absent when the orchestrator's run produced no journal yet.
- `deviation_digest` (optional) — rendered digest of the journal as built by the orchestrator's between-wave read. May be empty.

When the helper passes these into the reviewer team, it must forward them as the same field names so the reviewer prompts can include them. An empty digest is normal; treat it as "no prior deviations" and proceed.
```

- [ ] **Step 2: Forward to the reviewer team**

Locate the section that describes invoking `plan-executor:run-reviewer-team`. Add a sentence:

```markdown
When `deviation_journal_path` and/or `deviation_digest` are provided by the orchestrator, forward them verbatim to `plan-executor:run-reviewer-team` under the same field names.
```

- [ ] **Step 3: Commit**

```bash
git add plugins/plan-executor/skills/review-execution-output/SKILL.md
git commit -m "feat(review): forward deviation digest to reviewer team"
```

---

### Task 7: validate-execution-plan digest plumbing + trust contract

**Files:**

- Modify: `plugins/plan-executor/skills/validate-execution-plan/SKILL.md`

- [ ] **Step 1: Add optional inputs**

In the "Required inputs" section, after the existing inputs, append:

```markdown

### Optional inputs (deviation journal)

- `deviation_journal_path` (optional) — absolute path to `<execution_root>/.plan-executor/deviations.jsonl`. May be absent when the orchestrator's run produced no journal yet.
- `deviation_digest` (optional) — rendered digest of the journal as built by the orchestrator's between-wave read. May be empty.

An empty digest is normal; treat it as "no deviations to consider" and proceed.
```

- [ ] **Step 2: Add the trust contract to the validator-prompt section**

Locate the section that describes the validator-prompt body. Add a paragraph:

```markdown
**Deviation journal entries are advisory.** PASS only if the plan requirement is implemented in code or the deviation's evidence still verifies. If the evidence is stale, missing, or free-text only, treat the requirement as unmet. Surface stale-evidence findings as gaps with `missing_evidence` describing the discrepancy.
```

- [ ] **Step 3: Commit**

```bash
git add plugins/plan-executor/skills/validate-execution-plan/SKILL.md
git commit -m "feat(validation): consume deviation digest with trust contract"
```

---

### Task 8: run-reviewer-team digest surface + trust contract

**Files:**

- Modify: `plugins/plan-executor/skills/run-reviewer-team/SKILL.md`

- [ ] **Step 1: Add optional inputs**

In the "Required Inputs" section, after the existing inputs, append:

```markdown

### Optional inputs (deviation journal)

- `deviation_journal_path` (optional) — absolute path to `<execution_root>/.plan-executor/deviations.jsonl`.
- `deviation_digest` (optional) — rendered digest of the journal as built by the orchestrator's between-wave read.

An empty digest is normal; surface it to reviewers as "no prior deviations" and proceed.
```

- [ ] **Step 2: Add the trust contract to the reviewer-prompt section**

Locate the section that describes how reviewer prompts are built. Add a paragraph:

```markdown
**Use deviation entries as leads.** When `deviation_digest` is non-empty, include it verbatim in every reviewer's prompt with the heading `## Prior deviations to verify`. Tell reviewers: "Re-read the evidence cited in each deviation before accepting the claim. Do not suppress a finding solely because a deviation exists." Stale or unverifiable evidence is itself a finding.
```

- [ ] **Step 3: Commit**

```bash
git add plugins/plan-executor/skills/run-reviewer-team/SKILL.md
git commit -m "feat(reviewer-team): surface deviation digest with trust contract"
```

---

### Task 9: Verification

**Files:**

- Read-only checks across the four modified SKILL.md files.

- [ ] **Step 1: Marker parity check**

The deviation block marker in `execute-plan` SKILL.md must contain the substring the binary checks for:

```bash
grep -F 'Deviation journal (plan-executor enforced' \
  /Users/andreas.pohl/workspace/code/plan-executor-plugin/plugins/plan-executor/skills/execute-plan/SKILL.md
```

Expected: at least one matching line.

Cross-check against the binary:

```bash
grep -F 'Deviation journal (plan-executor enforced' \
  /Users/andreas.pohl/workspace/code/plan-executor/src/handoff.rs
```

Expected: at least one matching line. Both files must produce a match.

- [ ] **Step 2: Required-field coverage check**

Confirm the new optional fields are mentioned across the four files:

```bash
for f in \
  plugins/plan-executor/skills/execute-plan/SKILL.md \
  plugins/plan-executor/skills/review-execution-output/SKILL.md \
  plugins/plan-executor/skills/validate-execution-plan/SKILL.md \
  plugins/plan-executor/skills/run-reviewer-team/SKILL.md; do
  echo "=== $f ==="
  grep -nE 'deviation_journal_path|deviation_digest' "$f" || echo "MISSING"
done
```

Expected: every file lists both fields at least once. No `MISSING` lines.

- [ ] **Step 3: Phase 8 deviations-section check**

```bash
grep -nE '## Plan deviations|notable_summary' \
  /Users/andreas.pohl/workspace/code/plan-executor-plugin/plugins/plan-executor/skills/execute-plan/SKILL.md
```

Expected: at least one match for `## Plan deviations`.

- [ ] **Step 4: Phase 3a digest-read check**

```bash
grep -nE 'Between waves|deviation-journal|DigestScope::All' \
  /Users/andreas.pohl/workspace/code/plan-executor-plugin/plugins/plan-executor/skills/execute-plan/SKILL.md
```

Expected: at least one match for the between-wave heading and at least one mention of the validator command.

- [ ] **Step 5: Commit any verification fixes**

If any of the above checks fail, edit the relevant SKILL.md to address the gap, then re-run the check. Commit fixes individually:

```bash
git add plugins/plan-executor/skills/<which-file>/SKILL.md
git commit -m "fix(deviation-integration): address verification finding"
```

If all checks pass without fixes, do not create a commit.
