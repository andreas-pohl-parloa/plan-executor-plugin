# GPT-5.5 Support + codex-latest Retirement — Implementation Plan

**Goal:** Add OpenAI GPT-5.5 as a first-class supported model, retire the `codex-latest` alias, and make `gpt-5.5` the default value of `DEFAULT_FALLBACK_CHAIN` so Anthropic sessions fail over to it out of the box. Preserve backward compatibility for users with `codex-latest` already persisted in config.
**Type:** Feature
**JIRA:** CCP-0
**Tech Stack:** Rust 1.x, `tokio`, `tracing`, `serde`, `OnceLock` for one-time init. Existing workspace-level `cargo test` for TDD.
**Code Standards:** n/a
**Status:** READY
**no-worktree:** [ ]
**no-pr:** [ ]
**draft-pr:** [ ]
**merge:** [x]
**merge-admin:** [ ]
**non-interactive:** [x]
**execution:** remote
**add-marketplaces:** anthropics/claude-plugins-official, parloa/claudes-kitchen, JuliusBrussee/caveman, andreas-pohl-parloa/my-coding, andreas-pohl-parloa/plan-executor-plugin, parloa/inline-discussion
**add-plugins:** backend-services@claudes-kitchen, career-development@claudes-kitchen, caveman@caveman, gateway@claudes-kitchen, go-services@claudes-kitchen, inline-discussion@inline-discussion, my@my-coding, operational-excellence@claudes-kitchen, parloa-toolkit-services@claudes-kitchen, plan-executor@plan-executor, playwright@claude-plugins-official, python-services@claudes-kitchen, rust-services@claudes-kitchen, security@claudes-kitchen, skills-development@claudes-kitchen, superpowers@claude-plugins-official, threat-modeling@claudes-kitchen, typescript-services@claudes-kitchen, workflows@claudes-kitchen

---

**Architecture:** Add gpt-5.5 to the two lookup tables (`default_pricing_table` in `src/config/pricing.rs`, `MODEL_CONTEXT_WINDOWS` in `src/config/models.rs`). Flip the single-string default fallback const in `src/config/mod.rs`. Remove the alias surface in `src/config/models.rs` and its callers in `src/proxy/server.rs`, `src/proxy/commands.rs`, `src/cli/status.rs`, plus a stale rustdoc reference in `src/proxy/session.rs`. Add a one-time migration shim in `resolve_fallback_chain` that transparently rewrites `codex-latest` → `gpt-5.5` when reading persisted config, logging a deprecation warning once per process via a `OnceLock` gate.

