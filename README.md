# StockSwipe

**Inspired by [Draw](https://github.com/Nnadijoshuac/draw) (MIT, Nnadi Joshua, 2nd place at Stocklana), rebuilt for Monad.**

Borrow against tokenized shares without selling them, pay a merchant in the same transaction, and build a credit history on-chain. Every full repayment of a real loan is written by the lender, and a good record lowers your fee and raises your limit.

Monad Blitz Devcon Mumbai, 4 Nov 2026.

- Live app: https://stockswipe.site (frontend in `frontend/`, Next.js on Vercel, wired to the testnet Vault below)
- Repo: https://github.com/Raveesh1007/Tokens

## What it does

1. Lock mock shares (mNVDA, mTSLA, mAAPL) as collateral.
2. Borrow mock USDC against them and pay a merchant (or yourself) in one transaction.
3. Repay in full. If the loan was real (at least 10 USDC, held at least `minLoanAge`), the vault adds 1 to your score and writes it on-chain. A liquidation subtracts 5.
4. The score sets your terms. A good score never makes a loan unsecured: collateral backs every loan.

| Score | Max borrow | Fee |
| --- | --- | --- |
| below 0 | 25% of collateral | 1.5% |
| 0 to 2 | 35% | 1% |
| 3 to 9 | 40% | 0.5% |
| 10 (cap) | 45% | 0% |

Ten repaid loans cut the collateral needed for a 50 USDC loan by 22% and the fee to zero. The fee is always charged, including when you draw to your own wallet.

Optionally a borrower links an ERC-8004 agent identity, and the contract mirrors each score change to the ERC-8004 reputation registry, so other lenders can read it by trusting the contract address.

## Two deployments

### 1. StockSwipe Vault on Monad testnet (chain 10143), the demo path

A from-scratch lending vault. Liquidation threshold 65% for everyone, liquidator gets the debt plus 5% in collateral and the borrower gets the rest back. Demo `minLoanAge` is **10 seconds**; a real deployment would use days.

| Contract | Address |
| --- | --- |
| Vault | [`0x4F02789f8f68b10cd69C692B1c7C1DF02f4c7A13`](https://testnet.monadscan.com/address/0x4F02789f8f68b10cd69C692B1c7C1DF02f4c7A13) |
| mUSDC (open mint) | [`0x10B65a44193689b25999A6dBeaD4c1b96F2BAdea`](https://testnet.monadscan.com/address/0x10B65a44193689b25999A6dBeaD4c1b96F2BAdea) |
| mNVDA | [`0x57ffF3DF7e217477c67D21B75c64795106b72A06`](https://testnet.monadscan.com/address/0x57ffF3DF7e217477c67D21B75c64795106b72A06) |
| mTSLA | [`0xcEf7B276641729Bf026d75a0c8B1Dc62bC36B04a`](https://testnet.monadscan.com/address/0xcEf7B276641729Bf026d75a0c8B1Dc62bC36B04a) |
| mAAPL | [`0xBaa6DAaC6446ed4252ca71709Fe7BD55DC6e0b2b`](https://testnet.monadscan.com/address/0xBaa6DAaC6446ed4252ca71709Fe7BD55DC6e0b2b) |
| Mock ERC-8004 identity registry | [`0x745a10f0587348d6332621B9e5d0053D8038dB70`](https://testnet.monadscan.com/address/0x745a10f0587348d6332621B9e5d0053D8038dB70) |
| Mock ERC-8004 reputation registry | [`0xB892EbFD91C9A9AE7b4E2978fB611B843EC36389`](https://testnet.monadscan.com/address/0xB892EbFD91C9A9AE7b4E2978fB611B843EC36389) |

All verified on the explorer. The ERC-8004 registries do not exist on Monad testnet, so these are open mocks.

### 2. Morpho Blue credit router on Monad mainnet (chain 143)

The same score and tiers on top of the real Morpho Blue. The router wraps one Morpho market (mock USDC against mock NVDA, LLTV 62.5%, AdaptiveCurveIrm) and uses the real ERC-8004 registries. A live run registered agent 10423 on the real identity registry ([tx](https://monadscan.com/tx/0xfe3769db91c683ac00cabc3f4341303aafbbeb8ef29f9e22cf9e107dbb361cff)); after a full repay ([tx](https://monadscan.com/tx/0x1ffc06c92a12549729d6843832dab4784fe3070c1c2abee237d955740ae37b49)) the real reputation registry held one feedback from the router for that agent: +1, tag `credit`, tag `repay`.

| Contract | Address |
| --- | --- |
| MorphoCreditRouter | [`0xa6d6c28550012B88e02A43aD1F524D8Edd0265bf`](https://monadscan.com/address/0xa6d6c28550012B88e02A43aD1F524D8Edd0265bf) |
| Morpho Blue (existing) | [`0xD5D960E8C380B724a48AC59E2DfF1b2CB4a1eAee`](https://monadscan.com/address/0xD5D960E8C380B724a48AC59E2DfF1b2CB4a1eAee) |
| Market id | `0xfe18e427b73a384953f44b1b8aac0df2b69e49d424df13925d17ee4e4d050f66` |
| Mock oracle | [`0xf8AEa39ffee9AA5FfA82c3Ff3bc72448E9a1005a`](https://monadscan.com/address/0xf8AEa39ffee9AA5FfA82c3Ff3bc72448E9a1005a) |
| mUSDC (open mint) | [`0x4288A1124145965116822CA74E8e34ac6DA49c40`](https://monadscan.com/address/0x4288A1124145965116822CA74E8e34ac6DA49c40) |
| mNVDA | [`0xda35Ed558a82a9209987E125548D34c7F59a250a`](https://monadscan.com/address/0xda35Ed558a82a9209987E125548D34c7F59a250a) |
| ERC-8004 identity / reputation | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` / `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` |

Verified on the explorer. On this path liquidation follows Morpho: threshold is the 62.5% LLTV and the liquidator's bonus is Morpho's incentive (about 12.7% at this LLTV).

## What is tested

- `forge test` runs 28 Vault tests offline, including a fuzz test that no successful `pay` exceeds the tier limit.
- 30 fork tests run against the real Morpho and the real ERC-8004 registries on a mainnet fork. One suite registers a real agent and checks that a counted repay and a liquidation land in the real reputation registry.
- `backend/e2e.ts` passes 75 checks on the testnet deployment: three counted loans, the tier change to 40%/0.5%, a liquidation, and the registry mirror.
- `backend/e2e-morpho.ts` passes 28 checks on the mainnet deployment: a merchant payment through the router and a full repay by shares, ending at score 1. With `REGISTER_AGENT=1` it passes 35, adding the real agent registration and the read-back of the feedback from the real reputation registry.
- `pay`, `repay`, `withdraw` and `liquidate` are reentrancy-guarded, and internal audit passes on both the Vault and the Morpho router found no High issues.

## What is mocked, and the honest limits

- **All tokens are mocks** (shares and USDC, open mint) and the price comes from an owner-controlled oracle. No real stock exposure, no real users, nothing here is regulated.
- **The score is cheap to earn at demo settings.** Nobody can write their own score, only the contract does, but anyone can earn one. With the 10 second `minLoanAge` and open-mint USDC a wallet reaches the cap in about a minute. It is a real signal only with real loan ages, real money and a shared registry.
- **There are no due dates and no interest in the Vault**, so the score counts completed borrow and repay cycles, not punctuality. (On the Morpho path interest accrues in Morpho.)
- **A liquidated user can start over with a fresh wallet.** The penalty costs earned tiers, not a ban.
- **On the Morpho path, tiers price and cap loans taken through the router only.** A wallet can also borrow directly on Morpho up to its LLTV with no score and no fee, repays and liquidations done directly on Morpho are not counted, and leftover collateral is withdrawn through Morpho.
- **Not built:** interest accrual in the Vault, a real price feed (Pyth), a peg guard, a merchant embed button and webhooks (all of which Draw has).

## Prior art and credit

[Draw](https://github.com/Nnadijoshuac/draw) (Solana, Kamino, xStocks) shipped the idea of spending tokenized shares without selling them in one atomic transaction, with a 35% cap, a risk price instead of a health factor, and a merchant embed. We borrow those ideas knowingly.

The UI in `frontend/` is adapted from Draw under the MIT license (`frontend/LICENSE-draw`). The contracts, the credit score and tiers, the ERC-8004 mirror, the tests, the backend and the Morpho integration are written for this event. What we add is a lender-written credit history, and a from-scratch vault because Kamino does not exist on Monad.

## Run it

```bash
cd contracts
forge install foundry-rs/forge-std@v1.17.0 OpenZeppelin/openzeppelin-contracts@v5.7.0 morpho-org/morpho-blue --no-git
forge build
forge test
forge test --fork-url https://rpc.monad.xyz --match-contract 'MorphoRouterFork|MorphoRealRegistryFork'
```

```bash
cd backend
npm install
cp .env.example .env     # fill RPC_URL and keys for Monad testnet
npx tsx e2e.ts           # full flow on the deployment in contracts/deployments/<chainId>.json
npx tsx demo.ts status   # stage remote: status, crash, restore, repay, liquidate, refresh
```

Deploy scripts: `contracts/script/Deploy.s.sol` (Vault) and `contracts/script/DeployMorpho.s.sol` (Morpho market and router). Monad charges gas on the gas limit, so use `--gas-estimate-multiplier 120`, and `--slow` for deployers holding under 10 MON.

## Demo (3 minutes)

1. A new wallet pays a merchant 50 USDC against mNVDA: limit 35%, fee 1%. The user keeps their shares.
2. A seeded wallet at score 2 repays live: the score ticks to 3 and the terms move to 40% and 0.5%, visible in the `CreditUpdated` event on the explorer.
3. Crash a price, liquidate a second wallet live: collateral goes to the liquidator, the remainder returns to the borrower, the score drops to -5 and terms to 25% and 1.5%.
4. Same score and tiers on mainnet over Morpho Blue and the real ERC-8004 registry.

## Next

Interest and due dates, Pyth prices with a peg guard, a shared registry that more than one lender writes to, and running the vault inside Monad Private Settlement once it is live so positions stay private (a published design, not live today).
