# Contract graph: StakingRewardsWCC (EA Finance)

**Target:** `0x23EbC3770f98c01EDAB20eb1eF17Ee633c19b467`
**Chain:** BNB Smart Chain (chain id 56) — determined on-chain, see [Chain determination](#chain-determination)
**Captured:** 2026-08-15, BSC block 116,120,311
**Package contents:** this document + [`sources/`](./sources) (full verified source, both contracts) + [`data/live_state.json`](./data/live_state.json) (machine-readable live-state snapshot)

This is a mapping, not a verdict. Every "can" below describes what the code and current on-chain state permit, not a claim that it will happen or an exploitability rating — that judgment belongs to the next step.

---

## Chain determination

The `etherscan.io` link supplied with this target does not resolve: the address has **no bytecode, no balance, and nonce 0 on Ethereum mainnet** — that link is dead. DeFiLlama lists a protocol matching this address as **"EA Finance"** (slug `ea-finance`) on **BNB Smart Chain**, and BscScan has the target verified there under the name `StakingRewardsWCC`, matching the discovery notes exactly. All work below is on BSC (chain id 56) unless a section explicitly says otherwise.

A first broad sweep (checking all 32 EVM mainnets Etherscan's unified API covers) produced false-positive "found" results on Base, Optimism, Avalanche and Celo — the sweep script mistook a "chain not supported on free tier" error string for bytecode. This was caught and every chain was re-verified with direct `eth_getCode` calls against public RPCs (see [`data/live_state.json`](./data/live_state.json) `chain_presence_scan`). The corrected result: **the staking pool exists only on BSC.** The WCC token exists on BSC and, separately, on Base — see below.

---

## 1. The target: `StakingRewardsWCC`

Verified source, OpenZeppelin 5.x (`Ownable`, `ReentrancyGuard`, `Pausable`), not a proxy. Full source: [`sources/StakingRewardsWCC.sol`](./sources/StakingRewardsWCC.sol).

It holds two external references, both immutable/near-immutable pointers into the graph below:

| Reference | Value (live) | Mutability |
|---|---|---|
| `wccToken` | `0x6050D829F5a5E0eA758D8357DDcdeC1381699248` | `immutable`, set once at deploy |
| `rewardToken` | `0x6050D829F5a5E0eA758D8357DDcdeC1381699248` (same as `wccToken`, currently) | owner-mutable via `setRewardToken()`, **no event emitted on change** |

### Privileged functions (owner = single plain EOA, no multisig/timelock — confirmed, see [§3](#3-upstream-who-holds-power-over-this))

| Function | Effect |
|---|---|
| `setRewardToken(address)` | Repoints all future `claimRewards()` payouts to any ERC-20. No event. |
| `setDepositFee(bps)` | 0–1000 bps (0–10%) cut taken from every `deposit()`. |
| `setPoolCap` / `setWalletCap` | Currently both 0 (unlimited). |
| `setRewardPerPeriod` / `setRewardPeriod` / `setRewardStartTime` | Reward-emission schedule. |
| `pause()` / `unpause()` | Single-key, instant, no delay. |
| `withdrawFees()` | Sweeps `totalFeesCollected` (WCC) to owner. |
| `withdrawRemainingRewards()` | **Owner-only, gated by `whenPaused`** (same owner controls the pause). Pulls `rewardToken.balanceOf(this)` minus `(totalStaked + totalFeesCollected)` to the owner. |

`withdrawRemainingRewards()` is bounded correctly **only as long as `rewardToken == wccToken`** — that equality is exactly the fact that can be changed by the same key, silently, via `setRewardToken`. Since staked principal and rewards share one token by design, the safety of user principal against this function rests entirely on that one address staying pinned to `wccToken`, which is an owner-reversible choice, not a contract invariant.

### Code intent vs. live reality

The constructor and current chain state disagree on one parameter — exactly the kind of drift this mapping is meant to catch:

| Parameter | At deploy (decoded from constructor args) | Live now |
|---|---|---|
| `rewardPerPeriod` | 100 WCC / 4h | **33 WCC / 4h** — lowered via `setRewardPerPeriod` at some point |
| `rewardToken` | = `wccToken` | = `wccToken` (unchanged) |
| `depositFeeBps` | 30 (0.3%) | 30 (unchanged) |
| `paused` | false | false (live) |

`lastRewardUpdateTime` is 2026‑08‑14T18:34:50Z — about a day before capture, so the pool is actively used, not dormant.

### Solvency snapshot (right now)

- WCC actually held by the contract: **2,589,400.91**
- Owed back to users + fees (`totalStaked` + `totalFeesCollected`): **2,582,359.81**
- **Excess sitting in the contract that `pause()` + `withdrawRemainingRewards()` could pull to the owner at this exact moment: 7,041.10 WCC (~$694)**

This number moves constantly (it's whatever reward funding hasn't been claimed yet), but the mechanism is live and non-trivial funds are exposed to it right now, with no warning period.

The contract never calls `approve()` on any token, so it cannot be drained through a third-party allowance/`transferFrom` path — the only withdrawal paths out of it are the functions in the table above and users' own `withdraw()`/`claimRewards()`/`emergencyWithdraw()`.

---

## 2. Downstream: everything the target leans on

### 2.1 `wCC` — Wrapped Canton Coin (the real center of gravity)

`0x6050D829F5a5E0eA758D8357DDcdeC1381699248` — verified on BSC, not a proxy. Full source: [`sources/wCC.sol`](./sources/wCC.sol) (Hardhat-flattened; the project-specific contract is at the bottom, ~line 3779).

This is **not a plain ERC-20**. It's a LayerZero V2 **OFT** (Omnichain Fungible Token) combined with OpenZeppelin **AccessControl**. That combination is the whole story for this token, and it is invisible if you only read the staking pool:

- `constructor(lzEndpoint, delegate)` — `delegate` becomes `owner()` (controls all LayerZero configuration: peers, delegate, enforced options) **and** is granted `DEFAULT_ADMIN_ROLE` **and** `PAUSER_ROLE`. It is **not** granted `MINTER_ROLE` or `BURNER_ROLE` at deploy.
- `mint(address to, uint256 amount, string orderId)` — `onlyRole(MINTER_ROLE)`, `whenNotPaused`. No supply cap. Comment: *"Mint tokens (Canton Bridge only)"*.
- `burn(address from, uint256 amount, string orderId)` — `onlyRole(BURNER_ROLE)`, consumes an allowance. Comment: *"Requires user to have approved sufficient allowance to the caller (BridgeController)"*.
- `pause()`/`unpause()` — `onlyRole(PAUSER_ROLE)`.
- Standard OFT `send()` — burns on the source chain, mints on the destination chain (`_credit` → `_mint`, line 3304), gated by which chains are configured as trusted **peers** by `owner()`.

So there are **two independent minting paths**, both ultimately rooted in the same admin:

1. **Cross-chain OFT bridging** (BSC ↔ Base) — supply-neutral, gated by peer config.
2. **Canton Bridge mint/burn** — mints new supply with no on-chain burn anywhere; the corresponding "burn" is supposed to happen by locking native CC on the Canton Network, a **separate, non-EVM ledger this mapping cannot see into**. This path is pure trust in whoever holds `MINTER_ROLE`.

**Live role holders** (checked directly via `hasRole`, not assumed from the source):

| Role | Owner EOA (`0x0a06…26b5b`) | Staking pool | Holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | ✅ true | false | owner EOA |
| `PAUSER_ROLE` | ✅ true | false | owner EOA |
| `MINTER_ROLE` | ❌ false | false | **not identified — see gaps** |
| `BURNER_ROLE` | ❌ false | false | **not identified — see gaps** |

The practical read: the owner EOA doesn't hold minting power directly today, but it holds `DEFAULT_ADMIN_ROLE`, which can `grantRole(MINTER_ROLE, anyone)` — including itself — in one transaction, at any time, regardless of who holds it now.

**LayerZero endpoint:** `0x1a44076050125825900e736c501f859c50fE728c` — this matches LayerZero V2's canonical `EndpointV2` address, which is deployed identically across every LZ V2 chain. Genuine, not a lookalike.

**Configured peers (checked all major LZ V2 chain IDs directly):** only **Base** (`eid 30184` → itself, same address) is a trusted peer from BSC. Every other chain ID checked (Ethereum, Avalanche, Optimism, Arbitrum, Polygon, Celo, Gnosis) is unconfigured (`0x0…0`). This independently confirms the bytecode-presence finding below — the live trust mesh really is just BSC + Base today, not a wider footprint waiting to be found.

### 2.2 wCC on Base — same token, second chain

`0x6050D829F5a5E0eA758D8357DDcdeC1381699248` also exists on **Base**, at the identical address. Its runtime bytecode is **byte-for-byte identical** to the verified BSC copy (confirmed by direct comparison, not inferred from address or length alone) — so the source in `sources/wCC.sol` applies there too, even though BscScan's Base counterpart (Basescan) shows it as unverified compiled bytecode only.

- `owner()`, `DEFAULT_ADMIN_ROLE`, `PAUSER_ROLE` → same EOA as BSC, same pattern.
- `MINTER_ROLE`/`BURNER_ROLE` → same "not the owner, not identified" result.
- Total supply on Base: **2,288.26 WCC** (vs. 4,041,180.42 on BSC) — a minor secondary deployment, not a parallel main pool.
- No staking pool contract exists on Base (no bytecode at the target address there).

### 2.3 Liquidity: where WCC actually trades

Total DEX liquidity across every pool found (DexScreener, cross-checked against direct `eth_call` reads): **≈$69,268**, spread thin:

| Chain | DEX | Pair | Liquidity (USD) |
|---|---|---|---|
| BSC | PancakeSwap V3 | wCC/USDT | **$65,982** |
| BSC | PancakeSwap | wCC/USD1 | $1,655 |
| BSC | PancakeSwap | wCC/WBNB | $1,319 |
| BSC | PancakeSwap | wCC/WBNB | $6 |
| BSC | PancakeSwap | wCC/USDT | $0.40 |
| Base | Aerodrome | wCC/USDC | $159 |
| Base | Aerodrome | wCC/WETH | $147 |

**95% of all tradable liquidity sits in one pool** (`0x02D63d1339cEA5829CCb7342755dB4ED57398321`, PancakeSwap V3). Verified genuine, not a decoy: `token0` is `0x55d398326f99059fF775485246999027B3197955`, which is the real, canonical Binance-Peg USDT on BSC (confirmed by symbol/decimals read, not assumed from the address). Real balances read directly from the pool: 1,354.87 USDT / 655,878.96 WCC (V3 is concentrated-liquidity, so this ratio is a positioning artifact, not the spot price — price ($0.09853) was taken from `slot0`/DexScreener).

For scale: the staking pool alone holds ~2.59M WCC (~$255K at spot price) and total supply is ~4.04M WCC (~$398K FDV), against **$66K of real depth in the only pool that matters.** This is a straightforward reality-vs-claims fact about the surroundings, not a statement about what anyone intends to do with it.

### 2.4 What DeFiLlama itself tracks

Pulled DeFiLlama's own TVL adapter source ([`ea-finance/index.js`](https://github.com/DefiLlama/DefiLlama-Adapters/blob/main/projects/ea-finance/index.js)) rather than trusting the dashboard number. It references **exactly these two addresses** (staking pool + WCC) and nothing else — TVL is defined as `totalStakedAmount` valued in WCC. Live DeFiLlama TVL at capture: $251,417.34; independently recomputed from raw chain data + DexScreener price: $253,470 — agreement within ~1%, which is a good sanity check on both the adapter and this mapping. The task's original figures ($302,900 / 212 days) are a slightly earlier snapshot; the gap is normal price drift over the intervening ~2–3 weeks, not a discrepancy worth flagging on its own.

---

## 3. Upstream: who holds power over this

### 3.1 The owner EOA — `0x0a06128B72Ef14F78B51a3Be776b9f2bdbC26b5b`

Confirmed by direct `eth_getCode` (returns `0x`) to be a **plain externally-owned account** — no multisig, no timelock, no smart-account logic of any kind. This single key is the top of the authority graph for the entire protocol as mapped:

- `owner()` of the staking pool → every privileged function in [§1](#1-the-target-stakingrewardswcc).
- `owner()` of the WCC token (both BSC and Base) → all LayerZero OApp configuration: which chains are trusted peers, who the delegate is, message options.
- `DEFAULT_ADMIN_ROLE` on WCC (both chains) → can grant or revoke `MINTER_ROLE`, `BURNER_ROLE`, or `PAUSER_ROLE` to any address, including itself, unilaterally.
- `PAUSER_ROLE` on WCC (both chains) → can halt all WCC transfers directly, independent of the staking pool's own pause.

One key, three separate contracts, four distinct privilege systems (`Ownable` ×2, `AccessControl`, the pool's own `Pausable`). Observed on-chain footprint for this address: 0.111 BNB balance, nonce 13 (13 transactions ever sent, BSC side) — a low-activity operational wallet, not an actively-traded address.

`Ownable` here (both contracts) is single-step — `transferOwnership` takes effect immediately with no acceptance transaction from the new owner. Worth knowing as a mechanical fact: a transfer to the wrong address is final in one transaction, not a two-step, reversible handoff.

### 3.2 The unidentified bridge minter — the gap that matters most

Something holds `MINTER_ROLE` and `BURNER_ROLE` on WCC — the code comments call it "Canton Bridge" / "BridgeController," and EA Finance's own public description says wCC is "minted against CC locked on Canton" and burned on redemption. **This mapping could not determine which address that is.** It is neither the owner EOA nor the staking pool (both directly checked and negative). `AccessControl` here is the non-enumerable OpenZeppelin variant, so there is no on-chain function to list role members — the only way to find the holder is the `RoleGranted` event history, which was not reachable in this session (see [Gaps](#gaps--unresolved)).

This is precisely the shape flagged in the brief: a wallet or contract that never appears in the target's own code, that the token's code only refers to in a comment, and that has been handed the power to create WCC out of thin air (or destroy anyone's, given an allowance) — bounded only by whoever holds that private key and by `whenNotPaused`. Nothing in this mapping says that authority is being misused; the point is that it exists, it sits outside both contracts under audit, and its holder is currently unknown.

### 3.3 The off-chain half — Canton Network collateral

The entire premise of WCC's value is "1:1 backed by CC locked on Canton" (per EA Finance's own description and the mint/burn design). Canton Network is a **separate, non-EVM, permissioned ledger** — nothing about locked collateral there is visible from BSC/Base block explorers or RPCs. This mapping can confirm the EVM-side mint/burn *mechanism* exists and who can trigger it (partially — see 3.2), but **cannot verify that the 1:1 backing claim is actually true at any given moment.** That's a trust assumption baked into the entire graph, not something on-chain data on the EVM side can settle either way.

---

## 4. Proxies

**None.** Both the staking pool and WCC were explicitly checked (Etherscan's `Proxy` flag, plus manual review — no `delegatecall`, no EIP-1967 slots, no beacon pattern in either source) and both are ordinary deployed contracts. Nothing in this graph needed resolving through a proxy to real logic.

---

## Gaps — unresolved

Everything below is a genuine blind spot from this session, not a soft-pedaled way of saying "fine." Each is something the next step should either accept as an open trust assumption or chase down before relying on this mapping.

1. **Who holds `MINTER_ROLE` / `BURNER_ROLE` on WCC.** The single biggest gap. Could hide anything from a legitimate, well-run bridge relayer to a single unmonitored hot-wallet key with unlimited mint power over the token that backs this entire pool's value. Blocked by: non-enumerable `AccessControl` + no historical event access (see #4 below).
2. **Whether Canton-side CC collateral genuinely backs outstanding WCC 1:1 right now.** Structurally outside anything an EVM explorer or RPC can see. This mapping only confirms the EVM-side mechanism exists, not that it's being honored.
3. **Deployer identity / full ownership-transfer history for both contracts.** Current `owner()` is confirmed live and direct; whether it's the original deployer or a later transfer is not. `getcontractcreation` on chain 56 was blocked by the API key's tier (see #4).
4. **Historical event logs of any kind on BSC** (past `RoleGranted`, `OwnershipTransferred`, `setRewardToken` calls — which emit no event at all and so are invisible without tx-level history, past deposits/withdrawals). Two independent walls: the supplied Etherscan API key returns "Free API access is not supported for this chain" for chain 56's `account`/`proxy`/`logs` modules (only `contract` module calls like `getsourcecode` worked), and every public BSC RPC tried refused any `eth_getLogs` query older than roughly the last few thousand blocks with "Archive requests require a personal token." Current state was read directly and is solid; anything about the past on BSC specifically is not.
5. **Owner EOA's broader footprint** — full transaction history, other chains, other contracts it may control or have deployed. Same restriction as #4. Confirmed directly: plain EOA, 0.111 BNB, nonce 13 on BSC. Not confirmed: anything beyond that.
6. **Whether `setRewardToken` has ever actually been called.** It emits no event by design. Live value still equals the original constructor value, which is the best available evidence it hasn't changed — but a change-and-revert sequence between two blocks would leave the exact same footprint and is not ruled out.
7. **LayerZero DVN/executor configuration.** LayerZero V2 security also depends on which Decentralized Verifier Networks and executors are configured on the endpoint for this OApp — a separate trust layer from the peer list checked in §2.1. Not enumerated in this session; scoped out as shared, heavily-audited base infrastructure rather than project-specific code, but flagged rather than silently skipped.
8. **wCC holder concentration.** Etherscan's token-holder-list endpoint hit the same chain-56 restriction as #4. Whether the ~4.04M BSC supply is broadly held or concentrated in a handful of wallets (which would itself bear on how much the thin $66K pool actually protects anyone) is unknown.
9. **Official docs/audit history.** `ea.finance`, `app.ea.finance`, and `bscscan.com` all returned HTTP 403 / connection resets to every fetch method available in this session (plain fetch, browser-UA curl, and headless Chromium). Any team disclosure, audit report, or documented bridge-operator address that might close gap #1 could not be checked.
10. **Full 64-chain sweep for further WCC deployments.** Eight chains were directly verified (Ethereum, BSC, Base, Optimism, Avalanche, Celo, Arbitrum, plus an inconclusive Polygon attempt); the remaining ~56 chains Etherscan's unified API covers were not individually checked. The live LayerZero peer list (§2.1, only Base configured) makes an undiscovered *active* deployment unlikely, but doesn't rule out an inactive one sitting unpeered on some other chain.

---

## Package contents

- `README.md` — this document
- `sources/StakingRewardsWCC.sol` — target, verified source, single file, project logic only (start here)
- `sources/wCC.sol` — WCC token, verified source, single file, Hardhat-flattened (start here for the token)
- `sources/*.etherscan-getsourcecode.json` — raw Etherscan API responses (ABI, compiler settings, constructor args, license) for each contract, for provenance
- `sources/StakingRewardsWCC-full/` — the same target source **split into its real file tree** (11 files: the project contract under `contracts/`, plus every imported OpenZeppelin file under `@openzeppelin/...`, exactly as compiled)
- `sources/wCC-full/` — WCC split into its real file tree (44 files: `src/wCC.sol` is the project-specific contract; everything else is the LayerZero OApp/OFT/protocol dependency tree under `@layerzerolabs/...` plus OpenZeppelin's `AccessControl`/`ERC20`/`Pausable`/`Ownable` under `@openzeppelin/...`)
- `sources/wCC-full/MANIFEST.json`, `sources/StakingRewardsWCC-full/MANIFEST.json` — per-file listing; the wCC manifest includes the **exact pinned package version compiled against each dependency** (e.g. `@openzeppelin/contracts/access/Ownable.sol@v5.4.0`, `@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFT.sol@v2.3.44`), so any file can be diffed directly against its real tagged upstream release to confirm it hasn't been altered from the known-good original
- `data/live_state.json` — every on-chain read in this mapping, machine-readable, with the exact block/values behind every number quoted above

The single-file versions and the split trees carry the same compiled source (`StakingRewardsWCC.sol` is byte-identical to its split counterpart; `wCC.sol`'s split files are exact per-dependency slices of the same Hardhat-flattened text, whitespace at slice boundaries aside) — the split just makes every dependency individually browsable and version-diffable instead of buried in one flattened file or a JSON blob.
