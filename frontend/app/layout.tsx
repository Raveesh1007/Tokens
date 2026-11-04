import type { Metadata } from "next";
import { Inter, Inter_Tight, Roboto_Mono } from "next/font/google";
import "./globals.css";

const inter = Inter({ subsets: ["latin"], variable: "--font-inter" });
// Britti Sans is Monad's headline face but isn't freely licensed; Inter Tight is the closest open substitute.
const display = Inter_Tight({ subsets: ["latin"], variable: "--font-display-face" });
const mono = Roboto_Mono({ subsets: ["latin"], variable: "--font-roboto-mono" });

export const metadata: Metadata = {
  title: "StockSwipe — spend your stocks without selling them",
  description: "Pay at checkout with tokenized stocks as collateral, in one transaction on Monad.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${inter.variable} ${display.variable} ${mono.variable}`}>
      <body className="min-h-screen antialiased">{children}</body>
    </html>
  );
}
