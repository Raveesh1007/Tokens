import Image from "next/image";
import Link from "next/link";

export function Mark({ size = 20 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 20 20" aria-hidden>
      <rect width="20" height="20" rx="6" fill="var(--color-accent)" />
      <rect x="0" y="6.5" width="20" height="3" fill="white" opacity="0.9" />
      <rect x="4" y="13" width="6" height="2" rx="1" fill="white" opacity="0.7" />
    </svg>
  );
}

export function Wordmark({ size = 16, href = "/" }: { size?: number; href?: string }) {
  return (
    <Link href={href} className="flex items-center gap-2 font-semibold tracking-[-0.02em]" style={{ fontSize: size }}>
      <Mark size={Math.round(size * 1.25)} />
      <span style={{ fontFamily: "var(--font-display)" }}>StockSwipe</span>
    </Link>
  );
}

export function BuiltOnMonad({ dark = true }: { dark?: boolean }) {
  return (
    <a href="https://monad.xyz" className="inline-flex items-center gap-3" aria-label="Built on Monad">
      <span className={`eyebrow ${dark ? "text-white/50" : "text-[var(--color-muted)]"}`}>Built on</span>
      <Image
        src={dark ? "/brand/monad-logo-inverted.svg" : "/brand/monad-logo.svg"}
        alt="Monad"
        width={106}
        height={20}
      />
    </a>
  );
}

const RINGS = [120, 210, 310, 420, 540, 680];

export function Portal() {
  return (
    <svg
      aria-hidden
      className="portal-in pointer-events-none absolute left-1/2 top-1/2 h-[1400px] w-[1400px] -translate-x-1/2 -translate-y-1/2"
      viewBox="-700 -700 1400 1400"
    >
      {RINGS.map((r, i) => (
        <rect
          key={r}
          x={-r / 2}
          y={-r / 2}
          width={r}
          height={r}
          rx={r * 0.32}
          transform="rotate(45)"
          fill="none"
          stroke="white"
          strokeOpacity={0.34 - i * 0.05}
          strokeWidth={i === 0 ? 2 : 1}
        />
      ))}
    </svg>
  );
}

export function Chevrons() {
  return (
    <svg aria-hidden className="pointer-events-none absolute inset-0 h-full w-full" viewBox="0 0 1000 500" preserveAspectRatio="xMaxYMid slice">
      <defs>
        <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="var(--color-pink)" />
          <stop offset="0.5" stopColor="var(--color-accent)" />
          <stop offset="1" stopColor="var(--color-cyan)" />
        </linearGradient>
      </defs>
      {[560, 700, 840].map((x, i) => (
        <path
          key={x}
          d={`M ${x} -40 Q ${x + 220} 250 ${x} 540`}
          fill="none"
          stroke="url(#rim)"
          strokeWidth={2}
          strokeOpacity={0.5 - i * 0.12}
        />
      ))}
    </svg>
  );
}
