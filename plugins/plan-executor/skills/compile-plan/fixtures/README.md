# compile-plan fixtures

## Files

- `plan-gpt-5-5-support.md` — real past plan (small, 8 tasks). Used as the canonical fixture for regression tests of the skill's output.
- `plan-conversation-gateway.md` — real past plan (large, conv-gw scope). Used to smoke-test the skill against a non-trivial plan.
- `expected-gpt-5-5-tasks.json` — canonical expected output for `plan-gpt-5-5-support.md`, taken from experiment trial 1 of `/tmp/pe-compile-experiment/trials/gpt-5-5-support/`. Trials 1 and 2 were bit-identical. Use this to regression-check semantic-equivalent output (not byte-equivalent: wave decomposition may vary slightly across LLM runs — see below). The `plan.path` field is stored as the placeholder `<FIXTURES_DIR>/plan-gpt-5-5-support.md`; substitute the real absolute fixtures-directory path before comparing.
- There is NO canonical expected output for `plan-conversation-gateway.md` on purpose. The conv-gw experiment produced three distinct but semantically valid wave decompositions across trials. Enforcing bit-equivalence would flag false positives. See experiment findings §6.

## Regenerate outputs

First run handover to produce the `meta.json` sidecar:

```
claude -p "/plan-executor:handover \
  $(realpath fixtures/plan-gpt-5-5-support.md) \
  --type=feature --jira=CCP-0 --merge"
```

Then run compile-plan, passing the meta.json path (printed by handover as `HANDOVER:`) as the fourth argument:

```
claude -p "/plan-executor:compile-plan \
  $(realpath fixtures/plan-gpt-5-5-support.md) \
  $(realpath tasks.schema.json) \
  /tmp/compile-out \
  $(realpath fixtures/plan-gpt-5-5-support.md.meta.json)"
```

## Validate outputs

```
plan-executor validate --schema=tasks /tmp/compile-out/tasks.json
```

The `plan-executor` Rust binary must be on `PATH`. The compile-plan skill itself self-validates via this same CLI in Pass 5.

## Fix-loop fixtures (APPEND mode)

- `findings-sample.json` — example reviewer findings consumed by `compile-plan` APPEND mode (`$5`). Conforms to `../findings.schema.json`.
- `expected-tasks-with-fix-waves.json` — synthetic post-APPEND manifest illustrating: (a) original waves preserved, (b) round-1 fix-wave with id 100 depending on last impl wave, (c) round-2 fix-wave with id 101 depending on the prior fix-wave.
