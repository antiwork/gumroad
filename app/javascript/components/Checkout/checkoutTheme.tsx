import { type StripeElementStyleVariant, type StripeElementsOptions } from "@stripe/stripe-js";
import * as React from "react";

import { getContrastColor, hexToRgb } from "$app/utils/color";
import { getCssVariable } from "$app/utils/styles";

import { useIsDarkTheme } from "$app/components/useIsDarkTheme";
import { useRefToLatest } from "$app/components/useRefToLatest";

export type CheckoutTheme = {
  accent_color: string;
  indicator_color: string;
  background_color: string;
  text_color: string;
  danger_color: string;
  font_family: string;
};

export type CheckoutStyle = {
  css: string;
  seller_id: string;
  theme: CheckoutTheme;
};

export const getApplicableCheckoutStyle = (checkoutStyle: CheckoutStyle | null | undefined, sellerIds: string[]) =>
  checkoutStyle && sellerIds.length > 0 && sellerIds.every((sellerId) => sellerId === checkoutStyle.seller_id)
    ? checkoutStyle
    : null;

export const getCheckoutIndicatorCss = (theme: CheckoutTheme) =>
  `:root { --indicator: ${hexToRgb(theme.indicator_color)}; }`;

// The receipt must keep the theme the buyer actually checked out under. Re-deriving it live cannot
// work: the purchase empties the cart and the follow-up save refreshes `checkoutStyle` to null, so
// the receipt would un-theme itself a debounce later. `capturePurchased` snapshots the theme from
// the purchased line items instead — call it once the purchase is committed, past every early
// return, or a retried payment serves the snapshot to a cart the buyer has since changed.
// `undefined` means "no purchase yet", distinct from a purchase that resolved to no theme.
// It reads the style through a ref because payment spans awaits: the caller's closure is from the
// render that started payment, and a debounced cart save landing mid-payment can deliver the
// seller's style after that render — snapshotting the closed-over value would pin the older one.
export const useCheckoutStyle = (checkoutStyle: CheckoutStyle | null | undefined, cartSellerIds: string[]) => {
  const [purchasedStyle, setPurchasedStyle] = React.useState<CheckoutStyle | null | undefined>(undefined);
  const checkoutStyleRef = useRefToLatest(checkoutStyle);

  const capturePurchased = React.useCallback(
    (purchasedSellerIds: string[]) =>
      setPurchasedStyle(getApplicableCheckoutStyle(checkoutStyleRef.current, purchasedSellerIds)),
    [],
  );

  return [
    purchasedStyle === undefined ? getApplicableCheckoutStyle(checkoutStyle, cartSellerIds) : purchasedStyle,
    capturePurchased,
  ] as const;
};

type CheckoutThemeContext = {
  theme: CheckoutTheme | null;
  stripe_fonts_css_source: string;
};

const Context = React.createContext<CheckoutThemeContext | null>(null);

export const CheckoutThemeProvider = Context.Provider;

export const useCheckoutTheme = () => React.useContext(Context)?.theme ?? null;

export const shouldInvertNativePayPalButton = (theme: CheckoutTheme | null, isDarkTheme: boolean | null) =>
  theme ? getContrastColor(theme.background_color) === "#FFFFFF" : isDarkTheme === true;

export const useShouldInvertNativePayPalButton = () => {
  const theme = useCheckoutTheme();
  const isDarkTheme = useIsDarkTheme();
  return shouldInvertNativePayPalButton(theme, isDarkTheme);
};

const rgb = (hex: string) => hexToRgb(hex).split(" ").join(",");

export const getCheckoutThemeColors = (theme: CheckoutTheme) => {
  const text = rgb(theme.text_color);

  return {
    text: `rgb(${text})`,
    placeholder: `rgb(${text}, 0.5)`,
    background: `rgb(${rgb(theme.background_color)})`,
    border: `rgb(${text})`,
    accent: `rgb(${rgb(theme.accent_color)})`,
    indicator: `rgb(${rgb(theme.indicator_color)})`,
    danger: `rgb(${rgb(theme.danger_color)})`,
  };
};

export const useNeutralCheckoutThemeColors = () => {
  const colorScheme = useIsDarkTheme();
  const text = getCssVariable("neutral-color").trim().split(/\s+/u).join(",");
  const background = getCssVariable("neutral-filled").trim().split(/\s+/u).join(",");
  const borderAlpha = getCssVariable("neutral-border-alpha").trim();
  const accent = getCssVariable("neutral-accent").trim().split(/\s+/u).join(",");
  const danger = getCssVariable("neutral-danger").trim().split(/\s+/u).join(",");
  const placeholderAlpha = getCssVariable("gray-3").trim();

  return React.useMemo(
    () => ({
      text: `rgb(${text})`,
      placeholder: `rgb(${text}, ${placeholderAlpha})`,
      background: `rgb(${background})`,
      border: `rgb(${text}, ${borderAlpha})`,
      accent: `rgb(${accent})`,
      indicator: `rgb(${accent})`,
      danger: `rgb(${danger})`,
    }),
    [accent, background, borderAlpha, colorScheme, danger, placeholderAlpha, text],
  );
};

export const getCheckoutCardElementStyle = (theme: CheckoutTheme): StripeElementStyleVariant => {
  const colors = getCheckoutThemeColors(theme);

  return {
    fontFamily: theme.font_family,
    color: colors.text,
    iconColor: colors.placeholder,
    "::placeholder": { color: colors.placeholder },
  };
};

export const useCheckoutStripeFonts = (fallbackFont: {
  name: string;
  url: string;
}): NonNullable<StripeElementsOptions["fonts"]> => {
  const sellerFontsCssSource = React.useContext(Context)?.stripe_fonts_css_source;

  return React.useMemo(
    () => [
      { family: fallbackFont.name, src: `url(${fallbackFont.url})` },
      // Stripe cannot add font sources after Elements mounts. Load every allowed seller font up
      // front so a cart-driven theme change does not remount and erase entered payment data.
      ...(sellerFontsCssSource ? [{ cssSrc: sellerFontsCssSource }] : []),
    ],
    [fallbackFont.name, fallbackFont.url, sellerFontsCssSource],
  );
};
