"use client";

import { useCallback, useEffect, useState } from "react";
import {
  createPublicClient,
  createWalletClient,
  custom,
  http,
  type Abi,
  type Address,
  type EIP1193Provider,
  type Hash,
} from "viem";
import { monadTestnet } from "viem/chains";

export const chain = monadTestnet;
export const publicClient = createPublicClient({ chain, transport: http() });
export const explorerTx = (hash: string) => `${chain.blockExplorers.default.url}/tx/${hash}`;

declare global {
  interface Window {
    ethereum?: EIP1193Provider;
  }
}

export function useWallet() {
  const [address, setAddress] = useState<Address | null>(null);
  const [error, setError] = useState<string | null>(null);
  const hasMetaMask = typeof window !== "undefined" && !!window.ethereum;

  useEffect(() => {
    const eth = window.ethereum;
    if (!eth) return;
    void eth.request({ method: "eth_accounts" }).then((a) => setAddress((a[0] as Address) ?? null));
    const onAccounts = (a: string[]) => setAddress((a[0] as Address) ?? null);
    eth.on("accountsChanged", onAccounts);
    return () => eth.removeListener("accountsChanged", onAccounts);
  }, []);

  const walletClient = useCallback(() => {
    if (!window.ethereum) throw new Error("MetaMask isn't installed.");
    return createWalletClient({ chain, transport: custom(window.ethereum) });
  }, []);

  const connect = useCallback(async () => {
    setError(null);
    try {
      const client = walletClient();
      const [account] = await client.requestAddresses();
      try {
        await client.switchChain({ id: chain.id });
      } catch {
        await client.addChain({ chain });
      }
      setAddress(account ?? null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [walletClient]);

  const write = useCallback(
    async (address: Address, abi: Abi, functionName: string, args: readonly unknown[]): Promise<Hash> => {
      const client = walletClient();
      const [account] = await client.getAddresses();
      if (!account) throw new Error("Connect MetaMask first.");
      if ((await client.getChainId()) !== chain.id) await client.switchChain({ id: chain.id });
      const hash = await client.writeContract({ account, chain, address, abi, functionName, args });
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") throw new Error("The transaction reverted.");
      return hash;
    },
    [walletClient],
  );

  return { address, error, hasMetaMask, connect, write };
}

export function shortAddress(a: string) {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

export function errorMessage(e: unknown): string {
  const raw = e instanceof Error ? e.message : String(e);
  if (/user rejected|denied/i.test(raw)) return "You cancelled it in MetaMask.";
  if (/LTV/.test(raw)) return "That's more than your shares can cover at 35% loan-to-value.";
  if (/insufficient funds/i.test(raw)) return "You need testnet MON for gas.";
  return raw.split("\n")[0] ?? raw;
}