**Source facts (verified via OpenAI web search and discussion):**
- `gpt-5.5`: input $5.00/M, output $30.00/M, cached input $0.50/M (10% of input, matches OpenAI's pattern for gpt-5.4), context window 1,000,000.
- OpenAI has no TTL-based cache-write premium: `cache_write_5m == cache_write_1h == input`.

**Spec reference:** `docs/discussions/2026-04-23-gpt-5-5-retire-codex-latest.md`.

## Task 0: Create worktree

**Files:**
- No code changes. Creates isolated worktree per the project's `CLAUDE.md` rule.

- [ ] **Step 1: Create the worktree**

Run:
```bash
cd /Users/andreas.pohl/workspace/code/claude-code-proxy
git fetch origin
git worktree add -b feat/gpt-5-5-support ../.my/worktrees/claude-code-proxy-gpt-5-5 origin/main
cd ../.my/worktrees/claude-code-proxy-gpt-5-5
```

Expected: `Preparing worktree ...` then `Branch 'feat/gpt-5-5-support' set up to track 'origin/main'.`

- [ ] **Step 2: Verify clean working tree**

Run:
```bash
git status
git log -1 --oneline
```

Expected: `nothing to commit, working tree clean` and the HEAD commit matches `origin/main`.

- [ ] **Step 3: Baseline build**

Run:
```bash
cargo build
```

Expected: `Compiling claude-code-proxy ... Finished `dev` profile`. No errors. If this fails, stop and investigate before proceeding — all subsequent steps assume a clean baseline.

---

## Task 1: Add gpt-5.5 pricing (TDD)

**Files:**
- Modify: `src/config/pricing.rs` (insert entry in `default_pricing_table`, add test)

- [ ] **Step 1: Write the failing test**

Open `src/config/pricing.rs`. Find the test `get_pricing_for_gpt54` (around line 535). Immediately **after** that test, insert:

```rust
    #[test]
    fn get_pricing_for_gpt55() {
        let p = get_pricing_for_model("gpt-5.5").unwrap();
        assert!((p.input_per_mtok - 5.00).abs() < 0.001);
        assert!((p.cache_write_5m_per_mtok - 5.00).abs() < 0.001);
        assert!((p.cache_write_1h_per_mtok - 5.00).abs() < 0.001);
        assert!((p.cache_read_per_mtok - 0.50).abs() < 0.001);
        assert!((p.output_per_mtok - 30.00).abs() < 0.001);
        assert!(p.input_per_mtok_long.is_none());
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cargo test --lib -- config::pricing::tests::get_pricing_for_gpt55 --nocapture
```

Expected: test panics on the first `assert!` with `(p.input_per_mtok - 5.00).abs() < 0.001` being false.

Why: `get_pricing_for_model` uses longest-prefix matching (`find_longest_prefix_match`). Before Step 3 adds the specific `gpt-5.5` row, `"gpt-5.5".starts_with("gpt-5")` matches the broader `("gpt-5", p!(1.25, 1.25, 1.25, 0.125, 10.00))` entry, so `unwrap()` returns `Some(gpt-5 pricing)` with `input_per_mtok = 1.25`. The first assertion therefore fails with `left = 1.25, right = 5.00` (not a `None` unwrap). That is the intended TDD-red state.

- [ ] **Step 3: Add the pricing table entry**

In `src/config/pricing.rs`, find `default_pricing_table()`. Inside the `vec![...]` block, locate the `gpt-5.4` entry (around line 134):

```rust
        ("gpt-5.4", p!(2.50, 2.50, 2.50, 0.25, 15.00)),
```

Insert immediately **above** it:

```rust
        ("gpt-5.5", p!(5.00, 5.00, 5.00, 0.50, 30.00)),
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cargo test --lib -- config::pricing::tests::get_pricing_for_gpt55 --nocapture
```

Expected: `test config::pricing::tests::get_pricing_for_gpt55 ... ok`.

- [ ] **Step 5: Run the full pricing test module to catch regressions**

Run:
```bash
cargo test --lib -- config::pricing::tests --nocapture
```

Expected: all tests pass (including the existing `get_pricing_for_gpt54`, `get_pricing_unknown_model_returns_none`, etc.).

- [ ] **Step 6: Commit**

```bash
git add src/config/pricing.rs
git commit -m "feat(gpt-5.5): add pricing table entry (\$5/\$30/M, \$0.50 cache)"
```

---

## Task 2: Add gpt-5.5 context window (TDD)

**Files:**
- Modify: `src/config/models.rs` (insert into `MODEL_CONTEXT_WINDOWS`, add test)

- [ ] **Step 1: Write the failing test**

Open `src/config/models.rs`. Find the test `gpt54_model_context_window` at the bottom of the `tests` module. Insert immediately **after** it:

```rust
    #[test]
    fn gpt55_model_context_window() {
        assert_eq!(get_context_window_size("gpt-5.5"), 1_000_000);
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cargo test --lib -- config::models::tests::gpt55_model_context_window --nocapture
```

Expected: `assertion `left == right` failed: left: 200000, right: 1000000` (falls through to `DEFAULT_CONTEXT_WINDOW` because no prefix matches).

- [ ] **Step 3: Add the context-window entry**

In `src/config/models.rs`, locate the `MODEL_CONTEXT_WINDOWS` array. Find the existing `gpt-5.4` entry:

```rust
    ("gpt-5.4", 400_000),
```

Insert immediately **above** it:

```rust
    ("gpt-5.5", 1_000_000),
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cargo test --lib -- config::models::tests::gpt55_model_context_window --nocapture
```

Expected: `test config::models::tests::gpt55_model_context_window ... ok`.

- [ ] **Step 5: Run the full models test module**

Run:
```bash
cargo test --lib -- config::models::tests --nocapture
```

Expected: all tests pass. No regressions in existing context-window tests.

- [ ] **Step 6: Commit**

```bash
git add src/config/models.rs
git commit -m "feat(gpt-5.5): add 1M context window to models table"
```

---

## Task 3: Add soft-migration shim for `codex-latest` → `gpt-5.5` (TDD)

**Why:** Users with `codex-latest` persisted in `~/.claude-code-proxy/config.json` or `PROXY_FALLBACK_CHAIN` must continue to work after the alias is removed. We transparently rewrite the string at `resolve_fallback_chain` time and log a one-time warning.

**Files:**
- Modify: `src/config/mod.rs` (add the migration shim to `resolve_fallback_chain`, add tests)

- [ ] **Step 1: Write the failing tests**

Open `src/config/mod.rs`. Scroll to the bottom of the `#[cfg(test)] mod tests` block. Add these two tests at the end of the `mod tests` block, **before** the closing `}`:

```rust
    #[test]
    fn codex_latest_in_env_is_migrated_to_gpt55() {
        with_env(
            &[
                ("PROXY_FALLBACK_CHAIN", "codex-latest"),
                ("PROXY_CONFIG_DIR", "/tmp/ccp-test-nonexistent"),
            ],
            || {
                let config = build_config();
                assert_eq!(config.fallback_chain, vec!["gpt-5.5"]);
            },
        );
    }

    #[test]
    fn codex_latest_in_env_list_is_migrated_per_entry() {
        with_env(
            &[
                ("PROXY_FALLBACK_CHAIN", "codex-latest,gpt-5.4"),
                ("PROXY_CONFIG_DIR", "/tmp/ccp-test-nonexistent"),
            ],
            || {
                let config = build_config();
                assert_eq!(config.fallback_chain, vec!["gpt-5.5", "gpt-5.4"]);
            },
        );
    }

    #[test]
    fn codex_latest_in_file_is_migrated_to_gpt55() {
        let tmp = tempfile::tempdir().unwrap();
        let config_path = tmp.path().join("config.json");
        fs::write(
            &config_path,
            r#"{"model":"default","fallbackChain":["codex-latest"]}"#,
        )
        .unwrap();

        with_env(
            &[("PROXY_CONFIG_DIR", tmp.path().to_str().unwrap())],
            || {
                let config = build_config();
                assert_eq!(config.fallback_chain, vec!["gpt-5.5"]);
            },
        );
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cargo test --lib -- config::tests::codex_latest --nocapture
```

Expected: all three tests fail with assertions like `left: ["codex-latest"], right: ["gpt-5.5"]` — the migration shim does not exist yet.

- [ ] **Step 3: Add migration helper + wire into `resolve_fallback_chain`**

Open `src/config/mod.rs`. Near the other file-level `OnceLock` declarations (search for `OnceLock::new()` or add near the top of the module after existing `use` imports), add:

```rust
/// Deprecated alias that now migrates to `gpt-5.5` on read.
const LEGACY_CODEX_LATEST_ALIAS: &str = "codex-latest";

static CODEX_LATEST_DEPRECATION_LOGGED: std::sync::OnceLock<()> = std::sync::OnceLock::new();

/// Rewrites any legacy `codex-latest` entries to `gpt-5.5`, logging once per process.
fn migrate_legacy_fallback_entries(entries: Vec<String>) -> Vec<String> {
    let mut rewrote = false;
    let migrated: Vec<String> = entries
        .into_iter()
        .map(|entry| {
            if entry == LEGACY_CODEX_LATEST_ALIAS {
                rewrote = true;
                "gpt-5.5".to_owned()
            } else {
                entry
            }
        })
        .collect();
    if rewrote && CODEX_LATEST_DEPRECATION_LOGGED.set(()).is_ok() {
        tracing::warn!(
            "'codex-latest' fallback alias is deprecated and has been rewritten to 'gpt-5.5'. \
             Update your config or PROXY_FALLBACK_CHAIN to silence this warning."
        );
    }
    migrated
}
```

Then replace the existing `resolve_fallback_chain` function. Current body (lines 509–520):

```rust
fn resolve_fallback_chain(file: &ConfigFile) -> Vec<String> {
    env_var("PROXY_FALLBACK_CHAIN")
        .map(|v| {
            v.split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect()
        })
        .or_else(|| file.fallback_chain.clone())
        .unwrap_or_else(|| vec![DEFAULT_FALLBACK_CHAIN.to_owned()])
}
```

Replace with:

```rust
fn resolve_fallback_chain(file: &ConfigFile) -> Vec<String> {
    let chain = env_var("PROXY_FALLBACK_CHAIN")
        .map(|v| {
            v.split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect()
        })
        .or_else(|| file.fallback_chain.clone())
        .unwrap_or_else(|| vec![DEFAULT_FALLBACK_CHAIN.to_owned()]);
    migrate_legacy_fallback_entries(chain)
}
```

- [ ] **Step 4: Run the migration tests to verify they pass**

Run:
```bash
cargo test --lib -- config::tests::codex_latest --nocapture
```

Expected: all three tests pass.

- [ ] **Step 5: Run the full config test module**

Run:
```bash
cargo test --lib -- config::tests --nocapture
```

Expected: exactly one test fails — `default_fallback_chain`. It uses `with_clean_env` (no env / no file override), so `resolve_fallback_chain` falls back to `DEFAULT_FALLBACK_CHAIN` (still `"codex-latest"` until Task 4), and the new migration shim rewrites it to `"gpt-5.5"`. The test's assertion `vec!["codex-latest"]` is therefore violated. It is fixed in Task 4.

All other tests pass, including:
- `has_missing_fields_complete` — builds a `ConfigFile` struct directly and checks `has_missing_fields()`; never calls `build_config`, so the shim is not on its path.
- `ensure_config_complete_skips_when_complete` — writes a file with `fallbackChain: ["codex-latest"]` and asserts that the on-disk file is unchanged. The shim mutates the in-memory `Config` only; `ensure_config_complete` does not rewrite the file unless `has_missing_fields()` is true (it is not), so the on-disk bytes remain identical and the assertion holds.

If more than the one expected test fails, stop and investigate before committing.

- [ ] **Step 6: Commit**

```bash
git add src/config/mod.rs
git commit -m "feat(fallback): soft-migrate legacy codex-latest entries to gpt-5.5"
```

---

## Task 4: Switch `DEFAULT_FALLBACK_CHAIN` to `gpt-5.5` and update fixtures

**Files:**
- Modify: `src/config/mod.rs` (const + 3 tests/fixtures)

- [ ] **Step 1: Update the constant**

Open `src/config/mod.rs`. Find line 243:

```rust
/// Default fallback chain.
const DEFAULT_FALLBACK_CHAIN: &str = "codex-latest";
```

Replace with:

```rust
/// Default fallback chain.
const DEFAULT_FALLBACK_CHAIN: &str = "gpt-5.5";
```

- [ ] **Step 2: Update the `default_fallback_chain` test**

Find the test around line 758:

```rust
    #[test]
    fn default_fallback_chain() {
        with_clean_env(|| {
            let config = build_config();
            assert_eq!(config.fallback_chain, vec!["codex-latest"]);
        });
    }
```

Replace the assertion line with:

```rust
            assert_eq!(config.fallback_chain, vec!["gpt-5.5"]);
```

- [ ] **Step 3: Update the `has_missing_fields_complete` fixture**

Find around line 1026:

```rust
            fallback_chain: Some(vec!["codex-latest".to_owned()]),
```

Replace with:

```rust
            fallback_chain: Some(vec!["gpt-5.5".to_owned()]),
```

- [ ] **Step 4: Update the `ensure_config_complete_skips_when_complete` fixture**

Find around line 1109:

```rust
            "fallbackChain": ["codex-latest"],
```

Replace with:

```rust
            "fallbackChain": ["gpt-5.5"],
```

- [ ] **Step 5: Run the full config test module**

Run:
```bash
cargo test --lib -- config::tests --nocapture
```

Expected: all tests pass. Confirm specifically that `default_fallback_chain`, `has_missing_fields_complete`, `ensure_config_complete_skips_when_complete`, and the three codex_latest_* migration tests from Task 3 are all green.

- [ ] **Step 6: Commit**

```bash
git add src/config/mod.rs
git commit -m "feat(fallback): default fallback chain is now gpt-5.5"
```

---

## Task 5: Remove the `codex-latest` alias surface from `src/config/models.rs`

**Files:**
- Modify: `src/config/models.rs` (remove alias const, statics, functions, tests)

- [ ] **Step 1: Delete the alias const and default model const**

Open `src/config/models.rs`. Remove these two lines (around 11–15):

```rust
/// Alias string for the latest codex model.
const CODEX_LATEST_ALIAS: &str = "codex-latest";

/// Default resolved model for codex-latest (overridable via `PROXY_CODEX_LATEST_MODEL`).
const DEFAULT_CODEX_LATEST_MODEL: &str = "gpt-5.3-codex";
```

- [ ] **Step 2: Delete the `RESOLVED_CODEX_LATEST` static**

Around line 47, remove:

```rust
static RESOLVED_CODEX_LATEST: OnceLock<String> = OnceLock::new();
```

- [ ] **Step 3: Delete `is_codex_latest_alias`**

Remove the entire function block (around lines 69–82):

```rust
/// Checks if a model name is the codex-latest alias.
///
/// # Examples
/// ...
#[must_use]
pub fn is_codex_latest_alias(model: &str) -> bool {
    model == CODEX_LATEST_ALIAS
}
```

- [ ] **Step 4: Delete `init_codex_latest` and `get_resolved_codex_latest`**

Remove both function blocks (around lines 84–121).

- [ ] **Step 5: Simplify `resolve_model_alias`**

Current function (around lines 213–224):

```rust
#[must_use]
pub fn resolve_model_alias(model: &str) -> String {
    if is_codex_latest_alias(model) {
        return get_resolved_codex_latest();
    }
    if model == GEMINI_PRO_LATEST_ALIAS {
        return get_resolved_gemini_pro_latest();
    }
    if model == GEMINI_FLASH_LATEST_ALIAS {
        return get_resolved_gemini_flash_latest();
    }
    model.to_owned()
}
```

Replace with:

```rust
#[must_use]
pub fn resolve_model_alias(model: &str) -> String {
    if model == GEMINI_PRO_LATEST_ALIAS {
        return get_resolved_gemini_pro_latest();
    }
    if model == GEMINI_FLASH_LATEST_ALIAS {
        return get_resolved_gemini_flash_latest();
    }
    model.to_owned()
}
```

- [ ] **Step 6: Remove the alias label from `format_models_table`**

In the same file, find the block inside `format_models_table` (around lines 305–313):

```rust
        let alias = if m.name == get_resolved_codex_latest() {
            CODEX_LATEST_ALIAS
        } else if m.name == get_resolved_gemini_pro_latest() {
            GEMINI_PRO_LATEST_ALIAS
        } else if m.name == get_resolved_gemini_flash_latest() {
            GEMINI_FLASH_LATEST_ALIAS
        } else {
            ""
        };
```

Replace with:

```rust
        let alias = if m.name == get_resolved_gemini_pro_latest() {
            GEMINI_PRO_LATEST_ALIAS
        } else if m.name == get_resolved_gemini_flash_latest() {
            GEMINI_FLASH_LATEST_ALIAS
        } else {
            ""
        };
```

- [ ] **Step 7: Delete the codex-latest tests**

Still in `src/config/models.rs`, inside the `#[cfg(test)] mod tests` block, remove these five tests in their entirety:

- `codex_latest_alias_detected`
- `non_alias_not_detected`
- `init_returns_default_codex_model`
- `get_resolved_returns_initialized_model`
- `resolve_alias_returns_resolved_model`

Also, in the module-level doc comment at the top of the file (around line 4), update:

```rust
//! model aliases like "codex-latest" to actual model names.
```

to:

```rust
//! model aliases (e.g. gemini-pro-latest) to actual model names.
```

- [ ] **Step 8: Update the `resolve_model_alias` doc example**

Current doc-example inside `resolve_model_alias` (around lines 196–210) mentions codex-latest. Replace the doc block with:

```rust
/// Resolves a model alias to the actual model name.
///
/// Returns the resolved name for known aliases ("gemini-pro-latest",
/// "gemini-flash-latest"), or the input unchanged if it is not an alias.
///
/// # Examples
///
/// ```
/// use claude_code_proxy::config::models::{init_gemini_aliases, resolve_model_alias};
/// init_gemini_aliases();
/// assert_eq!(resolve_model_alias("gemini-pro-latest"), "gemini-3.1-pro-preview");
/// assert_eq!(resolve_model_alias("gpt-4"), "gpt-4");
/// ```
```

- [ ] **Step 9: Build (will fail, callers still reference removed symbols)**

Run:
```bash
cargo build
```

Expected: `error[E0432]: unresolved import` or `cannot find function is_codex_latest_alias` from `src/proxy/server.rs`, `src/proxy/commands.rs`, `src/cli/status.rs`. This is expected — Task 6 fixes them.

- [ ] **Step 10: Do NOT commit yet**

The tree does not compile. Proceed directly to Task 6.

---

## Task 6: Remove `codex-latest` from callers

**Files:**
- Modify: `src/proxy/server.rs` (import + init call + known_prefixes)
- Modify: `src/proxy/commands.rs` (3 known-prefix strings + 1 display branch + 1 test)
- Modify: `src/cli/status.rs` (1 import + 2 call sites)
- Modify: `src/proxy/session.rs` (1 stale rustdoc reference)

- [ ] **Step 1: Fix `src/proxy/server.rs` import**

Open `src/proxy/server.rs`. Line 21 currently reads:

```rust
use crate::config::models::{init_codex_latest, init_gemini_aliases, resolve_model_alias};
```

Replace with:

```rust
use crate::config::models::{init_gemini_aliases, resolve_model_alias};
```

- [ ] **Step 2: Remove the `init_codex_latest()` call**

Line 100 currently reads:

```rust
    let _ = init_codex_latest();
    let _ = init_gemini_aliases();
```

Delete the first line so only `init_gemini_aliases()` remains:

```rust
    let _ = init_gemini_aliases();
```

- [ ] **Step 3: Drop `codex-latest` from the known_prefixes list in `server.rs`**

Line 733 currently reads:

```rust
        let known_prefixes = ["gpt-", "o3", "o4", "claude-", "default", "codex-latest"];
```

Replace with:

```rust
        let known_prefixes = ["gpt-", "o3", "o4", "claude-", "default"];
```

- [ ] **Step 4: Fix `src/proxy/commands.rs` help strings (line 263)**

Find the string at around line 263:

```rust
                 Known prefixes: claude-, gpt-, o3, o4, codex-latest, default"
```

Replace with:

```rust
                 Known prefixes: claude-, gpt-, o3, o4, default"
```

- [ ] **Step 5: Fix `src/proxy/commands.rs` help string at line 289**

Around line 289, find the identical string and apply the same replacement:

```rust
             Known prefixes: claude-, gpt-, o3, o4, codex-latest, default"
```

becomes:

```rust
             Known prefixes: claude-, gpt-, o3, o4, default"
```

- [ ] **Step 6: Fix `src/proxy/commands.rs` known_prefixes array (line 384)**

Line 384 currently reads:

```rust
            let known_prefixes = ["gpt-", "o3", "o4", "claude-", "default", "codex-latest"];
```

Replace with:

```rust
            let known_prefixes = ["gpt-", "o3", "o4", "claude-", "default"];
```

- [ ] **Step 7: Simplify `model_display` in `commands.rs` (around line 430)**

Current block (around lines 430–438):

```rust
            let model_display = if crate::config::models::is_codex_latest_alias(&config.model) {
                format!(
                    "{} ({})",
                    config.model,
                    crate::config::models::resolve_model_alias(&config.model)
                )
            } else {
                config.model.clone()
            };
```

Replace with:

```rust
            let model_display = config.model.clone();
```

- [ ] **Step 8: Update the `parse_default_model` test (around line 1314)**

Current test:

```rust
    #[test]
    fn parse_default_model() {
        let cmd = parse_command("model codex-latest");
        assert!(matches!(
            cmd,
            Ok(ProxyCommand::DefaultModel { model: ref m }) if m == "codex-latest"
        ));
    }
```

Replace with:

```rust
    #[test]
    fn parse_default_model() {
        let cmd = parse_command("model gpt-5.5");
        assert!(matches!(
            cmd,
            Ok(ProxyCommand::DefaultModel { model: ref m }) if m == "gpt-5.5"
        ));
    }
```

- [ ] **Step 9: Fix `src/cli/status.rs` import**

Line 13 currently reads:

```rust
use crate::config::models::{is_codex_latest_alias, resolve_model_alias};
```

Replace with:

```rust
use crate::config::models::resolve_model_alias;
```

- [ ] **Step 10: Remove codex-latest display branch in `print_model_line`**

Current `print_model_line` (lines 92–103):

```rust
fn print_model_line(config: &crate::config::Config, stats: &Option<ServerStats>) {
    let display_model = stats
        .as_ref()
        .and_then(|s| s.model.clone())
        .unwrap_or_else(|| config.model.clone());
    if is_codex_latest_alias(&display_model) {
        let resolved = resolve_model_alias(&display_model);
        println!("Model:            {display_model} ({resolved})");
    } else {
        println!("Model:            {display_model}");
    }
}
```

Replace with:

```rust
fn print_model_line(config: &crate::config::Config, stats: &Option<ServerStats>) {
    let display_model = stats
        .as_ref()
        .and_then(|s| s.model.clone())
        .unwrap_or_else(|| config.model.clone());
    println!("Model:            {display_model}");
}
```

- [ ] **Step 11: Remove codex-latest display branch in `format_chain_model`**

Current (lines 129–135):

```rust
fn format_chain_model(model: &str) -> String {
    if is_codex_latest_alias(model) {
        format!("{model} ({})", resolve_model_alias(model))
    } else {
        model.to_owned()
    }
}
```

Replace with:

```rust
fn format_chain_model(model: &str) -> String {
    model.to_owned()
}
```

Note: `resolve_model_alias` is still imported because the Gemini alias expansion path uses it elsewhere — leave the import untouched. If `cargo build` reports `resolve_model_alias` as unused in this file, remove the import line as well.

- [ ] **Step 12: Update stale codex-latest doc comment in `src/proxy/session.rs`**

Line 728 of `src/proxy/session.rs` currently contains a rustdoc example referencing the retired alias:

```rust
/// Model aliases (e.g. `"codex-latest"`) are resolved to their canonical names so the
```

Replace with:

```rust
/// Model aliases (e.g. `"gemini-pro-latest"`) are resolved to their canonical names so the
```

Run `grep -n codex-latest src/` afterwards to confirm no Rust source references remain (CHANGELOG.md and historical README context still contain the string but are allowed).

- [ ] **Step 13: Full build**

Run:
```bash
cargo build
```

Expected: clean build, no errors and no new warnings. If `resolve_model_alias` is reported unused in `src/cli/status.rs`, remove it from the import and rebuild.

- [ ] **Step 14: Full test run**

Run:
```bash
cargo test
```

Expected: every test passes — lib tests, doc tests, and the integration tests in `tests/`. The integration test `tests/session_fallback_test.rs` uses `gpt-5.3-codex` directly (not `codex-latest`) and is unaffected.

- [ ] **Step 15: Commit**

```bash
git add src/config/models.rs src/proxy/server.rs src/proxy/commands.rs src/cli/status.rs src/proxy/session.rs
git commit -m "chore!: retire codex-latest alias (use gpt-5.5 or a concrete model)"
```

---

## Task 7: Update `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the `Essential commands` example (line ~102)**

Find:

```markdown
   claude-code-proxy model codex-latest            # Switch to Codex, affects only new sessions
```

Replace with:

```markdown
   claude-code-proxy model gpt-5.5                 # Switch to GPT-5.5, affects only new sessions
```

- [ ] **Step 2: Update the two-column command table (lines ~117, 120)**

Find:

```markdown
   | `:proxy:session model codex-latest` | Switch the current session's model |
```

Replace with:

```markdown
   | `:proxy:session model gpt-5.5` | Switch the current session's model |
```

Find:

```markdown
   | `:proxy:model codex-latest` | Change the default model for new sessions |
```

Replace with:

```markdown
   | `:proxy:model gpt-5.5` | Change the default model for new sessions |
```

- [ ] **Step 3: Update the `Automatic Failover` section (line ~228)**

Find:

```markdown
Default chain: `default` -> `codex-latest` (Anthropic fails over to the latest Codex model).
```

Replace with:

```markdown
Default chain: `default` -> `gpt-5.5` (Anthropic fails over to GPT-5.5).
```

- [ ] **Step 4: Update the sample `status` output (line ~279)**

Find:

```
Fallback chain:   default -> codex-latest (gpt-5.2-codex)
```

Replace with:

```
Fallback chain:   default -> gpt-5.5
```

- [ ] **Step 5: Update the runtime-model examples (lines ~289–297)**

Find the block:

```markdown
claude-code-proxy model gpt-5.2
claude-code-proxy model gpt-5.2-codex
claude-code-proxy model codex-latest     # Alias — resolves to the latest gpt-*-codex model
claude-code-proxy model default          # Passthrough to Anthropic (uses Claude Code's model)
```

Replace with:

```markdown
claude-code-proxy model gpt-5.5
claude-code-proxy model gpt-5.4
claude-code-proxy model gpt-5.3-codex
claude-code-proxy model default          # Passthrough to Anthropic (uses Claude Code's model)
```

Find:

```markdown
Model names are validated — known prefixes: `gpt-`, `o3`, `o4`, `claude-`, `gemini-`, `default`, `codex-latest`.

`codex-latest` is an alias that resolves to the latest Codex model (currently `gpt-5.2-codex`). It is resolved at proxy startup and all external outputs (statusline, session list, API requests) use the resolved name.
```

Replace with:

```markdown
Model names are validated — known prefixes: `gpt-`, `o3`, `o4`, `claude-`, `gemini-`, `default`.

Legacy `codex-latest` entries found in persisted config or `PROXY_FALLBACK_CHAIN` are automatically rewritten to `gpt-5.5` at load time; a one-time deprecation warning is logged.
```

- [ ] **Step 6: Update the `config.json` example (line ~405)**

Find:

```json
  "fallbackChain": ["codex-latest"],
```

Replace with:

```json
  "fallbackChain": ["gpt-5.5"],
```

- [ ] **Step 7: Update the env-var table (lines ~420, 424)**

Find:

```markdown
| `PROXY_MODEL` | `model` | `default` | Model (`default` for passthrough, `codex-latest` for Codex) |
```

Replace with:

```markdown
| `PROXY_MODEL` | `model` | `default` | Model (`default` for passthrough, `gpt-5.5` for OpenAI) |
```

Find:

```markdown
| `PROXY_FALLBACK_CHAIN` | `fallbackChain` | `codex-latest` | Comma-separated fallback models for automatic failover |
```

Replace with:

```markdown
| `PROXY_FALLBACK_CHAIN` | `fallbackChain` | `gpt-5.5` | Comma-separated fallback models for automatic failover |
```

- [ ] **Step 8: Sanity-check — no stray references**

Run:
```bash
grep -n 'codex-latest' README.md
```

Expected: **no matches**. If any remain, update them to `gpt-5.5` before committing.

- [ ] **Step 9: Commit**

```bash
git add README.md
git commit -m "docs: update README for gpt-5.5 default and codex-latest retirement"
```

---

## Task 8: End-to-end spot-check with isolated test proxy

**Why:** CLAUDE.md forbids touching the production proxy on port 9000. We verify the changes against a dedicated test proxy on port 9001 with an isolated `HOME` so the test proxy's state directory (`$HOME/.claude-code-proxy`) points at a throwaway dir — the production proxy's pid/log/session files are not touched.

**Important:** The codebase currently reads the state directory from `dirs::home_dir().join(".claude-code-proxy")` (see `src/cli/utils.rs:233-237`), not from `PROXY_HOME`. `PROXY_HOME` is **not** an honored variable. We therefore override `HOME` per the valid CLAUDE.md alternative.

**Files:**
- None modified. Validation only.

- [ ] **Step 1: Build binary inside the worktree**

Run (from the worktree root):
```bash
cargo build
```

Expected: clean build.

- [ ] **Step 2: Create the isolated HOME and start the test proxy on port 9001**

Run:
```bash
# 1. create the isolated HOME (state dir lives inside it at .claude-code-proxy)
mkdir -p "$PWD/.tmp-home/.claude-code-proxy"

# 2. make sure we have the absolute binary path before overriding HOME
BIN="$PWD/target/debug/claude-code-proxy"

# 3. start the test proxy with isolated HOME and port 9001
HOME="$PWD/.tmp-home" \
PROXY_PORT=9001 \
PROXY_AUTO_UPDATE=false \
nohup "$BIN" start > "$PWD/.tmp-home/.claude-code-proxy/test-proxy.log" 2>&1 &
sleep 2
cat "$PWD/.tmp-home/.claude-code-proxy/test-proxy.log" | head -30
```

Expected: log shows the proxy listening on `0.0.0.0:9001`. If it shows port 9000, stop — the HOME override did not apply.

Sanity-check that production proxy state was NOT touched:
```bash
ls -la "$HOME/.claude-code-proxy/proxy.pid"   # production pid file — should be unchanged
ls -la "$PWD/.tmp-home/.claude-code-proxy/proxy.pid"  # test pid file — should exist
```

Expected: both PID files exist and have different content / mtimes.

- [ ] **Step 3: Verify fallbackChain default**

The HTTP route that exposes `fallbackChain` is `GET /_proxy/stats` (see `src/proxy/server.rs:632-652`). There is no `/v1/proxy/config` route.

Run:
```bash
curl -s http://127.0.0.1:9001/_proxy/stats | python3 -m json.tool | grep -A2 fallbackChain
```

Expected: output contains:
```json
    "fallbackChain": [
        "gpt-5.5"
    ],
```

- [ ] **Step 4: Verify gpt-5.5 appears in the models table**

Note: the CLI listing subcommand is `models` (plural). `model <name>` sets the default model and requires a name.

Run:
```bash
HOME="$PWD/.tmp-home" "$BIN" models
```

Expected: stdout contains a row `gpt-5.5 ... 1000k ... $5.00 ... $30.00`.

- [ ] **Step 5: Verify soft-migration shim fires for legacy configs**

Stop the test proxy, restart with a legacy env value, and confirm the warning is emitted.

Run:
```bash
# stop the first test proxy
HOME="$PWD/.tmp-home" "$BIN" stop
sleep 1

# start again with a legacy value
HOME="$PWD/.tmp-home" \
PROXY_PORT=9001 \
PROXY_AUTO_UPDATE=false \
PROXY_FALLBACK_CHAIN="codex-latest" \
PROXY_LOG_LEVEL=debug \
nohup "$BIN" start > "$PWD/.tmp-home/.claude-code-proxy/test-proxy.log" 2>&1 &
sleep 2
grep -F "codex-latest" "$PWD/.tmp-home/.claude-code-proxy/test-proxy.log" || echo "WARN not found"
curl -s http://127.0.0.1:9001/_proxy/stats | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["fallbackChain"])'
```

Expected:
- The log grep finds a `WARN` line containing `'codex-latest' fallback alias is deprecated and has been rewritten to 'gpt-5.5'`.
- The curl output prints `['gpt-5.5']`.

- [ ] **Step 6: Stop the test proxy and clean up**

Run:
```bash
HOME="$PWD/.tmp-home" "$BIN" stop
sleep 1
rm -rf "$PWD/.tmp-home"
```

Expected: test proxy stopped, `.tmp-home` removed. Production proxy on port 9000 is untouched — verify with:
```bash
lsof -iTCP:9000 -sTCP:LISTEN
ls -la "$HOME/.claude-code-proxy/proxy.pid"  # production pid file still present
```

- [ ] **Step 7: No commit**

Validation only. No file changes.

---

## Task 9: Open PR

**Files:**
- None modified. Git / GitHub only.

- [ ] **Step 1: Push the branch**

Run:
```bash
git push -u origin feat/gpt-5-5-support
```

Expected: branch pushed and tracking set.

- [ ] **Step 2: Open the PR using conventional-commit title**

Per project convention (Parloa): `feat: …` or `feat(<ticket>): …`. This change has no Jira ticket, so use a scoped commit-style title.

Run:
```bash
gh pr create \
  --base main \
  --title "feat: add gpt-5.5, set as default fallback, retire codex-latest alias" \
  --body "$(cat <<'EOF'
## Summary
- Add `gpt-5.5` to pricing table (\$5/\$30/M, \$0.50 cached, 1M context)
- Set `DEFAULT_FALLBACK_CHAIN` to `gpt-5.5` (was `codex-latest`)
- Retire the `codex-latest` alias
- Soft-migrate legacy `codex-latest` entries in config/env to `gpt-5.5` with a one-time deprecation warning

## Backward compatibility
Users with `codex-latest` persisted in `~/.claude-code-proxy/config.json` or set via `PROXY_FALLBACK_CHAIN` are transparently migrated at load time. A single deprecation warning is logged per process.

## Test plan
- [ ] `cargo test` — all green
- [ ] Spot-check test proxy on port 9001: `fallbackChain == ["gpt-5.5"]`
- [ ] Spot-check soft migration: `PROXY_FALLBACK_CHAIN=codex-latest` rewrites to `gpt-5.5` and emits the deprecation warning
- [ ] Production proxy on port 9000 was **not** touched at any point

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed. Report the URL back to the user.

- [ ] **Step 3: Confirm CI triggered**

Run:
```bash
gh pr checks
```

Expected: checks start running. Per project convention (`~/workspace/code/CLAUDE.md`): poll CI no more than 3 times, at least 5 minutes apart. Do not mark the PR as "done" until all checks pass and there are no unresolved review threads.

---

## Self-review notes

- **Spec coverage:** every bullet in `docs/discussions/2026-04-23-gpt-5-5-retire-codex-latest.md` maps to a task: pricing (Task 1), context window (Task 2), soft migration (Task 3, resolved from thread t-2), default fallback (Task 4), alias retirement (Tasks 5–6), README (Task 7), validation (Task 8), PR (Task 9).
- **Placeholders:** none — every code block shows exact strings and every shell block shows the exact command.
- **Type / name consistency:** `migrate_legacy_fallback_entries` is the single helper referenced by `resolve_fallback_chain`. `CODEX_LATEST_DEPRECATION_LOGGED` / `LEGACY_CODEX_LATEST_ALIAS` are introduced in Task 3 and not referenced elsewhere (they are private module items).
- **CLAUDE.md adherence:** Task 0 creates an isolated worktree; Task 8 uses an isolated `HOME` (not `PROXY_HOME`, which the code does not honor) on port 9001 and never touches port 9000 or the production `~/.claude-code-proxy` state dir.
- **Post-review fixes applied (reviewer team, first pass):**
  - F1 — Task 1 Step 2 failure narrative corrected: `get_pricing_for_model("gpt-5.5")` returns `Some(gpt-5 pricing)` via longest-prefix, test fails on `assert!` not `unwrap()`.
  - F2 — Task 3 Step 5 corrected: only `default_fallback_chain` fails after the shim is added; `has_missing_fields_complete` and `ensure_config_complete_skips_when_complete` continue to pass.
  - F3 — Task 8 Steps 3 & 5: replaced non-existent `GET /v1/proxy/config` with `GET /_proxy/stats`.
  - F4 — Task 8 Step 4: replaced `model` (which needs a name arg) with `models` (the listing subcommand).
  - F5 — Task 8: replaced `PROXY_HOME` (not honored by the code) with `HOME` override; proven-safe state isolation.
  - F6 — Task 6 Step 12: added rewrite of the stale `codex-latest` rustdoc reference at `src/proxy/session.rs:728`.
