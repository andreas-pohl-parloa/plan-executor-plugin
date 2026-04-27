# Demo Feature

## Goal

Demonstrate Superpowers format detection. The handover skill should default `type=feature` and all flags to `false`, then ask interactively for any missing field.

## Acceptance Criteria

- A new module `frob` exists.
- `cargo test --lib frob::` passes.

## Tasks

1. Add `src/frob.rs` with a stub `pub fn frob() -> u32 { 0 }`.
2. Wire `pub mod frob;` into `src/lib.rs`.
3. Add a unit test asserting `frob() == 0`.
