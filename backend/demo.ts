import { formatUnits, parseUnits, type Address, type Hex } from "viem";
import { connect, fail, need, victimWallet, type Signer } from "./lib";

const c = await connect();
const { dep, vault, usdc, read } = c;
const deployer = c.signer(need("DEPLOYER_KEY") as Hex);
const demo = c.signer(need("BORROWER_KEY") as Hex);
const liquidator = c.signer(need("LIQUIDATOR_KEY") as Hex);
const merchant = need("MERCHANT_ADDRESS") as Address;

const mUSDC = (n: number) => parseUnits(String(n), 6);
const stocks: Record<string, { address: Address; base: bigint }> = {
  mNVDA: { address: dep.mNVDA, base: mUSDC(200) },
  mTSLA: { address: dep.mTSLA, base: mUSDC(450) },
  mAAPL: { address: dep.mAAPL, base: mUSDC(270) },
};
const price = (sym: string) => read<bigint>(vault, "price", [stocks[sym].address]);
const balance = (a: Address) => read<bigint>(usdc, "balanceOf", [a]);
const terms = (a: Address) => read<[bigint, bigint, bigint]>(vault, "terms", [a]);
const position = (a: Address, sym: string) => read<bigint[]>(vault, "positions", [a, stocks[sym].address]);
const liquidatable = (a: Address) => read<boolean>(vault, "liquidatable", [a, dep.mTSLA]);
const fmtTerms = ([ltv, fee, score]: bigint[]) => `score ${score}, limit ${Number(ltv) / 100}%, fee ${Number(fee) / 100}%`;
const victim = () => victimWallet(c, demo, merchant, false);

async function setPrice(sym: string, next: bigint) {
  await deployer.send(`set ${sym} price`, vault, "setPrice", [stocks[sym].address, next]);
}

async function describe(label: string, who: Address) {
  console.log(`${label} ${who}`);
  console.log(`  ${fmtTerms(await terms(who))}`);
  for (const sym of Object.keys(stocks)) {
    const [collateral, debt] = await position(who, sym);
    if (collateral || debt) console.log(`  ${sym}: collateral ${formatUnits(collateral, 18)}, debt ${formatUnits(debt, 6)} mUSDC`);
  }
}

// make sure `who` can cover `amount` of mUSDC and the vault is approved to pull it
async function fundUsdc(who: Signer, amount: bigint) {
  const bal = await balance(who.address);
  if (bal < amount) await deployer.send(`mint mUSDC to wallet`, usdc, "mint", [who.address, amount - bal]);
  await c.approve(who, usdc);
}

async function status() {
  for (const sym of Object.keys(stocks)) console.log(`${sym} price ${formatUnits(await price(sym), 6)}`);
  await describe("demo", demo.address);
  const v = await victim();
  if (!v) return console.log("victim: none, run refresh");
  await describe("victim", v.address);
  const [collateral, debt] = await position(v.address, "mTSLA");
  const below = (debt * 10000n * 10n ** 18n) / (collateral * (await read<bigint>(vault, "LIQ_BPS")));
  console.log(`  liquidatable now: ${await liquidatable(v.address)} (below mTSLA price ${formatUnits(below, 6)})`);
}

async function crash() {
  const [sym, pctArg] = process.argv.slice(3);
  const pct = Number(pctArg);
  if (!stocks[sym] || !Number.isInteger(pct) || pct < 1 || pct > 99) fail("usage: crash <mNVDA|mTSLA|mAAPL> <percent 1-99>");
  const old = await price(sym);
  const next = (old * BigInt(100 - pct)) / 100n;
  await setPrice(sym, next);
  console.log(`${sym} ${formatUnits(old, 6)} -> ${formatUnits(next, 6)}`);
  const v = await victim();
  if (v && sym === "mTSLA") console.log(`victim liquidatable: ${await liquidatable(v.address)}`);
}

async function restore() {
  for (const [sym, s] of Object.entries(stocks)) {
    if ((await price(sym)) === s.base) continue;
    await setPrice(sym, s.base);
    console.log(`${sym} back to ${formatUnits(s.base, 6)}`);
  }
}

// stage reset: base prices, a fresh liquidatable victim, an open loan on the demo wallet, a funded liquidator
async function refresh() {
  await restore();
  const v = (await victimWallet(c, demo, merchant, true))!;
  await fundUsdc(demo, mUSDC(500));
  if ((await position(demo.address, "mNVDA"))[1] === 0n) await c.borrow(demo, dep.mNVDA, mUSDC(50), merchant, "refresh");
  await fundUsdc(liquidator, mUSDC(500));
  await describe("demo", demo.address);
  await describe("victim", v.address);
}

async function repay() {
  const label = process.argv[3];
  const wallets: Record<string, () => Promise<Signer | undefined>> = {
    demo: async () => demo,
    liquidator: async () => liquidator,
    victim: victim,
  };
  const who = await wallets[label]?.();
  if (!who) fail("usage: repay <demo|victim|liquidator>, victim needs an open position");
  const before = await terms(who.address);
  let repaid = 0;
  for (const sym of Object.keys(stocks)) {
    const [, debt] = await position(who.address, sym);
    if (debt === 0n) continue;
    await fundUsdc(who, debt);
    const tx = await who.send(`repay ${sym}`, vault, "repay", [stocks[sym].address, debt]);
    console.log(`  counted: ${tx.logs(vault, "Repaid")[0].counted}`);
    repaid++;
  }
  if (!repaid) fail(`${label} has no open position`);
  console.log(`${label}: ${fmtTerms(before)} -> ${fmtTerms(await terms(who.address))}`);
}

async function liquidate() {
  const v = (await victim()) ?? fail("no victim with an open position, run refresh");
  const [collateral, debt] = await position(v.address, "mTSLA");
  if (!(await liquidatable(v.address))) fail("victim is healthy, run: crash mTSLA 60");
  const before = await terms(v.address);
  await fundUsdc(liquidator, debt);
  const tx = await liquidator.send("liquidate", vault, "liquidate", [v.address, dep.mTSLA]);
  const ev = tx.logs(vault, "Liquidated")[0];
  console.log(`debt ${formatUnits(ev.debt, 6)} mUSDC repaid by the liquidator`);
  console.log(`seized ${formatUnits(ev.seized, 18)} mTSLA, returned ${formatUnits(ev.returned, 18)} mTSLA to the victim (collateral was ${formatUnits(collateral, 18)})`);
  console.log(`victim: ${fmtTerms(before)} -> ${fmtTerms(await terms(v.address))}`);
}

const commands: Record<string, () => Promise<unknown>> = { status, crash, restore, refresh, repay, liquidate };
const run = commands[process.argv[2]];
if (!run) fail(`usage: tsx demo.ts <${Object.keys(commands).join("|")}> [args]`);
await run();
