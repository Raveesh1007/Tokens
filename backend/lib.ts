import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  concat,
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  keccak256,
  maxUint256,
  parseEther,
  parseEventLogs,
  stringToHex,
  type Abi,
  type Address,
  type Hex,
  type TransactionReceipt,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const here = dirname(fileURLToPath(import.meta.url));
export const root = join(here, "..");
if (existsSync(join(here, ".env"))) process.loadEnvFile(join(here, ".env"));

export type Args = Record<string, any>;
export type Contract = { address: Address; abi: Abi };
export type Deployment = {
  chainId: number;
  minLoanAge: number;
  mocks: boolean;
  usdc: Address;
  vault: Address;
  mNVDA: Address;
  mTSLA: Address;
  mAAPL: Address;
  identity: Address;
  reputation: Address;
};

process.on("uncaughtException", (e: Error & { shortMessage?: string }) => {
  console.error(e.shortMessage ?? e.message);
  process.exit(1);
});

export function fail(msg: string): never {
  throw new Error(msg);
}

export const need = (name: string) => process.env[name] ?? fail(`missing env ${name}`);

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export function abiOf(name: string): Abi {
  const file = join(root, "contracts/out", `${name}.sol`, `${name}.json`);
  if (!existsSync(file)) fail(`no artifact for ${name}, run forge build in contracts/`);
  return JSON.parse(readFileSync(file, "utf8")).abi;
}

export const deploymentFile = (chainId: number) => join(root, "contracts/deployments", `${chainId}.json`);

let passed = 0;

export function check(ok: boolean, msg: string) {
  if (!ok) fail(`FAIL ${msg}`);
  passed++;
  console.log(`  ok   ${msg}`);
}

export function eq(got: unknown, want: unknown, msg: string) {
  if (String(got) !== String(want)) fail(`FAIL ${msg}: got ${got}, want ${want}`);
  check(true, `${msg} = ${got}`);
}

export const checks = () => passed;

const explorers: Record<number, string> = {
  10143: "https://testnet.monadscan.com/tx/",
  143: "https://monadscan.com/tx/",
};

