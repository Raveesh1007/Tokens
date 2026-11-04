"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { maxUint256, parseUnits, type Address } from "viem";

import { Wordmark } from "@/components/Brand";
import {
  LIQ_BPS,
  MIN_LOAN_AGE,
  MIN_LOAN_USDC,
  STOCKS,
  TIERS,
  USDC,
  VAULT,
  borrowable,
  tokenAbi,
  vaultAbi,
} from "@/lib/contracts";
import { formatShares, formatUsd } from "@/lib/format";
import { errorMessage, explorerTx, publicClient, shortAddress, useWallet } from "@/lib/wallet";

type Holding = {
  symbol: string;
  name: string;
  address: Address;
  wallet: bigint;
  collateral: bigint;
  debt: bigint;
  principal: bigint;
  openedAt: bigint;
  price: bigint;
  liquidatable: boolean;
};

type Standing = { score: bigint; ltv: bigint; fee: bigint; repaid: number; liquidated: number };

export default function PortfolioPage() {
  const wallet = useWallet();
  const [holdings, setHoldings] = useState<Holding[] | null>(null);
  const [standing, setStanding] = useState<Standing | null>(null);
  const [cash, setCash] = useState(0n);
  const [oracle, setOracle] = useState<Address | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [lastTx, setLastTx] = useState<string | null>(null);
  const [now, setNow] = useState(() => BigInt(Math.floor(Date.now() / 1000)));

  useEffect(() => {
    const t = setInterval(() => setNow(BigInt(Math.floor(Date.now() / 1000))), 1000);
    return () => clearInterval(t);
  }, []);

  const load = useCallback(async () => {
    if (!wallet.address) return;
    const user = wallet.address;
    const rows = await Promise.all(
      STOCKS.map(async (s) => {
        const [bal, pos, price, liq] = await Promise.all([
          publicClient.readContract({ address: s.address, abi: tokenAbi, functionName: "balanceOf", args: [user] }),
          publicClient.readContract({ address: VAULT, abi: vaultAbi, functionName: "positions", args: [user, s.address] }),
          publicClient.readContract({ address: VAULT, abi: vaultAbi, functionName: "price", args: [s.address] }),
          publicClient.readContract({ address: VAULT, abi: vaultAbi, functionName: "liquidatable", args: [user, s.address] }),
        ]);
        return {
          ...s,
          wallet: bal,
          collateral: pos[0],
          debt: pos[1],
          principal: pos[2],
          openedAt: BigInt(pos[3]),
          price,
          liquidatable: liq,
        };
      }),
    );
    const [terms, credit, usdc, orc] = await Promise.all([
      publicClient.readContract({ address: VAULT, abi: vaultAbi, functionName: "terms", args: [user] }),
      publicClient.readContract({ address: VAULT, abi: vaultAbi, functionName: "credit", args: [user] }),
      publicClient.readContract({ address: USDC, abi: tokenAbi, functionName: "balanceOf", args: [user] }),
      publicClient.readContract({ address: VAULT, abi: vaultAbi, functionName: "oracle" }),
    ]);
    setHoldings(rows);
    setStanding({ ltv: terms[0], fee: terms[1], score: terms[2], repaid: Number(credit[1]), liquidated: Number(credit[2]) });
    setCash(usdc);
    setOracle(orc);
  }, [wallet.address]);

  useEffect(() => {
    void load().catch((e) => setError(errorMessage(e)));
  }, [load]);

  const run = useCallback(
    async (label: string, steps: () => Promise<string>) => {
      setBusy(label);
      setError(null);
      try {
        setLastTx(await steps());
        await load();
      } catch (e) {
        setError(errorMessage(e));
      } finally {
        setBusy(null);
      }
    },
    [load],
  );

  const approveUsdc = async (amount: bigint) => {
    const allowance = await publicClient.readContract({
      address: USDC,
      abi: tokenAbi,
      functionName: "allowance",
      args: [wallet.address!, VAULT],
    });
    if (allowance < amount) await wallet.write(USDC, tokenAbi, "approve", [VAULT, maxUint256]);
  };

  const faucet = (h: Holding) =>
    run(`faucet-${h.symbol}`, () => wallet.write(h.address, tokenAbi, "mint", [wallet.address, parseUnits("25", 18)]));

  const faucetUsdc = () =>
    run("faucet-usdc", () => wallet.write(USDC, tokenAbi, "mint", [wallet.address, parseUnits("100", 6)]));

  const repay = (h: Holding) =>
    run(`repay-${h.symbol}`, async () => {
      await approveUsdc(h.debt);
      return wallet.write(VAULT, vaultAbi, "repay", [h.address, h.debt]);
    });

  const withdraw = (h: Holding) =>
    run(`withdraw-${h.symbol}`, () => wallet.write(VAULT, vaultAbi, "withdraw", [h.address, h.collateral]));

  const crash = (h: Holding) =>
    run(`crash-${h.symbol}`, () => wallet.write(VAULT, vaultAbi, "setPrice", [h.address, h.price / 2n]));

  const liquidate = (h: Holding) =>
    run(`liquidate-${h.symbol}`, async () => {
      await approveUsdc(h.debt);
      return wallet.write(VAULT, vaultAbi, "liquidate", [wallet.address, h.address]);
    });

  if (!wallet.address) {
    return (
      <Page>
        <div className="rise flex min-h-[70vh] flex-col justify-center">
          <Wordmark size={30} />
          <p className="mt-3 max-w-[28ch] text-[17px] leading-relaxed text-[var(--color-muted)]">
            Pay for things with the shares you already own, and build a credit history every time you repay.
          </p>
          {wallet.hasMetaMask ? (
            <Primary className="mt-9" onClick={() => void wallet.connect()}>
              Connect MetaMask
            </Primary>
          ) : (
            <a
              href="https://metamask.io/download/"
              className="mt-9 block w-full rounded-[var(--radius-control)] bg-[var(--color-accent)] py-3.5 text-center text-[15px] font-medium text-white"
            >
              Install MetaMask
            </a>
          )}
          {wallet.error && <ErrorText>{wallet.error}</ErrorText>}
        </div>
      </Page>
    );
  }

  const ltv = standing?.ltv ?? 0n;
  const totalBorrowable = (holdings ?? []).reduce(
    (sum, h) => sum + borrowable(h.price, h.wallet + h.collateral, h.debt, ltv),
    0n,
  );
  const totalValue = (holdings ?? []).reduce((sum, h) => sum + ((h.wallet + h.collateral) * h.price) / 10n ** 18n, 0n);
  const isOracle = oracle?.toLowerCase() === wallet.address.toLowerCase();

  return (
    <Page>
      <header className="flex items-center justify-between">
        <Wordmark size={15} />
        <span className="eyebrow rounded-full border border-[var(--color-line)] bg-[var(--color-white)] px-3 py-1 text-[var(--color-muted)]">
          {shortAddress(wallet.address)}
        </span>
      </header>

      <section className="rise mt-9">
        <div className="flex items-baseline justify-between">
          <p className="eyebrow text-[var(--color-muted)]">Available to spend</p>
          <button
            type="button"
            onClick={() => void load()}
            className="rounded px-1 text-[12px] text-[var(--color-muted)] hover:text-[var(--color-ink)]"
          >
            Refresh
          </button>
        </div>
        {holdings ? (
          <p className="amount mt-1.5">{formatUsd(totalBorrowable)}</p>
        ) : (
          <div aria-hidden className="mt-3 h-9 w-44 rounded-lg bg-[var(--color-surface)]" />
        )}
        {holdings && (
          <p className="mt-1.5 text-[13px] text-[var(--color-muted)]">backed by {formatUsd(totalValue)} in shares</p>
        )}
        <Link
          href="/store"
          className="mt-6 block w-full rounded-[var(--radius-control)] bg-[var(--color-accent)] py-3.5 text-center text-[15px] font-medium text-white transition-colors hover:bg-[var(--color-accent-ink)]"
        >
          Go shopping
        </Link>
      </section>

      {standing && <CreditCard standing={standing} />}

      {error && <ErrorText>{error}</ErrorText>}
      {lastTx && (
        <a
          href={explorerTx(lastTx)}
          target="_blank"
          rel="noreferrer"
          className="mt-4 block text-[13px] font-medium text-[var(--color-accent)]"
        >
          View last transaction ↗
        </a>
      )}

      <section className="mt-10">
        <p className="eyebrow text-[var(--color-muted)]">Your shares</p>
        <div className="mt-3 divide-y divide-[var(--color-line)] border-y border-[var(--color-line)]">
          {(holdings ?? []).map((h) => {
            const age = h.openedAt > 0n ? now - h.openedAt : 0n;
            const wait = BigInt(MIN_LOAN_AGE) - age;
            return (
              <div key={h.symbol} className="py-4">
                <div className="flex items-baseline justify-between">
                  <div>
                    <p className="text-[15px] font-medium">{h.symbol}</p>
                    <p className="tabular mt-0.5 text-[13px] text-[var(--color-muted)]">
                      {formatShares(h.wallet)} in wallet · {formatShares(h.collateral)} locked · {formatUsd(h.price)}
                    </p>
                  </div>
                  <Chip onClick={() => void faucet(h)} disabled={!!busy}>
                    {busy === `faucet-${h.symbol}` ? "Minting" : "+25 free"}
                  </Chip>
                </div>

                {(h.debt > 0n || h.collateral > 0n) && (
                  <div className="mt-3 rounded-[var(--radius-card)] bg-[var(--color-surface)] p-3.5">
                    <Row label="You owe" value={formatUsd(h.debt)} />
                    <Row label="Loan-to-value" value={ltvText(h)} danger={h.liquidatable} />
                    <div className="mt-3 flex gap-2">
                      {h.debt > 0n ? (
                        <Secondary onClick={() => void repay(h)} disabled={!!busy || cash < h.debt}>
                          {busy === `repay-${h.symbol}` ? "Repaying" : `Repay ${formatUsd(h.debt)}`}
                        </Secondary>
                      ) : (
                        <Secondary onClick={() => void withdraw(h)} disabled={!!busy}>
                          {busy === `withdraw-${h.symbol}` ? "Unlocking" : "Unlock shares"}
                        </Secondary>
                      )}
                    </div>
                    {h.debt > 0n && (
                      <p className="mt-2 text-[12px] leading-relaxed text-[var(--color-muted)]">
                        {h.principal < MIN_LOAN_USDC
                          ? "Loans under $10 don't count toward your score."
                          : wait > 0n
                            ? `Repay in ${wait}s or later for it to count toward your score.`
                            : "Repaying in full now adds +1 to your score."}
                        {cash < h.debt && ` You hold ${formatUsd(cash)} USDC; get more below.`}
                      </p>
                    )}
                  </div>
                )}

                {isOracle && (
                  <div className="mt-3 flex gap-2">
                    <Secondary onClick={() => void crash(h)} disabled={!!busy}>
                      {busy === `crash-${h.symbol}` ? "Crashing" : "Demo: halve price"}
                    </Secondary>
                    {h.liquidatable && (
                      <Secondary onClick={() => void liquidate(h)} disabled={!!busy}>
                        {busy === `liquidate-${h.symbol}` ? "Liquidating" : "Liquidate"}
                      </Secondary>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>

        <div className="mt-4 flex items-center justify-between">
          <p className="text-[13px] text-[var(--color-muted)]">
            Cash: <span className="tabular font-medium text-[var(--color-ink)]">{formatUsd(cash)}</span> mUSDC
          </p>
          <Chip onClick={() => void faucetUsdc()} disabled={!!busy}>
            {busy === "faucet-usdc" ? "Minting" : "+100 mUSDC"}
          </Chip>
        </div>
      </section>

      <footer className="mt-12 border-t border-[var(--color-line)] pt-5">
        <p className="max-w-[40ch] text-[13px] leading-relaxed text-[var(--color-muted)]">
          Need testnet MON for gas? Get some from the{" "}
          <a href="https://faucet.monad.xyz" className="text-[var(--color-accent)] underline">
            Monad faucet
          </a>
          .
        </p>
      </footer>
    </Page>
  );
}

function CreditCard({ standing }: { standing: Standing }) {
  const score = Number(standing.score);
  const tier = score < 0 ? 0 : score < 3 ? 1 : score < 10 ? 2 : 3;
  return (
    <section className="portal-dark noise mt-8 overflow-hidden rounded-[var(--radius-card)] p-5 text-white">
      <div className="flex items-start justify-between">
        <div>
          <p className="eyebrow text-[var(--color-accent-bg)]">Credit score</p>
          <p className="amount mt-1">{score}</p>
        </div>
        <div className="text-right">
          <p className="eyebrow text-white/60">Your terms</p>
          <p className="mt-1 text-[15px] font-medium">
            {Number(standing.ltv) / 100}% limit · {Number(standing.fee) / 100}% fee
          </p>
          <p className="mt-0.5 text-[12px] text-white/60">
            {standing.repaid} repaid · {standing.liquidated} liquidated
          </p>
        </div>
      </div>
      <div className="mt-5 grid grid-cols-4 gap-1.5">
        {TIERS.map((t, i) => (
          <div
            key={t.label}
            className={`rounded-[10px] px-2 py-2 text-center ${i === tier ? "bg-[var(--color-accent)]" : "bg-white/5"}`}
          >
            <p className="eyebrow !text-[10px] text-white/70">{t.label}</p>
            <p className="mt-0.5 text-[12px] font-medium">{t.ltv}%</p>
            <p className="text-[11px] text-white/60">{t.fee}% fee</p>
          </div>
        ))}
      </div>
      <p className="mt-4 text-[12px] leading-relaxed text-white/60">
        Each full repay of a loan of $10 or more adds +1. A liquidation costs −5. Written on-chain by the vault.
      </p>
    </section>
  );
}

function ltvText(h: Holding) {
  const value = (h.collateral * h.price) / 10n ** 18n;
  if (value === 0n) return h.debt > 0n ? "∞" : "0%";
  const bps = (h.debt * 10_000n) / value;
  return `${(Number(bps) / 100).toFixed(1)}%${bps > LIQ_BPS ? " · liquidatable" : ""}`;
}

function Page({ children }: { children: React.ReactNode }) {
  return <main className="mx-auto w-full max-w-[440px] px-6 pb-16 pt-10">{children}</main>;
}

function ErrorText({ children }: { children: React.ReactNode }) {
  return (
    <p
      role="alert"
      className="mt-6 rounded-[var(--radius-box)] bg-[rgb(217_45_32_/_0.06)] px-3.5 py-3 text-[14px] leading-relaxed text-[var(--color-danger)]"
    >
      {children}
    </p>
  );
}

function Row({ label, value, danger }: { label: string; value: string; danger?: boolean }) {
  return (
    <div className="flex items-baseline justify-between py-1">
      <span className="text-[13px] text-[var(--color-muted)]">{label}</span>
      <span className={`tabular text-[14px] font-medium ${danger ? "text-[var(--color-danger)]" : ""}`}>{value}</span>
    </div>
  );
}

function Chip({ children, onClick, disabled }: { children: React.ReactNode; onClick: () => void; disabled?: boolean }) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className="shrink-0 rounded-full border border-[var(--color-line)] px-3 py-1 text-[12px] font-medium text-[var(--color-accent)] hover:border-[var(--color-accent)] disabled:opacity-40"
    >
      {children}
    </button>
  );
}

function Primary({ children, onClick, className = "" }: { children: React.ReactNode; onClick: () => void; className?: string }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`w-full rounded-[var(--radius-control)] bg-[var(--color-accent)] py-3.5 text-[15px] font-medium text-white transition-colors hover:bg-[var(--color-accent-ink)] ${className}`}
    >
      {children}
    </button>
  );
}

function Secondary({ children, onClick, disabled }: { children: React.ReactNode; onClick: () => void; disabled?: boolean }) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className="flex-1 rounded-[var(--radius-control)] border border-[var(--color-line)] bg-[var(--color-paper)] py-2.5 text-[13px] font-medium transition-colors hover:border-[var(--color-ink)] disabled:cursor-not-allowed disabled:text-[var(--color-muted)] disabled:hover:border-[var(--color-line)]"
    >
      {children}
    </button>
  );
}
