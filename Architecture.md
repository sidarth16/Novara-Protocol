# Novara Protocol — Architecture

> Navigation map for Codex, Claude Code, and contributors.

---

## System Overview

```
                        ┌─────────────────────────────────┐
                        │         LP (User)               │
                        │                                 │
                        │  depositWithProtection()        │
                        │  removeLiquidity()              │
                        └────────────┬────────────────────┘
                                     │
                                     ▼
┌────────────────────────────────────────────────────────────────┐
│                        NovaraHook.sol                          │
│                                                                │
│  The entry point. Implements all Uniswap v4 hook callbacks.    │
│  Owns position state. Coordinates all other contracts.         │
│                                                                │
│  afterAddLiquidity()       → snapshot entry, init position     │
│  beforeSwap()              → detect range exits, update vol    │
│  afterSwap()               → collect premium → reserve         │
│  beforeRemoveLiquidity()   → compute IL, schedule payout       │
│  afterRemoveLiquidity()    → transfer payout to LP             │
│  redeployFromAave()        → called by Reactive / Chainlink    │
└────────┬───────────────┬──────────────────┬────────────────────┘
         │               │                  │
         ▼               ▼                  ▼
┌────────────────┐ ┌─────────────────┐ ┌───────────────────────┐
│ NovaraReserve  │ │ NovaraAave      │ │ NovaraReactive.sol     │
│ .sol           │ │ Adapter.sol     │ │                        │
│                │ │                 │ │ Deployed on Reactive   │
│ Reserve        │ │ Abstracts Aave  │ │ Network (Lasna).       │
│ accounting.    │ │ v3 / Morpho.    │ │                        │
│                │ │                 │ │ Subscribes to:         │
│ deposit()      │ │ deposit()       │ │ • PositionCreated      │
│ withdraw()     │ │ withdraw()      │ │ • PriceExitedRange     │
│ recordLiab()   │ │ getYield()      │ │ • PriceEnteredRange    │
│ clearLiab()    │ │ currentAPY()    │ │ • Cron100              │
│ getCoverage()  │ │                 │ │                        │
│ getMaxPayout() │ │ Talks to:       │ │ Fires callbacks to:    │
│                │ │ Aave v3 Pool    │ │ redeployFromAave()     │
└────────┬───────┘ └────────┬────────┘ └───────────────────────┘
         │                  │
         ▼                  ▼
┌────────────────────────────────────────────────────────────────┐
│                        libraries/                              │
│                                                                │
│  ILCalculator.sol          ReserveMath.sol                     │
│                                                                │
│  Pure functions only.      Pure functions only.                │
│  No state. No imports      No state. No imports                │
│  outside math.             outside math.                       │
│                                                                │
│  computeIL()               computeCoverageRatio()              │
│  positionValue()           computePremiumRate()                │
│  hodlValue()               computeMaxPayout()                  │
│  sqrtPriceToTick()         computeVolatilityMultiplier()       │
└────────────────────────────────────────────────────────────────┘
```

---

## File Structure

```
novara/
│
├── src/
│   ├── NovaraHook.sol              # Primary hook. Inherits BaseHook.
│   ├── NovaraReserve.sol           # Reserve accounting. Called only by hook.
│   ├── NovaraAaveAdapter.sol       # Aave v3 / Morpho abstraction layer.
│   ├── NovaraReactive.sol          # Reactive Smart Contract (Lasna testnet).
│   │
│   └── libraries/
│       ├── ILCalculator.sol        # IL math. Pure functions only.
│       └── ReserveMath.sol         # Reserve + premium math. Pure functions only.
│
├── test/
│   ├── NovaraHook.t.sol            # Hook callback unit tests
│   ├── NovaraReserve.t.sol         # Reserve accounting tests
│   ├── NovaraAaveAdapter.t.sol     # Aave integration tests (fork)
│   ├── ILComputation.t.sol         # IL formula correctness
│   ├── PremiumModel.t.sol          # Premium rate + volatility scaling
│   ├── FullLifecycle.t.sol         # End-to-end integration test
│   ├── EdgeCases.t.sol             # Boundaries, zero liquidity, Aave failure
│   └── SecurityTests.t.sol         # Reserve drain, flash loan, reentrancy
│
├── script/
│   ├── DeployNovara.s.sol          # Full deployment: hook + reserve + adapter
│   └── DeployReactive.s.sol        # Reactive contract deployment (Lasna)
│
├── ARCHITECTURE.md                 # This file
└── README.md                       # Full spec, economic model, demo flow
```

