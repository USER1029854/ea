# Security audit — StakingRewardsWCC + wCC + Canton BridgeController (EA Finance, BSC)

**Targets audited**
- `StakingRewardsWCC` — `0x23EbC3770f98c01EDAB20eb1eF17Ee633c19b467` (headline target)
- `wCC` (Wrapped Canton Coin) — `0x6050D829F5a5E0eA758D8357DDcdeC1381699248` (the staked/reward asset)
- `BridgeController` — `0xd9e7c01fe4cd0c852b00fb51ffe2ffddfd93f945` (unverified; holds `MINTER_ROLE`/`BURNER_ROLE` over wCC — resolved and decompiled during this audit)

**Chain:** BNB Smart Chain (56). **Captured at** BSC block ~116,134,546.
**Scope:** protocol execution, asset movement, accounting, pricing, permissions, integrations, and any sibling contract holding authority over the target.

---

## Verdict

**Zero qualifying findings** — no economic exploit and no access/authority exploit that an unprivileged, attacker-reachable path can trigger.

Every path that moves value is one of:
1. **User-self-scoped** — it only touches the caller's own balance (`deposit`, `withdraw`, `claimRewards`, `emergencyWithdraw`, `requestBurn`), or
2. **Key-gated** — it requires the owner EOA or the relayer EOA private key (`withdrawFees`, `withdrawRemainingRewards`, `setRewardToken`, `executeMint`, `confirmBurn`, `rollbackBurn`, `pause`, role grants).

There is **no missing access check on a fund-mover, no self-grantable privilege, and no forgeable/replayable/hardcoded credential**. The only external calls in the entire authority graph that mint or move value are role-checked on-chain; none is gated by a signature over a hardcoded/derivable key (there is no `ecrecover` anywhere in any of the three contracts).

The material risks that do exist are **centralization / operational-key trust** (single-EOA admin over three contracts; a relayer hot-wallet that can mint; off-chain Canton collateral). Under the audit's own rules these are the excluded "admin error / privileged-party-misact" class and are documented below as trust assumptions, not findings.

This audit also **closes gap #1 of the prior mapping** (`reports/.../README.md`): the holder of `MINTER_ROLE`/`BURNER_ROLE` on wCC is the `BridgeController` at `0xd9e7c01f…`, and its two direct callers are the owner EOA (`DEFAULT_ADMIN`) and a relayer EOA (`RELAYER_ROLE`, `0xbbddb7…31b2`).

---

## 1. System model

**What the protocol is.** A single-sided staking pool. Users deposit wCC; the pool accrues a fixed WCC emission (`rewardPerPeriod` per `rewardPeriod`) and distributes it pro-rata via the standard MasterChef `accRewardPerShare`/`rewardDebt` accounting. The staking token and the reward token are the **same** asset (wCC), so the pool's balance simultaneously backs three liabilities: user principal (`totalStaked`), collected deposit fees (`totalFeesCollected`), and the un-claimed reward budget (the surplus the owner tops up).

**wCC** is a LayerZero V2 OFT combined with OpenZeppelin `AccessControl` + `Pausable`. It has two supply paths: (a) OFT `send()` cross-chain (burn-here/mint-there, peer-gated; only Base is peered) and (b) a Canton bridge `mint`/`burn` gated by `MINTER_ROLE`/`BURNER_ROLE`. wCC value rests on the off-chain claim that each unit is backed 1:1 by CC locked on the Canton ledger.

**BridgeController** is the sole holder of `MINTER_ROLE`/`BURNER_ROLE`. It implements the Canton mint/burn workflow: `requestMint` (permissionless event only) → `executeMint` (relayer mints after Canton lock); `requestBurn` (user burns their own wCC) → `confirmBurn` (relayer finalizes) / `rollbackBurn` (admin refunds by re-minting).

**Accounting identity that must hold (staking pool):**
`wccToken.balanceOf(pool) == totalStaked + totalFeesCollected + rewardSurplus`, with `rewardSurplus ≥ 0`.
Live: `2,589,400.91 == 2,572,511.97 + 9,847.84 + 7,041.10` ✓ (solvent).

