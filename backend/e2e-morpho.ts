import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { isAddress, maxUint256, parseEther, parseUnits, stringToHex, type Address, type Hex } from "viem";
import { abiOf, chainAt, check, checks, eq, fail, need, root, type Contract } from "./lib";

type Dep = {
  chainId: number;
  minLoanAge: number;
  router: Address;
  morpho: Address;
  marketId: Hex;
  oracle: Address;
  usdc: Address;
  nvda: Address;
};

const c = await chainAt(process.env.MORPHO_RPC_URL ?? "https://rpc.monad.xyz");
const file = join(root, "contracts/deployments", `${c.chainId}-morpho.json`);
if (!existsSync(file)) fail(`no deployment at ${file}, run DeployMorpho.s.sol first`);
const dep: Dep = JSON.parse(readFileSync(file, "utf8"));

const { read } = c;
const router: Contract = { address: dep.router, abi: abiOf("MorphoCreditRouter") };
const morpho: Contract = { address: dep.morpho, abi: abiOf("IMorpho") };
const oracle: Contract = { address: dep.oracle, abi: abiOf("MockMorphoOracle") };
const usdc = c.token(dep.usdc);
const nvda = c.token(dep.nvda);
const mUSDC = (n: number) => parseUnits(String(n), 6);
const step = (s: string) => console.log(`\n${s}`);

const merchant = need("MERCHANT_ADDRESS");
if (!isAddress(merchant)) fail("MERCHANT_ADDRESS is not an address");
const deployer = c.signer(need("DEPLOYER_KEY") as Hex);

const balance = (t: Contract, a: Address) => read<bigint>(t, "balanceOf", [a]);
const pos = (a: Address) => read<{ supplyShares: bigint; borrowShares: bigint; collateral: bigint }>(morpho, "position", [dep.marketId, a]);
const terms = (a: Address) => read<[bigint, bigint, bigint]>(router, "terms", [a]);

step(`preflight on chain ${c.chainId}`);
for (const [name, a] of Object.entries({ router: dep.router, morpho: dep.morpho, oracle: dep.oracle, usdc: dep.usdc, nvda: dep.nvda })) {
  check((await c.pub.getCode({ address: a })) !== undefined, `${name} has code at ${a}`);
}
eq(await read(router, "morpho"), dep.morpho, "router points at Morpho");
eq(await read(router, "marketId"), dep.marketId, "router marketId matches the deployment");
eq(await read(router, "minLoanAge"), dep.minLoanAge, "router minLoanAge matches the deployment");
const market = await read<{ lastUpdate: bigint; totalSupplyAssets: bigint }>(morpho, "market", [dep.marketId]);
check(market.lastUpdate > 0n, "market exists in Morpho");
check(market.totalSupplyAssets >= mUSDC(1000), `market has supply (${market.totalSupplyAssets})`);
eq(await read(usdc, "owner"), deployer.address, "DEPLOYER_KEY wallet owns mUSDC");

const borrower = await c.fresh(deployer, "morpho", parseEther("0.5"));
console.log(`  borrower ${borrower.address}`);
eq(await terms(borrower.address), [3500n, 100n, 0n], "new wallet terms (ltv, fee, score)");

step("setup");
const amount = mUSDC(50);
const [ltv, feeBps] = await terms(borrower.address);
const price = await read<bigint>(oracle, "price");
const needValue = (amount * 10000n + ltv - 1n) / ltv;
const collateralIn = (needValue * 10n ** 36n + price - 1n) / price;
await deployer.send("mint mUSDC to borrower", usdc, "mint", [borrower.address, mUSDC(100)]);
await borrower.send("mint mNVDA", nvda, "mint", [borrower.address, collateralIn]);
await c.approve(borrower, nvda, dep.router);
await c.approve(borrower, usdc, dep.router);
await borrower.send("morpho authorize router", morpho, "setAuthorization", [dep.router, true]);
eq(await read(morpho, "isAuthorized", [borrower.address, dep.router]), true, "router is authorized on Morpho");

const agentEnv = process.env.AGENT_ID;
let linked = false;
if (agentEnv) {
  const agentId = BigInt(agentEnv);
  const idReg: Contract = { address: await read<Address>(router, "identity"), abi: abiOf("MockIdentityRegistry") };
  const as = (from: Address, target: Contract, functionName: string, args: unknown[]) =>
    c.pub.simulateContract({ address: target.address, abi: target.abi, functionName, args, account: from }).then(() => true, () => false);
  // only the mock registry has setOwner, the real one assigns agents to their own owners
  if (await as(deployer.address, idReg, "setOwner", [agentId, borrower.address])) {
    await deployer.send("register agent", idReg, "setOwner", [agentId, borrower.address]);
  }
  if (await as(borrower.address, router, "linkAgent", [agentId])) {
    const link = await borrower.send("link agent", router, "linkAgent", [agentId]);
    eq(link.logs(router, "AgentLinked")[0].agentId, agentId, "AgentLinked agentId");
    linked = true;
  } else {
    console.log(`  borrower cannot link agent ${agentId}, skipping`);
  }
}

step("pay a merchant");
const merchantBefore = await balance(usdc, merchant);
const routerBefore = await balance(usdc, dep.router);
const pay = await borrower.send("pay", router, "pay", [collateralIn, amount, merchant, stringToHex("e2e-morpho", { size: 32 })]);
const fee = (amount * feeBps) / 10000n;
const paid = pay.logs(router, "Paid")[0];
eq(paid.fee, fee, "Paid.fee is 1%");
eq(paid.collateralIn, collateralIn, "Paid.collateralIn");
eq((await balance(usdc, merchant)) - merchantBefore, amount - fee, "merchant receives amount minus fee");
eq((await balance(usdc, dep.router)) - routerBefore, fee, "fee stays in the router");
const open = await pos(borrower.address);
eq(open.collateral, collateralIn, "Morpho collateral");
check(open.borrowShares > 0n, "Morpho borrow shares are open");
check((await read<bigint>(router, "debtOf", [borrower.address])) >= amount, "router debtOf covers the loan");
const [principal, openedAt] = await read<[bigint, bigint]>(router, "loans", [borrower.address]);
eq(principal, amount, "loan principal");

step("repay in full");
await c.waitUntil(openedAt + BigInt(dep.minLoanAge) + 2n, dep.minLoanAge + 60);
const done = await borrower.send("repay", router, "repay", [maxUint256]);
const repaid = done.logs(router, "Repaid")[0];
eq(repaid.counted, true, "full repay is counted");
check(repaid.amount >= amount, `Repaid.amount covers the principal (${repaid.amount})`);
eq((await pos(borrower.address)).borrowShares, 0n, "Morpho borrowShares are zero");
eq(await read(router, "credit", [borrower.address]), [1n, 1, 0], "credit (score, repaid, liquidated)");
eq(await terms(borrower.address), [3500n, 100n, 1n], "terms after one repay (ltv, fee, score)");
const updated = done.logs(router, "CreditUpdated")[0];
eq([updated.ltvBps, updated.feeBps, updated.score], [3500n, 100n, 1n], "CreditUpdated carries the new terms");
eq(await read(router, "loans", [borrower.address]), [0n, 0n], "loan record cleared");
if (linked) console.log(`  mirror: ${done.logs(router, "MirrorFailed").length ? "registry call failed (loan unaffected)" : "no failure reported"}`);

console.log(`\nPASS ${checks()} checks on chain ${c.chainId}`);
