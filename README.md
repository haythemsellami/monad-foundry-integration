# Monad Foundry Integration Tests

Test suite to verify Monad's custom EVM behavior in Foundry (forge, anvil, cast).

## Prerequisites

Install Monad Foundry:

```bash
# Install monad-foundry from the repo
foundryup --repo haythemsellami/foundry --branch monad-forge-integration

# Verify it's available and set it for usage
foundryup --list
foundryup --use haythemsellami-branch-monad-forge-integration

# Verify installation
forge --version
# Should show: forge 1.5.0-dev (monad branch)
```

To switch between versions:
```bash
# Monad Foundry
foundryup --use haythemsellami-branch-monad-forge-integration

# Standard Foundry
foundryup --use stable
```

## Test Types

This repo contains two types of tests:

### 1. Forge Tests (`.t.sol`)

Solidity tests that run with `forge test`. These verify gas costs and EVM behavior at the opcode level.

```bash
# Run all forge tests
forge test

# Run with verbosity
forge test -vv

# Run specific test
forge test --match-test test_ColdBalanceGasCost
```

### 2. MIP-3 Memory Tests (`script/forge/`)

Profile-based forge tests that verify MIP-3 linear memory pricing across hardfork boundaries. Runs the same test contracts under `monad_eight` and `monad_nine` profiles.

```bash
./script/forge/test_mip3.sh
```

### 3. Chisel Tests (`script/test/chisel/`)

Shell scripts that test chisel REPL with Monad gas costs. No anvil needed.

```bash
./script/test/chisel/test_chisel_monad.sh
```

### 4. Anvil Scripts (`script/test/anvil/`)

Shell scripts that test behavior requiring real transactions (balance changes, gas charging). These use `anvil --monad` and `cast`.

```bash
# Start Monad anvil
anvil --monad

# In another terminal, run script
./script/test/anvil/test_gas_limit_charging.sh
```

## Test Files

### Forge Tests (`test/`)

#### `MonadGasTest.t.sol`
Comprehensive gas pricing tests organized into 4 sections:

| Section | Tests | What it verifies |
|---------|-------|------------------|
| Cold/Warm Access | `test_ColdBalanceGasCost`, `test_WarmBalanceGasCost`, `test_ColdExtcodesizeGasCost`, `test_ColdExtcodehashGasCost`, `test_ColdWarmDifferenceIsExact` | Cold account access costs 10,100 (vs Ethereum's 2,600) |
| SLOAD | `test_SloadColdWarmDifference` | Cold storage read cost 8,100 |
| SSTORE | `test_SstoreExactCosts`, `test_SstoreColdAccessCost` | Cold SSTORE costs 28,100 (8,100 + 20,000) |
| No-Refund | `test_NoRefundOnStorageClear`, `test_StorageRefundPattern` | Clearing storage costs same as modifying (no refund) |

```bash
forge test --match-contract MonadGasTest -vv
```

#### `RefundTest.t.sol`
Documents the no-refund behavior with anvil test results.

**Anvil comparison results:**
| Operation | Ethereum | Monad | Difference |
|-----------|----------|-------|------------|
| `setValue(1)` | 43,718 | 49,718 | +6,000 (cold storage) |
| `clearValue()` | 21,441 | 32,241 | +10,800 (no refund) |

```bash
forge test --match-contract RefundTest -vv
```

#### `BytecodeSizeLimitTest.t.sol`
Tests contract bytecode size limits.

```bash
forge test --match-contract BytecodeSizeLimitTest -vv
```

#### `Mip3MemoryTest.t.sol`
MIP-3 linear memory cost model tests across two hardfork profiles.

| Contract | Profile | Tests | What it verifies |
|----------|---------|-------|------------------|
| `MonadNineMip3Test` | `monad_nine` | 13 | Linear pricing (`words/2`), 8 MB pooled cap, sibling memory release, MCOPY/CREATE/CREATE2/KECCAK256/RETURN memory expansion |
| `MonadEightMip3RegressionTest` | `monad_eight` | 1 | Over-8 MB succeeds (cap not active before MonadNine) |
| `Mip3DifferentialTest` | both | 3 | Same expansion costs dramatically more under quadratic (MonadEight) vs linear (MonadNine) |

```bash
# Run MonadNine tests
FOUNDRY_PROFILE=monad_nine forge test --match-contract MonadNineMip3Test -vv

# Run MonadEight regression
FOUNDRY_PROFILE=monad_eight forge test --match-contract MonadEightMip3RegressionTest -vv

# Run all MIP-3 tests with the wrapper script
./script/forge/test_mip3.sh
```

### Chisel Tests (`script/test/chisel/`)

#### `test_chisel_monad.sh`
Verifies chisel uses Monad gas costs for cold/warm access.

```bash
./script/test/chisel/test_chisel_monad.sh
```

### Anvil Scripts (`script/test/anvil/`)

#### `test_gas_limit_charging.sh`
**Proves Monad charges based on `gas_limit`, not `gas_used`.**

```bash
# Terminal 1: Start Monad anvil
anvil --monad

# Terminal 2: Run test
./script/test/anvil/test_gas_limit_charging.sh
```

Expected output on Monad:
```
Gas limit:  100000
Gas used:   49718
Actual spent: matches gas_limit × price

>>> MONAD: Charged on GAS_LIMIT <<<
```

Expected output on Ethereum (standard anvil):
```
Gas limit:  100000
Gas used:   43718
Actual spent: matches gas_used × price

>>> ETHEREUM: Charged on GAS_USED <<<
```

#### `test_opcodes_precompiles_gas_pricing.sh`
Tests gas costs for opcodes and precompiles.

```bash
anvil --monad
./script/test/anvil/test_opcodes_precompiles_gas_pricing.sh
```

#### `test_mip3_memory.sh`
End-to-end MIP-3 verification through `anvil --monad --hardfork ...`.

Checks:
- Near-8 MB allocation succeeds on `MonadNine`
- Over-8 MB allocation reverts on `MonadNine`
- Over-8 MB allocation succeeds on `MonadEight`
- Pooled cap positive and negative parent/child cases on `MonadNine`
- High-offset `CREATE2` succeeds on `MonadNine`
- Same 1 MB allocation estimates higher gas on `MonadEight` than `MonadNine`

```bash
./script/test/anvil/test_mip3_memory.sh
```