**Where ultimate authority rests.** One plain EOA `0x0a06…26b5b` is: `owner()` of the pool, `owner()`+`DEFAULT_ADMIN_ROLE`+`PAUSER_ROLE` of wCC, and `DEFAULT_ADMIN_ROLE`+`PAUSER_ROLE` of the bridge. A second EOA `0xbbddb7…31b2` holds `RELAYER_ROLE` (mint trigger). No multisig, no timelock.

---

## 2. Invariants derived (and their status)

| # | Invariant | Status |
|---|---|---|
| I1 | Pool solvency: `balance ≥ totalStaked + totalFeesCollected` | Holds; only breaks if reward claims exceed owner-funded surplus (owner-funding risk, profit-proportional). |
| I2 | A user can never withdraw more principal than they deposited (net of fee) | Holds — `withdraw`/`emergencyWithdraw` bounded by `user.amount`. |
| I3 | Reward paid ≤ fair pro-rata share of emission | Holds — monotone `accRewardPerShare`, `rewardDebt` re-synced on every balance change. |
| I4 | No non-owner can move the pool's tokens | Holds — pool never `approve()`s anyone; `allowance(pool→*) = 0`; wCC cannot be burned `from` the pool without its allowance. |
| I5 | wCC can be minted only through a role-checked path | Holds — only `BridgeController` has `MINTER_ROLE`; its `executeMint` checks `RELAYER_ROLE`. |
| I6 | Bridge mint is replay-safe per Canton order | Holds — `processedOrders[orderId]` set before the external mint (CEI), reverts `OrderAlreadyProcessed`. |
| I7 | A user can only burn their **own** wCC via the bridge | Holds — `requestBurn` hardcodes `from = msg.sender`; wCC `burn` also consumes `allowance(from, bridge)`. |
| I8 | No privilege is self-grantable | Holds — role admin is `DEFAULT_ADMIN_ROLE`; no `_setRoleAdmin` exposure; no missing check. |
| I9 | No value path gated by a hardcoded/derivable secret | Holds — no signature verification anywhere; mint gate is an on-chain role, not an `ecrecover`. |

No reachable state was found that breaks I2–I9 for an unprivileged actor. I1's only failure mode is owner under-funding, which yields no disproportionate attacker profit.

---

## 3. Triage — where the money and control are

- **Custody:** the pool holds ~2.59M WCC (~$255K). It is the only contract holding meaningful value; the bridge holds 0.
- **Control:** the ability to mint wCC (unbounded) is the highest-leverage authority. It lives in the bridge (`MINTER_ROLE`) and, one hop up, in whoever holds `DEFAULT_ADMIN_ROLE` on wCC (can grant `MINTER_ROLE` to anyone). Depth was concentrated on (a) the pool's deposit/withdraw/claim accounting and (b) the bridge's mint/burn guards.

---

## 4. Candidate analysis (adversarial, then falsified)

### 4.1 Staking pool — reward/accounting manipulation → **not exploitable**
Rewards are a fixed per-period emission split by stake share; a staker's payout is strictly `stake/totalStaked` of the emission. Increasing one's payout requires more stake (proportional capital) or a smaller `totalStaked` (requires other users to leave — excluded). Emission is **time-based**: `periodsElapsed = timeDiff / rewardPeriod` with `rewardPeriod = 14400 s`, so any reward requires holding stake across a ≥4-hour boundary — **flash loans cannot reach it atomically**. `updateRewards()` is called before every balance change; `rewardDebt` is re-synced on every deposit/withdraw/claim; `accRewardPerShare` is monotone, so `pending = amount·acc/P − rewardDebt` cannot underflow or double-count. Falsified: no disproportionate, capital-independent gain exists.

### 4.2 Same-token staking + `withdrawRemainingRewards` → **owner-only, not attacker-reachable**
`withdrawRemainingRewards()` pulls `balanceOf(this) − (totalStaked + totalFeesCollected)`; it is correct only while `rewardToken == wccToken`, which `setRewardToken()` can change with no event. Both functions are `onlyOwner` (and `whenPaused`), so this is an owner rug lever, not a path an external attacker can trigger. Documented as trust risk §6.

