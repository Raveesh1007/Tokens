import type { Address } from "viem";

import { deployments, tokenAbi, vaultAbi } from "./generated";

export { tokenAbi, vaultAbi };

const d = deployments["10143"];

export const VAULT: Address = d.vault;
export const USDC: Address = d.usdc;
export const MIN_LOAN_AGE = d.minLoanAge;
export const MIN_LOAN_USDC = 10_000_000n;
export const LIQ_BPS = 6500n;

// Demo shop payee; defaults to the team's deployer wallet.
export const MERCHANT: Address =
  (process.env.NEXT_PUBLIC_MERCHANT as Address) || "0x741D5528F1318AC2B0161f8b22B1f76099204B6B";

export const STOCKS: { symbol: string; name: string; address: Address }[] = [
  { symbol: "mNVDA", name: "NVIDIA", address: d.mNVDA },
  { symbol: "mTSLA", name: "Tesla", address: d.mTSLA },
  { symbol: "mAAPL", name: "Apple", address: d.mAAPL },
];

export const TIERS = [
  { label: "below 0", ltv: 25, fee: 1.5 },
  { label: "0 to 2", ltv: 35, fee: 1 },
  { label: "3 to 9", ltv: 40, fee: 0.5 },
  { label: "10", ltv: 45, fee: 0 },
];

// Mirrors Vault._healthy: extra collateral so (debt + amount) stays within the user's LTV.
export function collateralNeeded(price: bigint, collateral: bigint, debt: bigint, amount: bigint, ltvBps: bigint): bigint {
  if (price === 0n || ltvBps === 0n) return 0n;
  const need = ((debt + amount) * 10_000n + ltvBps - 1n) / ltvBps;
  const required = (need * 10n ** 18n + price - 1n) / price;
  return required > collateral ? required - collateral : 0n;
}

export function borrowable(price: bigint, collateral: bigint, debt: bigint, ltvBps: bigint): bigint {
  const max = (((collateral * price) / 10n ** 18n) * ltvBps) / 10_000n;
  return max > debt ? max - debt : 0n;
}
