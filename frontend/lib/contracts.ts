import { parseAbi, zeroAddress, type Address } from "viem";

// Fill these in from the Deploy.s.sol output once the contracts are on testnet.
export const VAULT: Address = (process.env.NEXT_PUBLIC_VAULT as Address) || zeroAddress;
export const USDC: Address = (process.env.NEXT_PUBLIC_USDC as Address) || zeroAddress;
export const MERCHANT: Address = (process.env.NEXT_PUBLIC_MERCHANT as Address) || zeroAddress;

export const STOCKS: { symbol: string; name: string; address: Address }[] = [
  { symbol: "mNVDA", name: "NVIDIA", address: (process.env.NEXT_PUBLIC_NVDA as Address) || zeroAddress },
  { symbol: "mTSLA", name: "Tesla", address: (process.env.NEXT_PUBLIC_TSLA as Address) || zeroAddress },
  { symbol: "mAAPL", name: "Apple", address: (process.env.NEXT_PUBLIC_AAPL as Address) || zeroAddress },
];

export const LTV_BPS = 3500n;
export const LIQ_BPS = 6500n;
export const USDC_DECIMALS = 6;
export const STOCK_DECIMALS = 18;

export const tokenAbi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function mint(address to, uint256 amount)",
]);

export const vaultAbi = parseAbi([
  "function price(address stock) view returns (uint256)",
  "function positions(address user, address stock) view returns (uint256 collateral, uint256 debt)",
  "function liquidatable(address user, address stock) view returns (bool)",
  "function oracle() view returns (address)",
  "function pay(address stock, uint256 collateralIn, uint256 amount, address to, bytes32 ref)",
  "function repay(address stock, uint256 amount)",
  "function withdraw(address stock, uint256 amount)",
  "function liquidate(address user, address stock)",
  "function setPrice(address stock, uint256 p)",
]);

export const deployed = VAULT !== zeroAddress;

// Mirrors Vault._healthy: extra collateral needed so (debt + amount) stays within 35% LTV.
export function collateralNeeded(price: bigint, collateral: bigint, debt: bigint, amount: bigint): bigint {
  if (price === 0n) return 0n;
  const total = (debt + amount) * 10n ** 18n * 10_000n;
  const denom = price * LTV_BPS;
  const required = (total + denom - 1n) / denom;
  return required > collateral ? required - collateral : 0n;
}

export function borrowable(price: bigint, collateral: bigint, debt: bigint): bigint {
  const max = (collateral * price) / 10n ** 18n * LTV_BPS / 10_000n;
  return max > debt ? max - debt : 0n;
}
