import { CurrencyCode, currencyCodeList } from "$app/utils/currency";

const BUYER_CURRENCY_COOKIE = "gumroad_buyer_currency";

const isKnownCurrencyCode = (code: string): code is CurrencyCode => currencyCodeList.some((known) => known === code);

export function readBuyerCurrencyPreference(): CurrencyCode | null {
  if (typeof window === "undefined") return null;
  const fromUrl = new URL(window.location.href).searchParams.get("currency");
  const raw = fromUrl
    ? fromUrl.toLowerCase()
    : (() => {
        const match = document.cookie.match(/(?:^|; )gumroad_buyer_currency=([^;]*)/u);
        const value = match?.[1];
        if (!value) return null;
        try {
          return decodeURIComponent(value).toLowerCase();
        } catch {
          return null;
        }
      })();
  return raw && isKnownCurrencyCode(raw) ? raw : null;
}

export function writeBuyerCurrencyPreference(code: string | null) {
  if (typeof window === "undefined") return;
  if (!code) {
    document.cookie = `${BUYER_CURRENCY_COOKIE}=; path=/; max-age=0`;
    return;
  }
  document.cookie = `${BUYER_CURRENCY_COOKIE}=${encodeURIComponent(code)}; path=/; max-age=31536000; SameSite=Lax`;
}