---

## Data Flow

### Happy Path — Full LP Lifecycle

```
1. LP calls depositWithProtection()
        │
        ▼
2. afterAddLiquidity fires
   → position created, entry price snapshotted
   → emit PositionCreated
        │
        ▼
3. Swaps occur, price drifts toward LP boundary
   beforeSwap fires on each swap
   → tick crossings tracked (volatility)
   → premium collected → NovaraReserve
        │
        ▼
4. Price crosses tickLower or tickUpper
   afterSwap detects out-of-range
   → position state: ACTIVE → IDLE
   → emit PriceExitedRange
        │
        ▼
5. NovaraReactive receives PriceExitedRange
   → fires callback: NovaraHook.deployToAave()
   → idle tokens deposited into Aave via NovaraAaveAdapter
   → aTokens held by hook
        │
        ▼
6. Time passes. Aave yield accrues.
   Yield routed to NovaraReserve on next interaction.
   Coverage ratio climbs.
        │
        ▼
7. Chainlink Automation detects price re-entry
   → performUpkeep() called
   → NovaraReactive fires redeployment callback
   → NovaraHook.redeployFromAave() executes
   → aTokens redeemed, tokens back in Uniswap
   → position state: IDLE → ACTIVE
        │
        ▼
8. LP calls removeLiquidity()
   beforeRemoveLiquidity fires
   → IL computed via ILCalculator
   → payout scheduled via NovaraReserve.getMaxPayout()
        │
        ▼
9. afterRemoveLiquidity fires
   → IL payout transferred to LP
   → emit ILCompensated(positionId, ilAmount, payoutAmount)
   → position state: ACTIVE → EXITED
```

---

## Contract Responsibilities — One Line Each

| Contract | Single Responsibility |
|----------|-----------------------|
| `NovaraHook` | Coordinate everything. Own position state. Fire events. |
| `NovaraReserve` | Track reserve assets and liabilities. Compute coverage. |
| `NovaraAaveAdapter` | Deposit and withdraw from Aave. Return yield. Nothing else. |
| `NovaraReactive` | Listen for events. Decide callbacks. Fire redeployments. |
| `ILCalculator` | Compute IL given entry price, exit price, range, liquidity. |
| `ReserveMath` | Compute premium rates, coverage ratios, max payouts. |

---

## Key Invariants

These must hold at all times. Tests must verify each.

```
1. reserveAssets >= 0 always
   → reserve can never go negative

2. payout <= reserveAssets always
   → hook never pays more than it holds

3. position.state transitions are one-directional
   → CREATED → ACTIVE → IDLE ↔ ACTIVE → EXITED
   → no state can go back to CREATED

4. aTokenBalance == sum of all IDLE position deposits
   → every idle token is accounted for in Aave

5. totalLiabilities == sum of estimated IL exposure across ACTIVE positions
   → reserve always knows its full obligation

6. coverageRatio = reserveAssets / totalLiabilities
   → recomputed after every reserve change
```

---

## External Contracts (Sepolia)

```
Uniswap v4 PoolManager        0x...  (confirm from v4-core)
Aave v3 Pool                  0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951
Aave v3 PoolAddressesProvider 0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A
USDC (Sepolia)                0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8
WETH (Sepolia)                0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14
Chainlink ETH/USD             0x694AA1769357215DE4FAC081bf1f309aDC325306
Chainlink Automation Registry 0x86EFBD0b6736Bed994962f9797049422A3A8E8Ad
```

---

## Build Order for Codex

Generate contracts in this exact order to avoid import errors:

```
1. libraries/ILCalculator.sol       (no dependencies)
2. libraries/ReserveMath.sol        (no dependencies)
3. NovaraReserve.sol                (imports ReserveMath)
4. NovaraAaveAdapter.sol            (imports Aave interfaces only)
5. NovaraHook.sol                   (imports all above + BaseHook)
6. NovaraReactive.sol               (standalone, Reactive Network)
```

---

*This file is the navigation map. README.md is the full spec.*
*When in doubt, README.md wins.*