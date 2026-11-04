import { Fragment } from "react";
import Link from "next/link";

import { Portal } from "@/components/Brand";
import { HoldingsField } from "@/components/HoldingsField";

const CUE = { claim: 120, shares: 500, word: 95, sub: 900, action: 1120 } as const;

export function Hero() {
  return (
    <section className="portal-dark noise relative flex items-center overflow-hidden text-white lg:min-h-[calc(100vh-7rem)]">
      <div className="absolute inset-0 overflow-hidden">
        <Portal />
        <HoldingsField />
      </div>

      <div className="relative mx-auto w-full max-w-2xl px-6 py-32 text-center sm:py-36 lg:py-20">
        <p className="eyebrow settle text-[var(--color-accent-bg)]" style={{ animationDelay: "60ms" }}>
          Tokenized stocks · Monad testnet
        </p>
        <h1 className="mx-auto mt-5 max-w-[14ch] text-[clamp(2.4rem,5.5vw,3.9rem)] font-semibold leading-[1.02] tracking-[-0.03em]">
          <Words text="Swipe your stocks" from={CUE.claim} />{" "}
          <Words text="without selling them" from={CUE.shares} className="text-[var(--color-accent-bg)]" />
        </h1>

        <p
          className="settle mx-auto mt-5 max-w-[34ch] text-[16px] leading-relaxed text-white/70"
          style={{ animationDelay: `${CUE.sub}ms` }}
        >
          Borrow against your tokenized stocks right at the checkout. One transaction on Monad, settled in about a second.
        </p>

        <div className="settle mt-8 flex flex-wrap justify-center gap-3" style={{ animationDelay: `${CUE.action}ms` }}>
          <Link
            href="/portfolio"
            className="rounded-[var(--radius-control)] bg-[var(--color-accent)] px-6 py-3.5 text-[15px] font-medium text-white transition-colors hover:bg-[var(--color-accent-ink)]"
          >
            Try it on testnet
          </Link>
          <Link
            href="/store"
            className="rounded-[var(--radius-control)] border border-white/20 bg-white/5 px-6 py-3.5 text-[15px] font-medium text-white backdrop-blur transition-colors hover:border-white/50"
          >
            Visit the demo shop
          </Link>
        </div>
      </div>
    </section>
  );
}

function Words({ text, from, className = "" }: { text: string; from: number; className?: string }) {
  return text.split(" ").map((word, i) => (
    <Fragment key={`${word}-${i}`}>
      {i > 0 && " "}
      <span className={`settle inline-block ${className}`} style={{ animationDelay: `${from + i * CUE.word}ms` }}>
        {word}
      </span>
    </Fragment>
  ));
}
