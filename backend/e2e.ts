import { isAddress, parseUnits, stringToHex, type Address, type Hex } from "viem";
import { check, checks, connect, eq, fail, need } from "./lib";

const c = await connect();
const { dep, vault, usdc, read, borrow, waitAge, expectRevert } = c;
const nvda = c.token(dep.mNVDA);
const tsla = c.token(dep.mTSLA);
const mUSDC = (n: number) => parseUnits(String(n), 6);
const step = (s: string) => console.log(`\n${s}`);

type Terms = [bigint, bigint, bigint];
type Pos = [bigint, bigint, bigint, bigint];
type Credit = [bigint, number, number];
const terms = (a: Address) => read<Terms>(vault, "terms", [a]);
const position = (a: Address, s: Address) => read<Pos>(vault, "positions", [a, s]);
const credit = (a: Address) => read<Credit>(vault, "credit", [a]);
const balance = (t: typeof usdc, a: Address) => read<bigint>(t, "balanceOf", [a]);

const merchant = need("MERCHANT_ADDRESS");
if (!isAddress(merchant)) fail("MERCHANT_ADDRESS is not an address");

const deployer = c.signer(need("DEPLOYER_KEY") as Hex);
const liquidator = c.signer(need("LIQUIDATOR_KEY") as Hex);
const funder = c.signer(need("BORROWER_KEY") as Hex);

step(`preflight on chain ${c.chainId}`);
for (const [name, a] of Object.entries({ vault: dep.vault, usdc: dep.usdc, mNVDA: dep.mNVDA, mTSLA: dep.mTSLA })) {
  check((await c.pub.getCode({ address: a })) !== undefined, `${name} has code at ${a}`);
}
eq(await read<Address>(vault, "oracle"), deployer.address, "vault oracle is DEPLOYER_KEY wallet");
eq(await read<bigint>(vault, "minLoanAge"), dep.minLoanAge, "vault minLoanAge matches deployment file");
const minLoan = await read<bigint>(vault, "MIN_LOAN_USDC");
check(mUSDC(50) >= minLoan, "test loan size clears MIN_LOAN_USDC");

const borrower = await c.fresh(funder, "e2e");
console.log(`  borrower ${borrower.address}`);
eq(await terms(borrower.address), [3500n, 100n, 0n], "new wallet terms (ltv, fee, score)");

step("setup");
await deployer.send("mint mUSDC to borrower", usdc, "mint", [borrower.address, mUSDC(1000)]);
await deployer.send("mint mUSDC to liquidator", usdc, "mint", [liquidator.address, mUSDC(1000)]);
await c.approve(borrower, usdc);
await c.approve(liquidator, usdc);

let agentId = 0n;
let feedbackBase = 0n;
if (dep.mocks) {
  agentId = BigInt(Date.now());
  feedbackBase = await read<bigint>(c.reputation, "feedbackCount");
  await deployer.send("register agent", c.identity, "setOwner", [agentId, borrower.address]);
  const link = await borrower.send("link agent", vault, "linkAgent", [agentId]);
  eq(link.logs(vault, "AgentLinked")[0].agentId, agentId, "AgentLinked agentId");
  eq(await read(vault, "agentOf", [borrower.address]), [agentId, true], "agentOf (id, set)");
} else {
  console.log("  registries are not mocks, skipping ERC-8004 mirror checks");
}

step("three counted loans");
const amount = mUSDC(50);
const baseCollateral = await read<bigint>(vault, "collateralFor", [dep.mNVDA, amount, borrower.address]);
for (let i = 0; i < 3; i++) {
  console.log(` loan ${i + 1}`);
  const selfDraw = i === 2;
  const to = selfDraw ? borrower.address : merchant;
  const before = await balance(usdc, to);
  const { collateralIn, paid } = await borrow(borrower, dep.mNVDA, amount, to, `e2e-loan-${i + 1}`);
  const fee = (amount * 100n) / 10000n;
  eq(paid.fee, fee, "fee is 1% (also on a self draw)");
  eq((await balance(usdc, to)) - before, amount - fee, `${selfDraw ? "borrower" : "merchant"} receives amount minus fee`);
  eq(paid.collateralIn, collateralIn, "Paid.collateralIn");
  const [collateral, debt, principal, openedAt] = await position(borrower.address, dep.mNVDA);
  eq([collateral, debt, principal], [collateralIn, amount, amount], "position (collateral, debt, principal)");
  check(!(await read<boolean>(vault, "liquidatable", [borrower.address, dep.mNVDA])), "position is healthy");
  await expectRevert("borrow past the limit", vault, "pay", [dep.mNVDA, 0n, mUSDC(1), merchant, stringToHex("x", { size: 32 })], borrower.address, "LTV");

  if (i === 0) {
    const part = await borrower.send("partial repay", vault, "repay", [dep.mNVDA, mUSDC(10)]);
    eq(part.logs(vault, "Repaid")[0].counted, false, "partial repay is not counted");
    eq((await credit(borrower.address))[0], 0n, "score unchanged after partial repay");
    eq((await position(borrower.address, dep.mNVDA))[1], amount - mUSDC(10), "debt after partial repay");
  }

  await waitAge(openedAt);
  const left = (await position(borrower.address, dep.mNVDA))[1];
  const done = await borrower.send("repay", vault, "repay", [dep.mNVDA, left]);
  const repaid = done.logs(vault, "Repaid")[0];
  eq(repaid.counted, true, "full repay is counted");
  eq(repaid.amount, left, "Repaid.amount");
  const [score, repaidCount] = await credit(borrower.address);
  eq([score, repaidCount], [BigInt(i + 1), i + 1], "credit (score, repaid)");
  const updated = done.logs(vault, "CreditUpdated")[0];
  eq([updated.ltvBps, updated.feeBps, updated.score], await terms(borrower.address), "CreditUpdated carries the new terms");
  eq((await position(borrower.address, dep.mNVDA))[1], 0n, "debt cleared");

  const sharesBefore = await balance(nvda, borrower.address);
  const out = await borrower.send("withdraw", vault, "withdraw", [dep.mNVDA, collateralIn]);
  eq(out.logs(vault, "Withdrawn")[0].amount, collateralIn, "Withdrawn amount");
  eq((await balance(nvda, borrower.address)) - sharesBefore, collateralIn, "shares are back in the wallet");
}

