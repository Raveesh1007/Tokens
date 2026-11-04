"use client";

import { Suspense } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";

import { MERCHANT } from "@/lib/contracts";
import { explorerTx } from "@/lib/wallet";

const SHOP = "Bandra Chai Co.";
const ITEMS = [
  { name: "Masala chai × 2", price: "5", note: "With a side of Parle-G" },
  { name: "Vada pav combo", price: "3", note: "Two pav, extra chutney" },
  { name: "Filter coffee", price: "2", note: "Madras style, steel tumbler" },
];

export default function StorePage() {
  return (
    <Suspense>
      <Store />
    </Suspense>
  );
}

function Store() {
  const paid = useSearchParams().get("paid");

  return (
    <main className="mx-auto w-full max-w-[440px] px-6 pb-16 pt-10">
      <header className="flex items-center justify-between">
        <div>
          <p className="text-[20px] font-semibold tracking-[-0.02em]">{SHOP}</p>
          <p className="text-[13px] text-[var(--color-muted)]">A demo merchant on Monad testnet</p>
        </div>
        <Link href="/portfolio" className="text-[13px] text-[var(--color-accent)]">
          My shares
        </Link>
      </header>

      {paid && (
        <div className="rise mt-7 rounded-[var(--radius-card)] bg-[var(--color-positive-bg)] p-4">
          <p className="text-[15px] font-medium text-[var(--color-positive)]">Order confirmed. Paid on-chain.</p>
          <a href={explorerTx(paid)} target="_blank" rel="noreferrer" className="mt-1 block text-[13px] text-[var(--color-positive)] underline">
            See the transaction ↗
          </a>
        </div>
      )}

      <div className="mt-8 divide-y divide-[var(--color-line)] border-y border-[var(--color-line)]">
        {ITEMS.map((item, i) => {
          const href = `/checkout?${new URLSearchParams({
            amount: item.price,
            to: MERCHANT,
            merchant: SHOP,
            ref: `bandra-chai-${i + 1}`,
            back: "/store",
          })}`;
          return (
            <div key={item.name} className="flex items-center justify-between gap-4 py-5">
              <div>
                <p className="text-[15px] font-medium">{item.name}</p>
                <p className="mt-0.5 text-[13px] text-[var(--color-muted)]">{item.note}</p>
              </div>
              <Link
                href={href}
                className="shrink-0 rounded-[var(--radius-control)] bg-[var(--color-accent)] px-4 py-2.5 text-[13px] font-medium text-white transition-colors hover:bg-[var(--color-accent-ink)]"
              >
                Pay ${item.price} with StockSwipe
              </Link>
            </div>
          );
        })}
      </div>

      <p className="mt-6 text-[13px] leading-relaxed text-[var(--color-muted)]">
        The shop is paid in USDC in the same transaction that borrows against your shares.
      </p>
    </main>
  );
}
