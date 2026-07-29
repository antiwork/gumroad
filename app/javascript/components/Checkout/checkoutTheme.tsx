import { type StripeElementStyleVariant, type StripeElementsOptions } from "@stripe/stripe-js";
import * as React from "react";

import { getContrastColor, hexToRgb } from "$app/utils/color";
import { getCssVariable } from "$app/utils/styles";

import { useIsDarkTheme } from "$app/components/useIsDarkTheme";
export type CheckoutTheme = {
  accent_color: string;
  indicator_color: string;
  background_color: string;
  text_color: string;
  danger_color: string;
  font_family: string;
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
    // Focus rings and the selected-method marker sit on the seller's background with no text on
    // them, so they use the 3:1-floored colour rather than the saved accent, which can match it.
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
