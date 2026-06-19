# Novara Protocol

> **Zero dead capital. Zero unprotected exposure.**

Novara is a self-sustaining LP capital management hook for Uniswap v4. It eliminates two simultaneous failures of concentrated liquidity — idle capital and unprotected active capital — through a single unified economic loop.

When a position is out of range, Novara automatically deploys the idle liquidity to Aave to earn yield. That yield flows into an on-chain reserve, which pays out LPs for impermanent loss when they exit an active position. No external insurer, no token incentives, no emissions — the system funds its own protection.

Built with Uniswap v4 Hooks, Aave v3, Chainlink, and Reactive Network for the UHI9 Hookathon (*Impermanent Loss & Yield Systems*).

---

## Table of Contents

1. [The Problem](#the-problem)
2. [The Insight](#the-insight)
3. [What Novara Does](#what-novara-does)
4. [The Economic Loop](#the-economic-loop)
5. [State Machine](#state-machine)
6. [Architecture Overview](#architecture-overview)
7. [Contract Specifications](#contract-specifications)
8. [Hook Callbacks](#hook-callbacks)
9. [Economic Model](#economic-model)
10. [Integrations](#integrations)
11. [MVP vs Future Work](#mvp-vs-future-work)
12. [Security Assumptions](#security-assumptions)
13. [Test Coverage Plan](#test-coverage-plan)
14. [Demo Flow](#demo-flow)

---

## The Problem

Concentrated liquidity on Uniswap v4 creates two simultaneous failures for every LP:

### Problem 1 — Active Capital Is Unprotected

When liquidity is **in-range**:
- LP earns swap fees ✓
- LP suffers impermanent loss during volatility ✗
- No on-chain protection mechanism exists natively
- Even profitable pools become net-negative during large price movements

### Problem 2 — Idle Capital Is Dead

When liquidity is **out-of-range**:
- LP earns zero swap fees
- Capital sits completely idle
- Full opportunity cost with no compensation
- Across Uniswap v4, **60–80% of concentrated liquidity is out-of-range at any given time**

These two problems are always present simultaneously. Existing hooks solve one or the other. Nobody has solved both.

---

## The Insight

> **The yield from idle capital can fund protection for active capital.**

This is the core breakthrough. Most systems treat yield generation and IL protection as separate problems requiring separate protocols, separate tokens, or external capital.

Novara unifies them into a single self-sustaining loop:

```
Idle capital → deployed to Aave/Morpho → earns lending yield
                                              ↓
                                    yield flows into reserve
                                              ↓
                              reserve compensates LPs for IL on exit
```

The insurance pool funds itself from the same capital it is protecting.  
No emissions. No external insurers. No token incentives. No external trust assumptions.

---

## What Novara Does

Novara is an adaptive LP capital management hook that dynamically manages LP capital across two states:

| LP State | Novara Behavior |
|----------|----------------|
| **In-range** | LP earns swap fees + receives IL protection from reserve |
| **Out-of-range** | Idle tokens automatically deployed to Aave/Morpho, yield funds reserve |

When price returns to range:
- Chainlink Automation detects re-entry condition
- Reactive Network fires redeployment callback
- Liquidity is restored into Uniswap before the next swap hits the range

**The LP experience:**
1. Deposit liquidity with a protection profile
2. Walk away
3. Idle capital earns yield automatically
4. Active capital is covered against IL
5. Exit with compensation if IL occurred

---

## The Economic Loop

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   LP deposits liquidity into Uniswap v4 pool                   │
│                          │                                      │
│              ┌───────────▼───────────┐                         │
│              │   Is liquidity        │                         │
│              │   in range?           │                         │
│              └───────────┬───────────┘                         │
│                    │           │                                │
│                   YES          NO                               │
│                    │           │                                │
│     ┌──────────────▼──┐   ┌───▼──────────────────┐            │
│     │ Active LP       │   │ Idle LP               │            │
│     │                 │   │                       │            │
│     │ • Earns fees    │   │ • Tokens sent to Aave │            │
│     │ • IL tracked    │   │ • Earns lending yield │            │
│     │ • Covered by    │   │ • Yield → reserve     │            │
│     │   reserve       │   │                       │            │
│     └──────────────┬──┘   └───────────┬───────────┘            │
│                    │                  │                         │
│                    │    ┌─────────────▼──────────┐             │
│                    │    │   Insurance Reserve    │             │
│                    │    │                        │             │
│                    │    │  • Grows with yield    │             │
│                    │    │  • Coverage ratio      │             │
│                    │    │    scales with depth   │             │
│                    └────►  • Pays IL on exit     │             │
│                         └────────────────────────┘             │
│                                                                 │
│          Price returns → Chainlink + Reactive detects          │
│          → Liquidity redeployed into Uniswap automatically     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Reflexive Sustainability

Higher volatility creates a self-reinforcing protection mechanism:

```
Higher Volatility
      ↓
Price leaves range more often
      ↓
More capital deployed to Aave
      ↓
More lending yield earned
      ↓
Larger insurance reserve
      ↓
Stronger IL protection
      ↓
More LPs willing to provide liquidity
      ↓
Deeper pools → More swap fees → Repeat
```

The system is more protected precisely when protection is most needed.

---

## State Machine

Each LP position exists in one of four states:

```
                    ┌─────────────┐
                    │   CREATED   │
                    │             │
                    │ Entry price │
                    │ snapshotted │
                    └──────┬──────┘
                           │ afterAddLiquidity
                           ▼
                    ┌─────────────┐
          ┌────────►│   ACTIVE    │◄────────────────┐
          │         │             │                 │
          │         │ In-range    │                 │
          │         │ Earning     │                 │
price     │         │ fees        │                 │ price re-enters
re-enters │         │ IL tracked  │                 │ range
range     │         └──────┬──────┘                 │
          │                │ price leaves range      │
          │                ▼ (beforeSwap detects)    │
          │         ┌─────────────┐                 │
          │         │    IDLE     │─────────────────┘
          │         │             │
          └─────────│ Out-of-range│
                    │ Tokens in   │
                    │ Aave/Morpho │
                    │ Yield →     │
                    │ reserve     │
                    └──────┬──────┘
                           │ LP calls removeLiquidity
                           ▼
                    ┌─────────────┐
                    │   EXITED    │
                    │             │
                    │ IL computed │
                    │ Payout if   │
                    │ IL > 0      │
                    └─────────────┘
```

### State Transitions

| From | To | Trigger | Handler |
|------|----|---------|---------|
| CREATED | ACTIVE | `afterAddLiquidity` fires | `NovaraHook.afterAddLiquidity` |
| ACTIVE | IDLE | Price tick crosses LP boundary | `NovaraHook.afterSwap` |
| IDLE | ACTIVE | Price re-enters range | `NovaraHook.afterSwap` + Reactive callback |
| ACTIVE | EXITED | LP calls `removeLiquidity` | `NovaraHook.beforeRemoveLiquidity` |
| IDLE | EXITED | LP calls `removeLiquidity` | `NovaraHook.beforeRemoveLiquidity` (recall from Aave first) |

---

## Architecture Overview

```
  Uniswap v4 (Sepolia)              Reactive Network (Lasna/Kopli)
  ┌──────────────────────┐          ┌──────────────────────────────┐
  │  NovaraHook          │          │  NovaraReactive              │
  │                      │  events  │                              │
  │  • Hook callbacks    │─────────►│  • Subscribes to:            │
  │  • Position tracking │          │    - PositionCreated         │
  │  • State management  │          │    - PriceExitedRange        │
  │  • Aave integration  │◄─────────│    - PriceEnteredRange       │
  │  • Reserve tracking  │ callback │                              │
  │  • IL computation    │          │  • Computes:                 │
  │  • Payout logic      │          │    - Range re-entry          │
  └──────────────────────┘          │    - Redeployment timing     │
           │                        │    - Reserve health          │
           │                        └──────────────────────────────┘
           │
           ▼
  ┌──────────────────────┐          ┌──────────────────────────────┐
  │  Aave v3 / Morpho    │          │  Chainlink                   │
  │                      │          │                              │
  │  • Receives idle     │          │  • Price feeds for           │
  │    LP tokens         │          │    re-entry detection        │
  │  • Returns aTokens   │          │  • Automation for            │
  │  • Yield accrues     │          │    redeployment trigger      │
  └──────────────────────┘          └──────────────────────────────┘
```

---

## Contract Specifications

### 1. `NovaraHook.sol`

The primary Uniswap v4 hook contract. Inherits `BaseHook`.

**Storage:**

```solidity
// LP position metadata
struct Position {
    address owner;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint160 entryPrice;       // sqrtPriceX96 at deposit
    uint256 entryTimestamp;
    PositionState state;      // ACTIVE | IDLE | EXITED
    uint256 aaveDepositAmount; // tokens deposited into Aave
    address aToken;           // aToken received from Aave
}

// Reserve state
struct Reserve {
    uint256 totalAssets;      // total reserve balance (in quote token)
    uint256 totalLiabilities; // total IL exposure across all active positions
    uint256 coverageRatio;    // totalAssets / totalLiabilities (18 decimals)
}

// Volatility state (for adaptive premium)
struct VolatilityState {
    uint256 tickCrossingsLast100Swaps;
    uint256 avgSwapSize;
    uint256 lastUpdateBlock;
    uint256 rollingVolatility; // BPS, used for premium scaling
}

mapping(bytes32 => Position) public positions;     // positionId → Position
mapping(PoolId => Reserve) public reserves;        // poolId → Reserve
mapping(PoolId => VolatilityState) public volState; // poolId → VolatilityState
mapping(PoolId => uint256[]) public priceHistory;  // poolId → rolling price window
```

**Key functions:**

```solidity
// Called by LP to deposit with Novara protection
function depositWithProtection(
    PoolKey calldata key,
    IPoolManager.ModifyLiquidityParams calldata params,
    ProtectionProfile calldata profile
) external returns (bytes32 positionId);

// Hook callbacks (see Hook Callbacks section)
function afterAddLiquidity(...) external override returns (bytes4, BalanceDelta);
function beforeSwap(...) external override returns (bytes4, BeforeSwapDelta, uint24);
function afterSwap(...) external override returns (bytes4, int128);
function beforeRemoveLiquidity(...) external override returns (bytes4);
function afterRemoveLiquidity(...) external override returns (bytes4, BalanceDelta);

// Called by Reactive Network callback
function redeployFromAave(bytes32 positionId) external onlyReactiveCallback;

// Called by Chainlink Automation
function checkUpkeep(bytes calldata) external view returns (bool, bytes memory);
function performUpkeep(bytes calldata) external;

// View functions
function getPosition(bytes32 positionId) external view returns (Position memory);
function getReserve(PoolId poolId) external view returns (Reserve memory);
function getCoverageRatio(PoolId poolId) external view returns (uint256);
function estimatedPayout(bytes32 positionId) external view returns (uint256);
```

**ProtectionProfile struct:**

```solidity
struct ProtectionProfile {
    uint256 minCoverageExpected; // BPS — LP's minimum acceptable coverage (informational)
    bool autoRedeploy;           // true = auto redeploy when price returns
    bool autoExit;               // true = auto exit if coverage ratio falls below threshold
    uint256 exitCoverageThreshold; // BPS — exit if coverage drops below this
}
```

---

### 2. `NovaraReserve.sol`

Standalone reserve accounting contract. Separated from the hook for upgradeability and auditability.

```solidity
// Core reserve operations
function deposit(PoolId poolId, uint256 amount) external onlyHook;
function withdraw(PoolId poolId, uint256 amount) external onlyHook;
function recordLiability(PoolId poolId, bytes32 positionId, uint256 ilExposure) external onlyHook;
function clearLiability(PoolId poolId, bytes32 positionId) external onlyHook;

// Coverage
function getCoverageRatio(PoolId poolId) external view returns (uint256);
function getMaxPayout(PoolId poolId, uint256 ilAmount) external view returns (uint256);
```

---

### 3. `NovaraAaveAdapter.sol`

Thin adapter between NovaraHook and Aave v3 / Morpho. Abstracts lending protocol selection.

```solidity
function deposit(address token, uint256 amount) external onlyHook returns (uint256 aTokenAmount);
function withdraw(address token, uint256 aTokenAmount) external onlyHook returns (uint256 tokenAmount);
function getYieldAccrued(address token, uint256 originalAmount) external view returns (uint256);
function currentAPY(address token) external view returns (uint256); // BPS
```

---

### 4. `NovaraReactive.sol`

Reactive Smart Contract deployed on Reactive Network (Lasna/Kopli testnet).

```solidity
// Subscribes to:
// - NovaraHook: PositionCreated(positionId, poolId, owner, tickLower, tickUpper)
// - NovaraHook: PriceExitedRange(positionId, poolId, currentTick)
// - NovaraHook: PriceEnteredRange(positionId, poolId, currentTick)
// - Cron: periodic reserve health checks

function react(LogRecord calldata log) external override;

// Internal decision logic
function _handlePositionCreated(bytes calldata data) internal;
function _handlePriceExited(bytes calldata data) internal;
function _handlePriceReturned(bytes calldata data) internal;
function _triggerRedeploy(bytes32 positionId) internal;
```

---

## Hook Callbacks

### `afterAddLiquidity`

**When:** LP adds liquidity to a Novara-protected pool.

**Actions:**
1. Snapshot `sqrtPriceX96` as `entryPrice`
2. Record position metadata in `positions` mapping
3. Determine if position is immediately in-range or out-of-range
4. If out-of-range immediately: flag for Aave deployment
5. Emit `PositionCreated` event for Reactive Network subscription
6. Update `totalLiabilities` in reserve (estimated max IL exposure)

**Gas considerations:** Minimal state writes. Aave deposit happens asynchronously via Reactive callback, not in this hook.

---

### `beforeSwap`

**When:** Any swap occurs in a Novara pool.

**Actions:**
1. Read current tick from pool state
2. For each position that crosses a boundary on this swap:
   - If ACTIVE position goes out-of-range: mark as `IDLE`, emit `PriceExitedRange`
   - If IDLE position re-enters range: emit `PriceEnteredRange` (redeployment handled by Reactive/Chainlink)
3. Update `VolatilityState`:
   - Increment tick crossing counter
   - Record swap size
   - Recompute rolling volatility estimate
4. Update `priceHistory` circular buffer (used for volatility)

**Note:** Does NOT perform Aave deposits/withdrawals inline (too expensive). These are triggered asynchronously.

---

### `afterSwap`

**When:** After any swap completes.

**Actions:**
1. Update price snapshot in `priceHistory`
2. Route a portion of swap fees to reserve:
   - `premiumAmount = swapFee × premiumRate(volatility)`
   - `premiumRate` scales from 0.5% (low vol) to 2% (high vol)
3. Call `NovaraReserve.deposit(poolId, premiumAmount)`
4. Emit `ReserveUpdated` event

---

### `beforeRemoveLiquidity`

**When:** LP calls `removeLiquidity`.

**Actions:**
1. Look up position by `(owner, tickLower, tickUpper)`
2. If position is `IDLE`: recall tokens from Aave via `NovaraAaveAdapter.withdraw`
3. Compute IL:
   ```
   exitPrice = current sqrtPriceX96
   IL = computeIL(entryPrice, exitPrice, tickLower, tickUpper, liquidity)
   ```
4. If `IL > 0`:
   - Compute `maxPayout = reserve.getMaxPayout(poolId, IL)`
   - Schedule payout (transferred in `afterRemoveLiquidity`)
5. Clear position liability from reserve
6. Mark position as `EXITED`

---

### `afterRemoveLiquidity`

**When:** After LP liquidity is removed.

**Actions:**
1. Transfer scheduled IL payout to LP from reserve
2. Emit `ILCompensated(positionId, ilAmount, payoutAmount, coverageRatio)`
3. Update reserve totals

---

## Economic Model

### Premium Collection

Every swap contributes a small premium to the reserve:

```
premiumRate = basePremium × volatilityMultiplier

basePremium = 0.5% of swap fee
volatilityMultiplier = 1.0 + (rollingVolatility / maxVolatility) × 1.5
                     → range: 1.0x (low vol) to 2.5x (high vol)

premiumAmount = swapFeeAmount × premiumRate
```

Volatility is measured endogenously from:
- Tick crossing frequency (last 100 swaps)
- Average swap size relative to pool reserves
- Rolling price variance from `priceHistory`

No external volatility oracle required.

---

### Aave Yield Routing

When a position goes idle:

```
idleTokens → NovaraAaveAdapter.deposit()
           → aTokens held by hook
           → yield accrues automatically

yieldAccrued = aTokenBalance - originalDeposit
             → routed to reserve on redeploy or exit
```

APY contribution to reserve depends on:
- Time out of range
- Aave current supply rate for that token
- Size of idle position

---

### IL Computation

Standard concentrated liquidity IL formula:

```solidity
function computeIL(
    uint160 entryPrice,    // sqrtPriceX96 at deposit
    uint160 exitPrice,     // sqrtPriceX96 at withdrawal
    int24 tickLower,
    int24 tickUpper,
    uint128 liquidity
) internal pure returns (uint256 ilAmount) {
    // Value at entry
    uint256 valueAtEntry = _positionValue(entryPrice, tickLower, tickUpper, liquidity);
    // Value at exit (actual)
    uint256 valueAtExit = _positionValue(exitPrice, tickLower, tickUpper, liquidity);
    // HODL value (what LP would have if they just held tokens)
    uint256 hodlValue = _hodlValue(entryPrice, exitPrice, tickLower, tickUpper, liquidity);
    // IL = HODL value - actual LP value (if positive, LP underperformed)
    ilAmount = hodlValue > valueAtExit ? hodlValue - valueAtExit : 0;
}
```

---

### Coverage Ratio

```
coverageRatio = reserveAssets / totalLiabilities

Payout = min(ILAmount, ILAmount × coverageRatio)
```

Coverage starts low when the pool is new and grows over time as:
1. Premiums accumulate from swap fees
2. Aave yield flows into reserve
3. Existing IL claims reduce liabilities over time

This is a **feature, not a limitation.** LPs see a real coverage ratio (e.g. 23% on day 1, 71% on day 30). This sets honest expectations and grows into a mature protection system.

---

## Integrations

### Aave v3

- **Why:** Most liquid lending protocol on Sepolia testnet. Reliable supply rates.
- **What:** Idle LP tokens deposited via `IPool.supply()`, withdrawn via `IPool.withdraw()`
- **Tokens:** USDC, WETH (primary pairs for demo)
- **aTokens:** Held by `NovaraHook`, redeemed on position exit or range re-entry
- **Fallback:** If Aave supply rate < threshold (e.g. 0.5% APY), hold tokens in hook rather than deposit

### Chainlink

- **Price Feeds:** `AggregatorV3Interface` for ETH/USD — used to validate range re-entry detection
- **Automation:** `AutomationCompatibleInterface` — `checkUpkeep` scans idle positions for range re-entry, `performUpkeep` triggers `redeployFromAave`
- **Why Chainlink:** Re-entry detection needs to happen between swaps. Chainlink Automation runs on a schedule independently of swap activity.

### Reactive Network

- **Why:** Coordinates asynchronous events across blocks. When price exits range (event on Sepolia), Reactive contract detects it and fires callback to deploy to Aave. When price returns (Chainlink confirms), Reactive fires redeployment callback.
- **RSC:** `NovaraReactive.sol` deployed on Lasna testnet
- **Subscriptions:**
  - `PositionCreated` → activate monitoring
  - `PriceExitedRange` → trigger Aave deposit callback
  - `PriceEnteredRange` → trigger Aave withdrawal + redeployment callback
  - Cron (every ~12 min) → reserve health check
- **Why not just keepers:** Keepers can trigger but cannot coordinate multi-step logic. Reactive contracts can receive events, make decisions, and send targeted callbacks — the brain of the async pipeline.

---


### Post-Hackathon / Grant Work

**V2 Features:**
- Multi-lending-protocol support (Morpho, Compound)
- Portfolio-level coverage (aggregate IL across multiple positions)
- LP coverage NFTs (tokenized insurance positions, tradeable)
- Cross-pool reserve sharing (deep stablecoin pools subsidize volatile pair pools)

**V3 Vision:**
- Novara as LP treasury infrastructure — any protocol can plug in
- Cross-chain idle capital deployment via Across Protocol
- Governance over premium rates and coverage parameters
- Novara DAO — reserve governed by long-term LPs

---

## Security Assumptions

### What Novara Trusts

| Dependency | Trust Assumption | Risk |
|------------|-----------------|------|
| Uniswap v4 PoolManager | Correct tick and price reporting | Low — audited core |
| Aave v3 | Supply/withdraw functions behave correctly | Low — battle-tested |
| Chainlink Price Feeds | Prices are accurate within 1 block | Medium — oracle risk |
| Chainlink Automation | Upkeep fires within reasonable time | Medium — liveness risk |
| Reactive Network | Callbacks delivered correctly | Medium — new infrastructure |

### What Novara Does NOT Assume

- **Reserve solvency guarantee:** Coverage ratio can fall below 100%. This is explicit and communicated to LPs. The system never promises full coverage.
- **Instant redeployment:** Between price re-entering range and redeployment completing, there may be 1-3 blocks where the LP misses fees. This is acceptable and disclosed.
- **Aave liquidity:** If Aave has insufficient liquidity for withdrawal, the hook falls back to holding tokens internally.

### Known Risks

1. **Aave liquidity crunch:** If Aave utilization is near 100%, withdrawal may fail or be partial. Mitigation: check utilization before deposit; set max deposit threshold.

2. **Reactive Network liveness:** If the RSC fails to deliver a callback, idle tokens remain in Aave longer than intended. Mitigation: Chainlink Automation as fallback for redeployment.

3. **Reserve drain attack:** Malicious LP could attempt to drain reserve via repeated small IL claims. Mitigation: minimum position size, cooldown period between claims, coverage ratio floor.

4. **Price manipulation:** Flash loan attacks to push price out of range, trigger Aave deposit, then return price. Mitigation: minimum blocks-out-of-range before Aave deposit fires (e.g. 5 blocks).

5. **Tick boundary precision:** Out-of-range detection uses tick comparisons. Off-by-one errors could cause missed transitions. Mitigation: thorough boundary tests at `tickLower - 1`, `tickLower`, `tickUpper`, `tickUpper + 1`.

---

## Test Coverage Plan

| Test File | What It Tests |
|-----------|--------------|
| `NovaraHook.t.sol` | Hook callback firing, state transitions |
| `NovaraReserve.t.sol` | Reserve accounting, coverage ratio math |
| `NovaraAaveAdapter.t.sol` | Aave deposit/withdraw, yield accrual |
| `ILComputation.t.sol` | IL formula correctness across price scenarios |
| `PremiumModel.t.sol` | Premium rate scaling with volatility |
| `FullLifecycle.t.sol` | End-to-end: deposit → idle → yield → re-enter → exit → payout |
| `EdgeCases.t.sol` | Tick boundaries, zero liquidity, coverage below 100%, Aave failure |
| `SecurityTests.t.sol` | Reserve drain attempt, flash loan manipulation, reentrancy |

<!-- **Target: 25+ tests, all passing before submission.** -->

---

## Demo Flow

The demo tells a complete story in 90 seconds:

**Step 1 — LP Deposits**
> ETH/USDC position created. Entry price snapshotted. Dashboard shows: Active, Coverage 18%, Target APY 4.2%.

**Step 2 — Price Leaves Range**
> Swap pushes price below LP's range. Hook detects tick crossing. Reactive Network fires. Idle USDC deposited into Aave.
> Dashboard updates: *State: Idle. Aave APY: 4.1%. Reserve growing.*

**Step 3 — Yield Flows to Reserve**
> Time passes (compressed in demo). Reserve balance increases. Coverage ratio climbs from 18% → 34%.
> Dashboard: *Reserve +$12.40. Coverage 34%.*

**Step 4 — Price Returns**
> Chainlink detects re-entry. Automation fires `performUpkeep`. Reactive callback triggers `redeployFromAave`. Liquidity back in Uniswap before next swap.
> Dashboard: *State: Active. Redeployed successfully.*

**Step 5 — LP Exits With IL**
> LP calls `removeLiquidity`. Hook computes IL: $47.20. Reserve pays out $16.05 (34% coverage).
> Dashboard: *IL Reduced by 34%. $16.05 compensation paid.*

**Headline:**
> *Without Novara: LP lost $47.20. With Novara: LP lost $31.15. Dead capital earned yield. Active capital was protected. One hook.*

---


### Build & Test

```bash
forge install
forge build
forge test --fork-url $SEPOLIA_RPC_URL -vvv
forge script script/DeployNovara.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
```

---

## Summary

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│   NOVARA PROTOCOL                                                │
│   Zero dead capital. Zero unprotected exposure.                  │
│                                                                  │
│   The problem:                                                   │
│   60–80% of LP capital sits idle and unprotected simultaneously  │
│                                                                  │
│   The insight:                                                   │
│   Idle capital yield can fund active capital protection          │
│                                                                  │
│   The mechanism:                                                 │
│   Idle → Aave → Yield → Reserve → IL Compensation               │
│                                                                  │
│   The result:                                                    │
│   A self-sustaining LP protection system requiring no            │
│   external capital, emissions, or token incentives               │
│                                                                  │
│   Stack:                                                         │
│   Uniswap v4 hooks + Aave v3 + Chainlink + Reactive Network      │
│                                                                  │
│   Status: Building                                                │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

*Built for UHI9 Hookathon — Theme: Impermanent Loss & Yield Systems*  
*Powered by Uniswap V4 · Aave v3 · Chainlink · Reactive Network*