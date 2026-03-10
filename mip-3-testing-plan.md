# MIP-3 Integration Testing Plan

Make `forge test` the primary MIP-3 test surface.

MIP-3 is interpreter behavior, not RPC behavior: the linear memory formula
lives in `memory/mod.rs`, the 8 MB cap in `cfg.rs`, the hardfork gate at
MonadNine+ in `spec.rs`, and the 22 custom opcode replacements in
`instructions.rs`. This repo already uses `forge test` for opcode-level
invariants and anvil scripts for transaction / RPC behavior.

`anvil --monad` still hardcodes `MonadSpecId::default()`, so node-driven
tests cannot distinguish MonadEight from MonadNine yet.

## Test Shape

Use two Foundry profiles and a thin wrapper script.

`monad_hardfork` is a first-class config field, and `forge test`,
`forge script`, and `chisel` all honor `config.monad_spec_id()`.

Add these profiles to `foundry.toml`:

```toml
[profile.monad_eight]
monad_hardfork = "MonadEight"

[profile.monad_nine]
monad_hardfork = "MonadNine"
```

Add one focused file: `test/Mip3MemoryTest.t.sol`.

## MonadNine — Exact MIP-3 Assertions

These are stable because the spec is explicit (`words / 2` in
`memory/mod.rs`, 8 MB cap in `cfg.rs`).

Run with `forge test --profile monad_nine`.

### Linear memory pricing (MSTORE)

- Single expansion: force memory to N bytes via `mstore(sub(N, 32), 0)`,
  measure gas. Assert the memory component equals `ceil(N / 32) / 2`.
- Stepped expansion: expand to A, then to B. Assert the second charge is
  `cost(B) - cost(A)`, i.e. `(words_B - words_A) / 2` delta only.

### 8 MB cap

- Exact 8 MB (8,388,608 bytes = 262,144 words) succeeds.
- 8 MB + 32 bytes reverts (MemoryLimitOOG).

### Pooled parent/child cap

- Parent allocates near the limit, child small alloc succeeds.
- Parent allocates near the limit, slightly larger child alloc fails.
- Child memory release: two sibling child calls of the same size both
  succeed (SharedMemory checkpoint is restored between calls).

### MCOPY canary

MCOPY is one of the replaced handlers (`instructions.rs`), and its resize
path depends on `max(dst, src)` (`opcodes.rs`).

- Test `dst >> src` with `len = 32` to isolate destination memory expansion.
- Test `src >> dst` with `len = 32` to isolate source memory expansion.

### CREATE / CREATE2 canary

Both are replaced handlers (`instructions.rs`). Test with tiny initcode at a
huge `code_offset` with very small `len`, so memory expansion dominates while
initcode metering and CREATE2 hashing stay small.

### KECCAK256 or RETURN canary

One non-copy, non-store opcode to prove the handler replacement works across
opcode categories.

## MonadEight — Hardfork-Gating Semantics

Run with `forge test --profile monad_eight`.

No exact formula assertions — on MonadEight, memory pricing is the upstream
REVM quadratic path, and asserting exact totals from Solidity is brittle.

- Over-8 MB allocation succeeds, proving the cap is hardfork-gated and does
  not apply to MonadEight.

## Differential Script

A thin wrapper script runs both profiles and compares gas for the same
memory probe:

- Same forced expansion (e.g. 1 MB MSTORE) is more expensive under
  MonadEight (quadratic) than MonadNine (linear).
- Same forced MCOPY expansion is more expensive under MonadEight.
- Same high-offset CREATE2 is more expensive under MonadEight.

This avoids trying to introspect the active profile from Solidity.

## Harness Conventions

- Use inline assembly `mstore(sub(size, 32), 0)` to force deterministic
  memory growth.
- Measure gas with `gasleft()` inside Solidity, not by shell parsing.
- Use low-level `call` for child-failure tests so the parent can keep
  asserting after the child reverts.
- Optimizer off (`foundry.toml` already sets `optimizer = false`) so
  overhead constants are stable.

## Anvil / Script Layer

No anvil-based MIP-3 tests until anvil can select MonadNine.

Once hardfork selection lands, add one black-box RPC script
(`script/test/anvil/test_mip3_memory.sh`) to verify:

- Same calldata estimates cheaper on MonadNine than MonadEight.
- Exact 8 MB call succeeds, over-cap call reverts.
- One pooled parent/child case via a deployed harness contract.

Skip fork tests. They are a poor fit for exact gas assertions and make the
suite depend on remote state.
