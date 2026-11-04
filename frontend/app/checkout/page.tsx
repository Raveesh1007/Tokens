"use client";

import { Suspense, useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { isAddress, maxUint256, parseUnits, stringToHex, type Address } from "viem";

import { MIN_LOAN_USDC, STOCKS, VAULT, collateralNeeded, tokenAbi, vaultAbi } from "@/lib/contracts";
import { formatShares, formatUsd } from "@/lib/format";
import { errorMessage, explorerTx, publicClient, shortAddress, useWallet } from "@/lib/wallet";

type Option = { symbol: string; address: Address; price: bigint; wallet: bigint; need: bigint };
type Phase = "ready" | "approving" | "paying" | "paid";

export default function CheckoutPage() {
  return (
    <Suspense fallback={<Shell><Centered>Loading</Centered></Shell>}>
      <Checkout />
    </Suspense>
  );
}

function Checkout() {
  const params = useSearchParams();
  const wallet = useWallet();

  const amountText = params.get("amount") ?? "";
  const amount = useMemo(() => {
    try {
      return parseUnits(amountText, 6);
    } catch {
      return 0n;
    }
  }, [amountText]);
  const rawTo = params.get("to");
  const to = rawTo && isAddress(rawTo) ? rawTo : null;
  const merchant = params.get("merchant");
  const ref = params.get("ref") ?? "";
  const back = params.get("back");

  const [options, setOptions] = useState<Option[] | null>(null);
  const [terms, setTerms] = useState<{ ltv: bigint; fee: bigint; score: bigint } | null>(null);
  const [chosen, setChosen] = useState<string | null>(null);
  const [phase, setPhase] = useState<Phase>("ready");
  const [hash, setHash] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!wallet.address || !amount) return;
    const user = wallet.address;
    void publicClient
      .readContract({ address: VAULT, abi: vaultAbi, functionName: "terms", args: [user] })
      .then(async ([ltv, feeBps, score]) => {
        setTerms({ ltv, fee: feeBps, score });
        const rows = await Promise.all(
          STOCKS.map(async (s) => {
            const [bal, pos, price] = await Promise.all([
              publicClient.readContract({ address: s.address, abi: tokenAbi, functionName: "balanceOf", args: [user] }),
              publicClient.readContract({ address: VAULT, abi: vaultAbi, functionName: "positions", args: [user, s.address] }),
              publicClient.readContract({ address: VAULT, abi: vaultAbi, functionName: "price", args: [s.address] }),
            ]);
            return {
              symbol: s.symbol,
              address: s.address,
              price,
              wallet: bal,
              need: collateralNeeded(price, pos[0], pos[1], amount, ltv),
            };
          }),
        );
        setOptions(rows);
        setChosen((c) => c ?? rows.find((r) => r.price > 0n && r.wallet >= r.need)?.symbol ?? rows[0]?.symbol ?? null);
      })
      .catch((e) => setError(errorMessage(e)));
  }, [wallet.address, amount]);

  const option = options?.find((o) => o.symbol === chosen) ?? null;
  const enough = !!option && option.price > 0n && option.wallet >= option.need;
  const fee = terms ? (amount * terms.fee) / 10_000n : 0n;
  const counts = amount >= MIN_LOAN_USDC;

  const pay = useCallback(async () => {
    if (!option || !wallet.address) return;
    setError(null);
    try {
      if (option.need > 0n) {
        const allowance = await publicClient.readContract({
          address: option.address,
          abi: tokenAbi,
          functionName: "allowance",
          args: [wallet.address, VAULT],
        });
        if (allowance < option.need) {
          setPhase("approving");
          await wallet.write(option.address, tokenAbi, "approve", [VAULT, maxUint256]);
        }
      }
      setPhase("paying");
      const tx = await wallet.write(VAULT, vaultAbi, "pay", [
        option.address,
        option.need,
        amount,
        to ?? wallet.address,
        stringToHex(ref.slice(0, 31), { size: 32 }),
      ]);
      setHash(tx);
      setPhase("paid");
    } catch (e) {
      setError(errorMessage(e));
      setPhase("ready");
    }
  }, [option, wallet, amount, to, ref]);

  const destination = merchant ? `Paying ${merchant}` : to ? `Paying ${shortAddress(to)}` : "Borrowing to your wallet";

  if (!amount) return <Shell><Centered>There is no amount to pay.</Centered></Shell>;

  if (!wallet.address) {
    return (
      <Shell>
        <div className="rise flex flex-1 flex-col justify-center">
          <p className="text-[13px] text-[var(--color-muted)]">{destination}</p>
          <p className="amount amount-lg mt-2">{formatUsd(amount)}</p>
          <p className="mt-7 max-w-[30ch] text-[15px] leading-relaxed text-[var(--color-muted)]">
            Connect MetaMask to pay with shares you already own. You keep every one.
          </p>
          {wallet.error && <ErrorText>{wallet.error}</ErrorText>}
        </div>
        <Primary onClick={() => void wallet.connect()}>Connect MetaMask</Primary>
      </Shell>
    );
  }

  if (phase === "paid" && option) {
    const doneHref = back ? `${back}${back.includes("?") ? "&" : "?"}paid=${hash}` : "/portfolio";
    return (
      <Shell>
        <div className="rise flex-1">
          <span className="flex h-11 w-11 items-center justify-center rounded-full bg-[var(--color-positive-bg)]">
            <Tick />
          </span>
          <p className="mt-6 text-[13px] text-[var(--color-muted)]">{merchant ? `Paid ${merchant}` : "Done"}</p>
          <p className="amount amount-lg mt-1">{formatUsd(amount)}</p>
          <p className="mt-7 max-w-[26ch] text-[19px] font-medium leading-snug tracking-[-0.01em]">
            You still own every {option.symbol}. <span className="tabular">{formatShares(option.need)}</span> is held as
            security.
          </p>
          <div className="mt-7 rounded-[var(--radius-card)] bg-[var(--color-surface)] p-4">
            <Row label="Borrowed" value={formatUsd(amount)} />
            <Row label="Fee" value={formatUsd(fee)} />
            <Row label="Received" value={formatUsd(amount - fee)} />
            <p className="mt-3.5 border-t border-[var(--color-line)] pt-3.5 text-[13px] leading-relaxed text-[var(--color-muted)]">
              You owe {formatUsd(amount)}. Repay it and the {option.symbol} comes back to you.
              {counts
                ? " Repaying in full after the minimum loan age adds +1 to your credit score."
                : " Loans under $10 don't count toward your credit score."}
            </p>
          </div>
          {hash && (
            <a
              href={explorerTx(hash)}
              target="_blank"
              rel="noreferrer"
              className="mt-5 block text-[13px] font-medium text-[var(--color-accent)]"
            >
              View on Monad explorer ↗
            </a>
          )}
        </div>
        <Link
          href={doneHref}
          className="block w-full rounded-[var(--radius-control)] bg-[var(--color-accent)] py-3.5 text-center text-[15px] font-medium text-white"
        >
          Done
        </Link>
      </Shell>
    );
  }

  const busy = phase === "approving" || phase === "paying";

  return (
    <Shell>
      <div className="rise flex-1">
        <p className="text-[13px] text-[var(--color-muted)]">{destination}</p>
        <p className="amount amount-lg mt-2">{formatUsd(amount)}</p>

        <div className="mt-8">
          {!options ? (
            <div className="h-28 rounded-[var(--radius-card)] bg-[var(--color-surface)]" aria-hidden />
          ) : (
            <>
              <p className="eyebrow text-[var(--color-muted)]">Pay with</p>
              <div className="mt-2 flex gap-2">
                {options.map((o) => (
                  <button
                    key={o.symbol}
                    type="button"
                    onClick={() => setChosen(o.symbol)}
                    aria-pressed={o.symbol === chosen}
                    className={`flex-1 rounded-[var(--radius-control)] border py-2.5 text-[13px] font-medium transition-colors ${
                      o.symbol === chosen
                        ? "border-[var(--color-accent)] bg-[var(--color-accent-bg)] text-[var(--color-accent)]"
                        : "border-[var(--color-line)] text-[var(--color-muted)] hover:border-[var(--color-ink)]"
                    }`}
                  >
                    {o.symbol}
                  </button>
                ))}
              </div>

              {option && (
                <div className="mt-4 rounded-[var(--radius-card)] bg-[var(--color-surface)] p-4">
                  <Row label="Locked as security" value={`${formatShares(option.need)} ${option.symbol}`} />
                  <Row label="You hold" value={`${formatShares(option.wallet)} ${option.symbol}`} />
                  <Row label="Share price" value={formatUsd(option.price)} />
                  {terms && <Row label="Your limit" value={`${Number(terms.ltv) / 100}% of collateral`} />}
                  <Row label="Fee" value={`${formatUsd(fee)} (${Number(terms?.fee ?? 0n) / 100}%)`} />
                  <Row label="Recipient gets" value={formatUsd(amount - fee)} />
                  <p className="mt-4 border-t border-[var(--color-line)] pt-4 text-[13px] leading-relaxed text-[var(--color-muted)]">
                    Your shares are held, not sold. Repay the {formatUsd(amount)} any time to unlock them.
                  </p>
                </div>
              )}

              {option && !enough && (
                <p className="mt-4 text-[13px] leading-relaxed text-[var(--color-danger)]">
                  Not enough {option.symbol}.{" "}
                  <Link href="/portfolio" className="underline">
                    Get free test shares
                  </Link>
                </p>
              )}
            </>
          )}
        </div>

        {error && <ErrorText>{error}</ErrorText>}
      </div>

      <Primary onClick={() => void pay()} disabled={!enough || busy}>
        {phase === "approving" ? "Approve in MetaMask (1 of 2)" : phase === "paying" ? "Confirm in MetaMask" : `Pay ${formatUsd(amount)}`}
      </Primary>
      {back && (
        <Link
          href={back}
          className="mt-2 block w-full py-2.5 text-center text-[13px] text-[var(--color-muted)] hover:text-[var(--color-ink)]"
        >
          Cancel
        </Link>
      )}
    </Shell>
  );
}

function Tick() {
  return (
    <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden>
      <path d="M4 9.5 7.2 12.6 14 5.8" stroke="var(--color-positive)" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function Shell({ children }: { children: React.ReactNode }) {
  return <main className="mx-auto flex min-h-screen w-full max-w-[420px] flex-col px-6 pb-7 pt-9">{children}</main>;
}

function Centered({ children }: { children: React.ReactNode }) {
  return <div className="flex flex-1 items-center justify-center text-[15px] text-[var(--color-muted)]">{children}</div>;
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

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-baseline justify-between py-1.5">
      <span className="text-[13px] text-[var(--color-muted)]">{label}</span>
      <span className="tabular text-[14px] font-medium">{value}</span>
    </div>
  );
}

function Primary({ children, onClick, disabled }: { children: React.ReactNode; onClick: () => void; disabled?: boolean }) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className="w-full rounded-[var(--radius-control)] bg-[var(--color-accent)] py-3.5 text-[15px] font-medium text-white transition-colors hover:bg-[var(--color-accent-ink)] disabled:cursor-not-allowed disabled:bg-[var(--color-line)] disabled:text-[var(--color-muted)]"
    >
      {children}
    </button>
  );
}
