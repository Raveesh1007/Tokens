"use client";

import { useEffect, useState } from "react";
import Link from "next/link";

import { Wordmark } from "@/components/Brand";

const REPO = "https://github.com/Raveesh1007/Tokens";

const LINKS = [
  { label: "How it works", href: "/#how" },
  { label: "Why Monad", href: "/#why" },
  { label: "Merchants", href: "/#merchants" },
  { label: "Demo shop", href: "/store" },
  { label: "Source", href: REPO },
];

export function SiteNav() {
  const [announce, setAnnounce] = useState(true);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (!open) return;
    const close = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    window.addEventListener("keydown", close);
    return () => window.removeEventListener("keydown", close);
  }, [open]);

  return (
    <>
      {announce && (
        <div className="relative bg-[var(--color-ink)] px-12 py-3 text-center text-[14px] text-white sm:text-[15px]">
          <span>StockSwipe is live on Monad testnet: pay with your stocks without selling them.</span>{" "}
          <Link href="/store" className="whitespace-nowrap font-medium underline decoration-[var(--color-accent)] decoration-2 underline-offset-4">
            Try the demo shop
          </Link>
          <button
            type="button"
            onClick={() => setAnnounce(false)}
            aria-label="Dismiss announcement"
            className="absolute right-4 top-1/2 -translate-y-1/2 rounded p-1 text-white/70 hover:text-white"
          >
            <Icon d="M6 6l12 12M18 6 6 18" />
          </button>
        </div>
      )}

      <header className="sticky top-0 z-50 border-b border-[var(--color-line)] bg-[var(--color-paper)]/90 backdrop-blur-md">
        <div className="flex items-center justify-between px-5 py-3.5 sm:px-10">
          <div className="flex items-center gap-12">
            <Wordmark size={17} />
            <nav className="hidden items-center gap-7 text-[15px] lg:flex">
              {LINKS.map((l) => (
                <a key={l.label} href={l.href} className="text-[var(--color-ink)]/80 transition-colors hover:text-[var(--color-accent)]">
                  {l.label}
                </a>
              ))}
            </nav>
          </div>

          <div className="flex items-center gap-5">
            <Link href="/portfolio" className="hidden text-[15px] text-[var(--color-ink)]/80 hover:text-[var(--color-accent)] sm:inline">
              My shares
            </Link>
            <Link
              href="/portfolio"
              className="hidden rounded-full bg-[var(--color-ink)] px-5 py-2.5 text-[15px] font-medium text-white transition-colors hover:bg-[var(--color-accent)] sm:inline-block"
            >
              Try it on testnet
            </Link>
            <button
              type="button"
              onClick={() => setOpen((o) => !o)}
              aria-label={open ? "Close menu" : "Open menu"}
              aria-expanded={open}
              className="-mr-1 p-1 text-[var(--color-ink)] lg:hidden"
            >
              {open ? <Icon d="M6 6l12 12M18 6 6 18" size={26} /> : <Icon d="M4 9h16M4 15h16" size={26} />}
            </button>
          </div>
        </div>

        {open && (
          <nav className="border-t border-[var(--color-line)] bg-[var(--color-paper)] px-5 pb-6 pt-2 lg:hidden">
            {LINKS.map((l) => (
              <a
                key={l.label}
                href={l.href}
                onClick={() => setOpen(false)}
                className="block border-b border-[var(--color-line)] py-4 text-[17px] text-[var(--color-ink)]"
              >
                {l.label}
              </a>
            ))}
            <Link
              href="/portfolio"
              className="mt-6 block rounded-full bg-[var(--color-ink)] py-3.5 text-center text-[15px] font-medium text-white"
            >
              Try it on testnet
            </Link>
          </nav>
        )}
      </header>
    </>
  );
}

function Icon({ d, size = 18 }: { d: string; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" aria-hidden>
      <path d={d} />
    </svg>
  );
}