export async function connect() {
  const url = need("RPC_URL");
  const chainId = await createPublicClient({ transport: http(url) }).getChainId();
  const chain = defineChain({
    id: chainId,
    name: `chain-${chainId}`,
    nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
    rpcUrls: { default: { http: [url] } },
  });
  const pub = createPublicClient({ chain, transport: http(url), pollingInterval: 250 });
  const isMonad = chainId in explorers;

  const file = deploymentFile(chainId);
  if (!existsSync(file)) fail(`no deployment for chain ${chainId} at ${file}, run the deploy script first`);
  const dep: Deployment = JSON.parse(readFileSync(file, "utf8"));

  const tokenAbi = abiOf("Token");
  const vault: Contract = { address: dep.vault, abi: abiOf("Vault") };
  const usdc: Contract = { address: dep.usdc, abi: tokenAbi };
  const token = (address: Address): Contract => ({ address, abi: tokenAbi });
  const identity: Contract = { address: dep.identity, abi: abiOf("MockIdentityRegistry") };
  const reputation: Contract = { address: dep.reputation, abi: abiOf("MockReputationRegistry") };

  const read = <T>(c: Contract, functionName: string, args: unknown[] = []) =>
    pub.readContract({ address: c.address, abi: c.abi, functionName, args }) as Promise<T>;

  const events = (receipt: TransactionReceipt, c: Contract, eventName: string): Args[] =>
    parseEventLogs({
      abi: c.abi,
      logs: receipt.logs.filter((l) => l.address.toLowerCase() === c.address.toLowerCase()),
      eventName,
    } as never).map((l) => (l as unknown as { args: Args }).args);

  const show = (label: string, hash: Hex) =>
    console.log(`  tx   ${label.padEnd(26)} ${explorers[chainId] ? explorers[chainId] + hash : hash}`);

  function signer(privateKey: Hex) {
    const account = privateKeyToAccount(privateKey);
    const wallet = createWalletClient({ account, chain, transport: http(url) });
    let lastBlock = 0n;

    // low-balance Monad accounts get one tx per 3 blocks
    async function pace() {
      if (!isMonad || lastBlock === 0n) return;
      while ((await pub.getBlockNumber()) < lastBlock + 3n) await sleep(100);
    }

    async function send(label: string, c: Contract, functionName: string, args: unknown[] = []) {
      await pace();
      const req = { address: c.address, abi: c.abi, functionName, args, account };
      const gas = ((await pub.estimateContractGas(req)) * 12n) / 10n;
      const hash = await wallet.writeContract({ ...req, gas });
      const receipt = await pub.waitForTransactionReceipt({ hash });
      lastBlock = receipt.blockNumber;
      show(label, hash);
      if (receipt.status !== "success") fail(`${label} reverted in ${hash}`);
      return { hash, receipt, logs: (target: Contract, eventName: string) => events(receipt, target, eventName) };
    }

    async function transfer(label: string, to: Address, value: bigint) {
      await pace();
      // native transfers cost exactly 21000
      const hash = await wallet.sendTransaction({ to, value, gas: 21000n });
      const receipt = await pub.waitForTransactionReceipt({ hash });
      lastBlock = receipt.blockNumber;
      show(label, hash);
    }

    return { address: account.address, key: privateKey, send, transfer };
  }
  type Signer = ReturnType<typeof signer>;

  // wallets are derived from the funder key, so reruns start clean and nothing is lost with the key
  const derive = (funder: Signer, tag: string, i: number) =>
    signer(keccak256(concat([funder.key, stringToHex(`${tag}${i}`)])));

  async function fund(funder: Signer, to: Address) {
    const min = parseEther(isMonad ? "1" : "0.2");
    const bal = await pub.getBalance({ address: to });
    if (bal < min) await funder.transfer("fund gas", to, min - bal);
  }

  async function fresh(funder: Signer, tag: string) {
    for (let i = 0; ; i++) {
      const s = derive(funder, tag, i);
      if ((await pub.getTransactionCount({ address: s.address })) > 0) continue;
      await fund(funder, s.address);
      return s;
    }
  }

  async function approve(who: Signer, c: Contract, spender: Address = dep.vault) {
    const allowance = await read<bigint>(c, "allowance", [who.address, spender]);
    if (allowance < maxUint256 / 2n) await who.send("approve", c, "approve", [spender, maxUint256]);
  }

  // mint the exact collateral needed (stock faucet is open) and pay `to` in one vault call
  async function borrow(who: Signer, stock: Address, amount: bigint, to: Address, ref: string) {
    const collateralIn = await read<bigint>(vault, "collateralFor", [stock, amount, who.address]);
    await who.send("mint stock", token(stock), "mint", [who.address, collateralIn]);
    await approve(who, token(stock));
    const tx = await who.send("pay", vault, "pay", [stock, collateralIn, amount, to, stringToHex(ref, { size: 32 })]);
    return { tx, collateralIn, paid: tx.logs(vault, "Paid")[0] };
  }

  async function waitAge(openedAt: bigint) {
    const target = openedAt + BigInt(dep.minLoanAge) + 1n;
    const deadline = Date.now() + (dep.minLoanAge + 60) * 1000;
    while ((await pub.getBlock()).timestamp < target) {
      if (Date.now() > deadline) fail("chain clock did not advance, run anvil with --block-time 1");
      await sleep(300);
    }
  }

  async function expectRevert(label: string, c: Contract, functionName: string, args: unknown[], from: Address, reason: string) {
    try {
      await pub.simulateContract({ address: c.address, abi: c.abi, functionName, args, account: from });
    } catch (e) {
      check((e as Error).message.includes(reason), `${label} reverts ${reason}`);
      return;
    }
    fail(`${label} did not revert`);
  }

  return {
    pub, chainId, dep, vault, usdc, token, identity, reputation,
    read, events, signer, derive, fund, fresh, approve, borrow, waitAge, expectRevert,
  };
}

export type Chain = Awaited<ReturnType<typeof connect>>;
