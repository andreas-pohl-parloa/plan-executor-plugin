# handover skill fixtures

These fixtures exercise format detection in `plan-executor:handover`.

## Files

- `plan-executor-format.md` — plan-executor format with all flag headers present. Handover should run non-interactively against this fixture and produce output equal to `expected-meta-plan-executor-format.json` (after substituting `<FIXTURES_DIR>` for the absolute fixtures-directory path at the time of regeneration).
- `superpowers-format.md` — Superpowers-style plan (`## Goal`, `## Acceptance Criteria`, `## Tasks`). Handover should detect the format, default `type=feature` + all flags `false`, and request the remaining metadata interactively. There is no canonical expected output because it depends on the answers the user gives at compile time.
- `plain-markdown.md` — unstructured plan / GitHub-issue-style body. Handover should ask for every required field. No canonical expected output.

## Regenerate outputs

```
claude -p "/plan-executor:handover \
  $(realpath fixtures/plan-executor-format.md) \
  --type=refactor --draft-pr"
```

## Validate outputs

The `plan-executor` Rust CLI does not validate `meta.json` files (only compiled `tasks.json` manifests). Validation of `meta.json` is the responsibility of `plan-executor:compile-plan`'s Pass 1 loader.
