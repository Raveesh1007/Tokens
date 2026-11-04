import Link from "next/link";

import { BuiltOnMonad, Chevrons, Wordmark } from "@/components/Brand";
import { Hero } from "@/components/Hero";
import { SiteNav } from "@/components/SiteNav";
import { TransactionDiagram } from "@/components/TransactionDiagram";

export default function LandingPage() {
  return (
    <div className="bg-[var(--color-paper)]">
      <SiteNav />
      <Hero />
      <Problem />
      <Mechanism />
      <WhyMonad />
      <ForMerchants />
      <Proof />
      <Outro />
      <Footer />
    </div>
  );
}

function Problem() {
  return (
    <Section>
      <Label>The problem</Label>
      <Heading first="Selling is the only option today" second="It shouldn't be" />

      <div className="mt-8 grid gap-10 md:grid-cols-2">
        <div className="max-w-[46ch] space-y-4 text-[16px] leading-relaxed text-[var(--color-muted)]">
          <p>
            Tokenized stocks like xStocks finally let anyone, anywhere, own NVIDIA or Apple on-chain. But the moment you
            need cash, you have to sell: a taxable event, and the upside you believed in is gone.
          </p>
          <p>
            The fix already exists. Securities-backed lending is how wealthy people fund their lives without selling
            anything. It needs a private bank, a six-figure minimum and days of paperwork.
          </p>
          <p className="text-[var(--color-ink)]">
            Most of the world has no credit bureau, so it has no consumer credit at all. Your portfolio can be the
            underwriting instead.
          </p>
        </div>

        <ul className="space-y-3 text-[16px] leading-relaxed">
          {[
            "What if your portfolio could pay for chai?",
            "What if borrowing against it took one tap?",
            "What if the loan and the payment were the same transaction?",
          ].map((line) => (
            <li key={line} className="border-b border-[var(--color-line)] pb-3 italic text-[var(--color-muted)]">
              {line}
            </li>
          ))}
        </ul>
      </div>
    </Section>
  );
}

function Mechanism() {
  const steps = [
    {
      n: "01",
      title: "You reach the checkout",
      text: "A shop shows a Pay with StockSwipe button. Connect MetaMask on Monad, nothing else to set up.",
    },
    {
      n: "02",
      title: "StockSwipe prices it against your shares",
      text: "The vault's price feed decides how many shares a $5 payment needs at 35% loan-to-value.",
    },
    {
      n: "03",
      title: "One transaction does everything",
      text: "Your shares are locked, USDC is borrowed against them, and the shop is paid. All of it settles together or not at all.",
    },
    {
      n: "04",
      title: "You still own the shares",
      text: "They are held as security, not sold. Repay whenever and they come back to your wallet.",
    },
  ];

  return (
    <Section bordered id="how">
      <Label>How it works</Label>
      <Heading first="Four steps for you" second="One transaction underneath" />

      <div className="mt-10 divide-y divide-[var(--color-line)] border-y border-[var(--color-line)]">
        {steps.map((step) => (
          <div key={step.n} className="grid gap-3 py-7 md:grid-cols-[4rem_1fr]">
            <span className="eyebrow pt-1 text-[var(--color-accent)]">{step.n}</span>
            <div>
              <h3 className="text-[19px] font-medium tracking-[-0.01em]">{step.title}</h3>
              <p className="mt-2 max-w-[56ch] text-[16px] leading-relaxed text-[var(--color-muted)]">{step.text}</p>
            </div>
          </div>
        ))}
      </div>

      <TransactionDiagram />
    </Section>
  );
}

function WhyMonad() {
  return (
    <section id="why" className="direction-dark noise relative overflow-hidden text-white">
      <Chevrons />
      <div className="mx-auto max-w-5xl px-6 py-16 sm:py-20 md:py-24">
        <p className="eyebrow text-[var(--color-accent-bg)]">Why Monad</p>
        <h2 className="mt-5 max-w-[20ch] text-[clamp(1.75rem,4vw,2.75rem)] font-semibold leading-[1.08] tracking-[-0.03em]">
          Checkout speed
          <span className="block text-[var(--color-accent-bg)]">with on-chain settlement</span>
        </h2>

        <div className="mt-8 grid gap-10 md:grid-cols-2">
          <p className="max-w-[46ch] text-[16px] leading-relaxed text-white/70">
            There is no moment where you have taken on debt but the shop has not been paid. Off-chain those are two
            systems and a reconciliation problem. On Monad it is one contract call that lands in about a second, for a
            fraction of a cent.
          </p>

          <dl className="space-y-5">
            {[
              ["About a second to final", "Fast enough to stand at a counter and wait for it."],
              ["Gas measured in fractions of a cent", "A $5 payment can afford its own transaction fee."],
              ["Open at 3am on a Sunday", "Tokenized stocks trade when the stock market is shut."],
              ["No credit file required", "The collateral is the underwriting, so there is nothing to score."],
            ].map(([term, def]) => (
              <div key={term} className="border-b border-white/10 pb-5">
                <dt className="text-[15px] font-medium">{term}</dt>
                <dd className="mt-1 max-w-[46ch] text-[15px] leading-relaxed text-white/60">{def}</dd>
              </div>
            ))}
          </dl>
        </div>
      </div>
    </section>
  );
}

