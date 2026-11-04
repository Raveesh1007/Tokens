import { formatUnits, parseUnits, type Hex } from "viem";
import { connect, fail, need, victimWallet } from "./lib";

const c = await connect();
const { dep, vault, usdc, read, borrow, waitAge } = c;
const mUSDC = (n: number) => parseUnits(String(n), 6);
const merchant = need("MERCHANT_ADDRESS") as Hex;

const deployer = c.signer(need("DEPLOYER_KEY") as Hex);
const demo = c.signer(need("BORROWER_KEY") as Hex);
const balance = (a: Hex) => read<bigint>(usdc, "balanceOf", [a]);
const credit = (a: Hex) => read<[bigint, number, number]>(vault, "credit", [a]);
const debtOf = async (a: Hex, stock: Hex) => (await read<bigint[]>(vault, "positions", [a, stock]))[1];

console.log(`demo wallet ${demo.address}`);
if ((await balance(demo.address)) < mUSDC(500)) {
  await deployer.send("mint mUSDC to demo", usdc, "mint", [demo.address, mUSDC(1000)]);
}
await c.approve(demo, usdc);

// score 2 so the live repay on stage takes the wallet from 3500/100 to 4000/50
while ((await credit(demo.address))[0] < 2n) {
  if ((await debtOf(demo.address, dep.mNVDA)) > 0n) {
    const left = await debtOf(demo.address, dep.mNVDA);
    await demo.send("repay open loan", vault, "repay", [dep.mNVDA, left]);
    continue;
  }
  const { collateralIn } = await borrow(demo, dep.mNVDA, mUSDC(50), merchant, "seed");
  const [, , , openedAt] = await read<bigint[]>(vault, "positions", [demo.address, dep.mNVDA]);
  await waitAge(openedAt);
  await demo.send("repay", vault, "repay", [dep.mNVDA, mUSDC(50)]);
  await demo.send("withdraw", vault, "withdraw", [dep.mNVDA, collateralIn]);
}

if ((await debtOf(demo.address, dep.mNVDA)) === 0n) {
  await borrow(demo, dep.mNVDA, mUSDC(50), merchant, "seed-open");
}
const [ltv, fee, score] = await read<bigint[]>(vault, "terms", [demo.address]);
if (score !== 2n) fail(`demo wallet is at score ${score}, the demo needs score 2, use a fresh BORROWER_KEY wallet`);
console.log(`demo: score ${score}, limit ${Number(ltv) / 100}%, fee ${Number(fee) / 100}%, open loan of 50 mUSDC on mNVDA to repay live`);

const victim = (await victimWallet(c, demo, merchant, true))!;
const [collateral, debt] = await read<bigint[]>(vault, "positions", [victim.address, dep.mTSLA]);
const liqBps = await read<bigint>(vault, "LIQ_BPS");
const threshold = (debt * 10000n * 10n ** 18n) / (collateral * liqBps);
const price = await read<bigint>(vault, "price", [dep.mTSLA]);
console.log(`victim ${victim.address}: debt ${formatUnits(debt, 6)} mUSDC on mTSLA`);
console.log(`liquidatable once mTSLA price drops below ${formatUnits(threshold, 6)} (now ${formatUnits(price, 6)})`);