### 4.3 Token-behavior assumptions (fee-on-transfer / rebasing / reentrant / returns-false) → **none apply**
The staked asset is wCC, whose `_update` only enforces `whenNotPaused` and otherwise defers to stock OZ `ERC20` — no transfer fee, no rebase, no transfer hook/callback. `SafeERC20` handles non-standard returns. All state-mutating pool functions are `nonReentrant`, and wCC has no reentrancy surface. Re-running the value trace under hostile-but-compliant token behavior yields no break.

### 4.4 Bridge `executeMint` — unauthorized/replayed mint → **guarded**
Decompiled path: `_checkRole(RELAYER_ROLE)` → `whenNotPaused` → `nonReentrant` → validate `to≠0, amount>0, orderId≠""` → `require(!processedOrders[orderId])` (revert `OrderAlreadyProcessed`) → set `processedOrders[orderId]=true` → `wcc.mint(to,amount,orderId)`. Role check dominates; replay flag set before the external call. An arbitrary caller reverts at the role check. Not reachable.

### 4.5 Bridge `requestMint` — permissionless mint? → **no value**
Permissionless, but the impl only validates inputs and emits `MintRequested`; **no SSTORE, no external call, no mint**. It is a signal a relayer observes off-chain; minting still requires `executeMint` (relayer). No value moves.

### 4.6 Bridge `requestBurn` — burn someone else's tokens? → **own tokens only**
Permissionless, but calls `wcc.burn(from = msg.sender, …)` (the `from` operand is `CALLER`, pc 1471), and wCC `burn` additionally consumes `allowance(from, bridge)`. A caller can only destroy their own approved balance; a duplicate-order guard (`OrderAlreadyProcessed`) prevents reusing an `orderId`. No ability to burn the pool's or a third party's balance.

### 4.7 Bridge `rollbackBurn` / `confirmBurn` — unguarded refund/finalize? → **key-gated**
`rollbackBurn` is `onlyRole(DEFAULT_ADMIN_ROLE)` (checks role `0x00`) and re-mints as a refund; `confirmBurn` is `onlyRole(RELAYER_ROLE)`. Both require a privileged key; neither is attacker-reachable. Each has an idempotency flag preventing double-refund/double-finalize.

### 4.8 Privilege escalation on wCC/bridge → **none**
Roles use stock OZ `AccessControl`; every role's admin is `DEFAULT_ADMIN_ROLE`; no `_setRoleAdmin` is exposed and no fund-mover omits its guard. The only holder of `MINTER_ROLE`/`BURNER_ROLE` on wCC is the bridge (confirmed via `RoleGranted` history and live `hasRole`); the owner EOA and relayer EOA do **not** hold them directly. There is no path for a non-admin to obtain any role.

### 4.9 Leaked/hardcoded credential → **absent**
No `ecrecover`, no `STATICCALL`/`DELEGATECALL`, and only three `CALL`s in the bridge — all to the wCC token. wCC and the pool contain no signature logic. There is no signer key, secret, or credential embedded in any deployed bytecode that gates value. The class the brief emphasizes (a key present in deployed code) does not exist here.

---

## 5. Coverage map — candidates considered and dismissed

- Reward share inflation via large deposit → profit proportional to stake; emission is fixed & time-based → out of scope (economic gate).
- Flash-loan reward theft → rewards require holding stake across a 4h period boundary; not atomic → unreachable.
- First-depositor / share-price inflation (ERC4626-style) → pool tracks 1:1 principal, not shares → N/A.
- Reentrancy across claim/withdraw → `nonReentrant` on all; wCC has no callback → mitigated.
- Fee-on-transfer / rebasing accounting drift → wCC is plain OZ ERC20 → N/A.
- Rounding/precision in `accRewardPerShare` (`·1e18/totalStaked`) → dust accretes to protocol, sub-wei per period → no attacker gain.
- `pendingReward`/`claimRewards` underflow → monotone `acc`, re-synced `rewardDebt` → cannot underflow.
- `emergencyWithdraw` skips `updateRewards` → over-credits remaining stakers by a period's dust; caller forfeits rewards → no attacker profit.
- Pool token drain via `transferFrom`/allowance → pool never approves; `allowance(pool→*)=0` → impossible.
- Burn the pool's staked wCC via bridge → `requestBurn` burns `from=CALLER`, needs `from`'s allowance to bridge → impossible.
- `executeMint` replay / unauthorized → role-checked + `processedOrders` guard (CEI) → mitigated.
- `requestMint` open mint → event-only, no value → no impact.
- Privilege self-grant on wCC/bridge → OZ admin model intact, no `_setRoleAdmin` exposure → unreachable.
- Hardcoded signer/secret gating mint → no signature path exists → absent.
- Owner rug via `setRewardToken`+`withdrawRemainingRewards`, unlimited `grantRole(MINTER_ROLE)`, `pause` → all owner-key gated → out of scope (privileged-party misact).
- Relayer hot-wallet mint → requires the relayer private key → operational key risk, not code-reachable.
- LayerZero `send()` draining the pool → burns caller's own balance; peer-gated (only Base) → N/A.

