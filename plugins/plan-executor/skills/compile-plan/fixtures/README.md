# compile-plan fixtures

## Files

- `plan-gpt-5-5-support.md` — real past plan (small, 8 tasks). Used as the canonical fixture for regression tests of the skill's output.
- `plan-conversation-gateway.md` — real past plan (large, conv-gw scope). Used to smoke-test the skill against a non-trivial plan.
- `expected-gpt-5-5-tasks.json` — canonical expected output for `plan-gpt-5-5-support.md`, taken from experiment trial 1 of `/tmp/pe-compile-experiment/trials/gpt-5-5-support/`. Trials 1 and 2 were bit-identical. Use this to regression-check semantic-equivalent output (not byte-equivalent: wave decomposition may vary slightly across LLM runs — see below).
- There is NO canonical expected output for `plan-conversation-gateway.md` on purpose. The conv-gw experiment produced three distinct but semantically valid wave decompositions across trials. Enforcing bit-equivalence would flag false positives. See experiment findings §6.

## Regenerate outputs

```
claude -p "/plan-executor:compile-plan \
  fixtures/plan-gpt-5-5-support.md \
  tasks.schema.json \
  /tmp/compile-out"
```

## Validate outputs

```
plan-executor validate /tmp/compile-out/tasks.json
```

(The `plan-executor validate` CLI is added in the companion plan-executor repo PR; forward-references that work.)
