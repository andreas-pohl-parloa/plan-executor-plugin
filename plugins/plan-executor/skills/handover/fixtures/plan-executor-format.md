# Demo Refactor — Implementation Plan

**Goal:** Demonstrate plan-executor format detection. Trivial scope so handover can run end-to-end without ambiguity.
**Type:** Refactor
**JIRA:** none
**Tech Stack:** Rust (edition 2024).
**Code Standards:** `rust-services:production-code-recipe`.
**Status:** READY
**no-worktree:** [ ]
**no-pr:** [ ]
**draft-pr:** [x]
**merge:** [ ]
**merge-admin:** [ ]
**non-interactive:** [ ]
**execution:** local

---

## Task 1: rename a constant

**Files:** `src/lib.rs`

- [ ] Rename `MAX_FOO` to `MAX_BAR`. Run `cargo test`.