function ForMerchants() {
  return (
    <Section id="merchants">
      <Label>For merchants</Label>
      <Heading first="StockSwipe is not a destination" second="It is a payment button" />

      <p className="mt-8 max-w-[52ch] text-[16px] leading-relaxed text-[var(--color-muted)]">
        Any shop can take payment from a customer&apos;s stock portfolio with one link. The money arrives as USDC in the
        shop&apos;s wallet, in the same transaction.
      </p>

      <div className="mt-7 overflow-hidden rounded-[var(--radius-card)] bg-[var(--color-ink)] shadow-[var(--shadow-raise)]">
        <div className="flex items-center gap-2 border-b border-white/10 px-5 py-3">
          <span className="h-2.5 w-2.5 rounded-full bg-white/15" />
          <span className="h-2.5 w-2.5 rounded-full bg-white/15" />
          <span className="h-2.5 w-2.5 rounded-full bg-white/15" />
          <span className="ml-2 font-mono text-[12px] text-[var(--color-code-punct)]">checkout.html</span>
        </div>
        <pre className="overflow-x-auto px-4 py-4 font-mono text-[11.5px] leading-[1.75] sm:px-5 sm:py-5 sm:text-[13px]">
          <code>
            <C k="punct">&lt;</C>
            <C k="tag">a</C> <C k="attr">href</C>
            <C k="punct">=</C>
            <C k="str">&quot;https://stockswipe.app/checkout?amount=</C>
            <C k="num">5</C>
            <C k="str">&amp;to=0xShop&amp;merchant=Bandra+Chai+Co.&quot;</C>
            <C k="punct">&gt;</C>
            {"\n  "}
            <span className="text-white">Pay with StockSwipe</span>
            {"\n"}
            <C k="punct">&lt;/</C>
            <C k="tag">a</C>
            <C k="punct">&gt;</C>
          </code>
        </pre>
      </div>
    </Section>
  );
}

function C({ k, children }: { k: "tag" | "attr" | "str" | "num" | "punct"; children: React.ReactNode }) {
  const color = {
    tag: "var(--color-code-tag)",
    attr: "var(--color-code-attr)",
    str: "var(--color-code-string)",
    num: "var(--color-code-number)",
    punct: "var(--color-code-punct)",
  }[k];
  return <span style={{ color }}>{children}</span>;
}

function Proof() {
  return (
    <Section bordered>
      <Label>What is actually built</Label>
      <Heading first="Not a mockup" second="A verified contract on Monad" />

      <p className="mt-8 max-w-[54ch] text-[16px] leading-relaxed text-[var(--color-muted)]">
        StockSwipe&apos;s vault is its own Solidity contract: it holds the collateral, lends the USDC and pays the shop in a
        single call. Anyone can liquidate a position that falls past 65%, so the vault stays solvent without us.
      </p>

      <div className="mt-9 grid gap-px overflow-hidden rounded-[var(--radius-card)] border border-[var(--color-line)] bg-[var(--color-line)] sm:grid-cols-3">
        {[
          ["1", "transaction to lock, borrow and pay"],
          ["35%", "maximum loan-to-value"],
          ["65%", "liquidation threshold, your safety margin"],
        ].map(([figure, caption]) => (
          <div key={caption} className="bg-[var(--color-white)] p-6">
            <p className="tabular text-[34px] font-semibold tracking-[-0.03em] text-[var(--color-accent)]" style={{ fontFamily: "var(--font-display)" }}>
              {figure}
            </p>
            <p className="mt-1 text-[14px] leading-relaxed text-[var(--color-muted)]">{caption}</p>
          </div>
        ))}
      </div>

      <p className="mt-6 text-[14px] leading-relaxed text-[var(--color-muted)]">
        The cap is deliberate. Tokenized stocks trade 24/7 but the underlying market does not, so a position opened on
        Saturday can gap at Monday&apos;s open. The gap between 35% and 65% is your margin.
      </p>
    </Section>
  );
}

function Outro() {
  return (
    <section className="gradient-light noise relative overflow-hidden border-t border-[var(--color-line)]">
      <div className="mx-auto max-w-5xl px-6 py-28 text-center">
        <h2 className="mx-auto max-w-[18ch] text-[clamp(2.2rem,5vw,3.5rem)] font-semibold leading-[1.02] tracking-[-0.03em]">
          Spend the value.
          <span className="block text-[var(--color-accent)]">Keep the upside.</span>
        </h2>
        <div className="mt-9 flex justify-center">
          <Link
            href="/portfolio"
            className="rounded-[var(--radius-control)] bg-[var(--color-accent)] px-6 py-3.5 text-[15px] font-medium text-white transition-colors hover:bg-[var(--color-accent-ink)]"
          >
            Try it on testnet
          </Link>
        </div>
      </div>
    </section>
  );
}

function Footer() {
  return (
    <footer className="bg-[var(--color-ink)] text-white/50">
      <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-6 px-6 py-10 text-[13px]">
        <div className="space-y-3">
          <Wordmark />
          <p>Spend your stocks without selling them.</p>
        </div>
        <div className="space-y-3 sm:text-right">
          <BuiltOnMonad />
          <p>
            Design adapted from{" "}
            <a href="https://github.com/Nnadijoshuac/draw" className="underline hover:text-white">
              Draw
            </a>{" "}
            (MIT)
          </p>
        </div>
      </div>
    </footer>
  );
}

function Section({ children, bordered, id }: { children: React.ReactNode; bordered?: boolean; id?: string }) {
  return (
    <section id={id} className={bordered ? "border-t border-[var(--color-line)]" : undefined}>
      <div className="mx-auto max-w-5xl px-6 py-16 sm:py-20 md:py-24">{children}</div>
    </section>
  );
}

function Label({ children }: { children: React.ReactNode }) {
  return <p className="eyebrow text-[var(--color-accent)]">{children}</p>;
}

function Heading({ first, second }: { first: string; second: string }) {
  return (
    <h2 className="mt-5 max-w-[20ch] text-[clamp(1.9rem,4vw,3rem)] font-semibold leading-[1.04] tracking-[-0.03em]">
      {first}
      <span className="block text-[var(--color-muted)]">{second}</span>
    </h2>
  );
}