step("score 3 terms");
eq(await terms(borrower.address), [4000n, 50n, 3n], "terms after 3 repays (ltv, fee, score)");
const tierCollateral = await read<bigint>(vault, "collateralFor", [dep.mNVDA, amount, borrower.address]);
check(tierCollateral < baseCollateral, `same loan needs less collateral (${tierCollateral} < ${baseCollateral})`);

step("liquidation");
const debt = mUSDC(100);
const open = await borrow(borrower, dep.mTSLA, debt, merchant, "e2e-liq");
eq(open.paid.fee, (debt * 50n) / 10000n, "fee is 0.5% at the new tier");
const [collateral] = await position(borrower.address, dep.mTSLA);
const price = await read<bigint>(vault, "price", [dep.mTSLA]);
check(!(await read<boolean>(vault, "liquidatable", [borrower.address, dep.mTSLA])), "healthy before the crash");
await expectRevert("liquidating a healthy position", vault, "liquidate", [borrower.address, dep.mTSLA], liquidator.address, "healthy");

const crashed = (price * 6n) / 10n;
try {
  await deployer.send("crash mTSLA price", vault, "setPrice", [dep.mTSLA, crashed]);
  check(await read<boolean>(vault, "liquidatable", [borrower.address, dep.mTSLA]), "liquidatable after the crash");

  const liqUsdc = await balance(usdc, liquidator.address);
  const liqShares = await balance(tsla, liquidator.address);
  const borrowerShares = await balance(tsla, borrower.address);
  const liq = await liquidator.send("liquidate", vault, "liquidate", [borrower.address, dep.mTSLA]);
  const seizeValue = debt * 10500n;
  const wantSeized = (seizeValue * 10n ** 18n + crashed * 10000n - 1n) / (crashed * 10000n);
  const ev = liq.logs(vault, "Liquidated")[0];
  eq(ev.seized, wantSeized, "seized = debt plus 5% in collateral, rounded up");
  eq(ev.returned, collateral - wantSeized, "returned = collateral minus seized");
  eq(ev.debt, debt, "Liquidated.debt");
  eq(ev.liquidator, liquidator.address, "Liquidated.liquidator");
  eq((await balance(tsla, liquidator.address)) - liqShares, wantSeized, "liquidator received the seized shares");
  eq(liqUsdc - (await balance(usdc, liquidator.address)), debt, "liquidator paid the full debt");
  eq((await balance(tsla, borrower.address)) - borrowerShares, collateral - wantSeized, "borrower got the remainder back");
  eq(await position(borrower.address, dep.mTSLA), [0n, 0n, 0n, 0n], "position deleted");
  const after = await credit(borrower.address);
  eq(after, [-2n, 3, 1], "credit after liquidation (score 3 - 5, repaid 3, liquidated 1)");
  eq(await terms(borrower.address), [2500n, 150n, -2n], "terms after liquidation (ltv, fee, score)");
  const upd = liq.logs(vault, "CreditUpdated")[0];
  eq([upd.score, upd.ltvBps, upd.feeBps], [-2n, 2500n, 150n], "CreditUpdated after liquidation");
} finally {
  await deployer.send("restore mTSLA price", vault, "setPrice", [dep.mTSLA, price]);
}
eq(await read(vault, "price", [dep.mTSLA]), price, "price restored");

if (dep.mocks) {
  step("ERC-8004 mirror");
  eq(await read(c.reputation, "feedbackCount"), feedbackBase + 4n, "four feedback entries (3 repay, 1 liquidation)");
  const fb = async (i: bigint) => read<[bigint, bigint, number, string, string]>(c.reputation, "feedbacks", [i]);
  for (let i = 0n; i < 3n; i++) eq(await fb(feedbackBase + i), [agentId, 1n, 0, "credit", "repay"], `feedback ${i} (agentId, value, decimals, tag1, tag2)`);
  eq(await fb(feedbackBase + 3n), [agentId, -5n, 0, "credit", "liquidation"], "feedback 3 (agentId, value, decimals, tag1, tag2)");
}

console.log(`\nPASS ${checks()} checks on chain ${c.chainId}`);