---

## 6. Out-of-scope trust assumptions (not findings — documented for completeness)

These are the real risk surface, but each requires a privileged key or off-chain state, so none is an attacker-reachable vulnerability under the brief.

1. **Single-EOA super-admin.** `0x0a06…26b5b` (plain EOA, no multisig/timelock) is `DEFAULT_ADMIN_ROLE` on wCC and can `grantRole(MINTER_ROLE, itself)` in one tx and mint unlimited wCC — instantly collapsing the backing of every staker's principal. Highest systemic risk; entirely a centralization/key-custody exposure.
2. **Owner reward-surplus lever.** `setRewardToken` (no event) + `pause` + `withdrawRemainingRewards` lets the owner pull the un-claimed reward budget (~7,041 WCC now); with `setRewardToken` re-pointed, the "reserved" bound no longer protects principal. Owner-only.
3. **Relayer hot wallet.** `RELAYER_ROLE` = EOA `0xbbddb7…31b2` (nonce 2522, an automated relayer). Compromise of that key ⇒ unlimited wCC mint via `executeMint` (bounded only by `whenNotPaused` and per-`orderId` uniqueness). Off-chain key security.
4. **Canton collateralization.** The 1:1 CC-backing of minted wCC is unverifiable from any EVM chain; it is a pure trust assumption in the bridge operator.

**Mitigations to consider (operational, not code bugs):** move admin to a timelocked multisig; emit an event and/or add a timelock on `setRewardToken`; segregate the reward budget from principal accounting; cap/monitor bridge mint velocity; publish the Canton attestation.

---

## 7. Assumptions & limitations

- **BridgeController is unverified.** All statements about it are derived from decompiling its runtime bytecode (`eth_getCode`), selector recovery (OpenChain), and control-flow tracing of the dispatcher and each function's guard/CALL. Selectors, role constants (`RELAYER_ROLE`, `PAUSER_ROLE`, `DEFAULT_ADMIN_ROLE`), the `processedOrders` replay guard, and the three `CALL`s to wCC were confirmed directly in the disassembly; I could not cross-check against original source. If the bytecode read were wrong, the conclusions on §4.4–4.7 would change — but the mint/burn CALLs, role pushes, and replay SSTORE are unambiguous in the trace.
- **Historical event coverage** used a single working archival RPC (Nodereal) with 9k-block windows from each contract's deploy block; `RoleGranted` enumeration returned the complete constructor-era grants for both wCC and the bridge. A later grant/revoke outside the scanned windows is not fully excluded, but live `hasRole` reads corroborate the current holder set.
- **Verified sources match deployment.** `StakingRewardsWCC.sol` and `wCC.sol` in this package are byte-identical (modulo CRLF/trailing whitespace) to BscScan's live verified source; all vendored OZ v5.4.0 and LayerZero v2.3.44 dependencies are byte-identical to the pinned upstream npm releases (diffed in this session) — no hidden modification in the dependency tree.
- Off-chain components (Canton ledger, relayer service, LayerZero DVN/executor config) are outside EVM visibility and were not assessed.

---

## 8. Calibration

Severity/confidence are stated only after falsification. No candidate survived its rebuttal as an attacker-reachable issue, so there is nothing to rank. Confidence in the **"no unauthorized fund-mover / no leaked credential"** conclusion is high for the two verified contracts (source == bytecode, deps == upstream) and medium-high for the bridge (decompiled, guards unambiguous but source unavailable). The dominant residual risk is centralization, which is real but explicitly out of the attacker-reachable scope.
