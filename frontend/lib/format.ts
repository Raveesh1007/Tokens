import { formatUnits } from "viem";

const usd = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });

export const formatUsd = (units: bigint) => usd.format(Number(formatUnits(units, 6)));

export const formatShares = (units: bigint) =>
  Number(formatUnits(units, 18)).toLocaleString("en-US", { maximumFractionDigits: 4 });
