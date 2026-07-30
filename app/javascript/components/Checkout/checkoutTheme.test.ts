// @vitest-environment happy-dom
import { act, cleanup, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";

import { WCAG_AA_NON_TEXT, getContrastRatio, rgbToHex } from "$app/utils/color";

import {
  type CheckoutStyle,
  type CheckoutTheme,
  getApplicableCheckoutStyle,
  getCheckoutIndicatorCss,
  shouldInvertNativePayPalButton,
  useCheckoutStyle,
  useNeutralCheckoutThemeColors,
} from "$app/components/Checkout/checkoutTheme";

afterEach(cleanup);

const theme = (background_color: string): CheckoutTheme => ({
  accent_color: "#009a49",
  indicator_color: "#009a49",
  background_color,
  text_color: "#000000",
  danger_color: "#9b1c12",
  font_family: '"Roboto Mono", "ABC Favorit", monospace',
});

describe("shouldInvertNativePayPalButton", () => {
  it("uses the seller background instead of the OS theme for branded checkouts", () => {
    expect(shouldInvertNativePayPalButton(theme("#f8efe3"), true)).toBe(false);
    expect(shouldInvertNativePayPalButton(theme("#111111"), false)).toBe(true);
  });

  it("uses the OS theme for neutral checkouts", () => {
    expect(shouldInvertNativePayPalButton(null, false)).toBe(false);
    expect(shouldInvertNativePayPalButton(null, true)).toBe(true);
  });
});

describe("getApplicableCheckoutStyle", () => {
  const checkoutStyle: CheckoutStyle = {
    css: ":root { --accent: 0 154 73; }",
    seller_id: "seller-a",
    theme: theme("#f8efe3"),
  };

  it("keeps the style while every live cart item belongs to its seller", () => {
    expect(getApplicableCheckoutStyle(checkoutStyle, ["seller-a", "seller-a"])).toBe(checkoutStyle);
  });

  it("suppresses stale styling for empty, mixed, or different-seller carts", () => {
    expect(getApplicableCheckoutStyle(checkoutStyle, [])).toBeNull();
    expect(getApplicableCheckoutStyle(checkoutStyle, ["seller-a", "seller-b"])).toBeNull();
    expect(getApplicableCheckoutStyle(checkoutStyle, ["seller-b"])).toBeNull();
  });
});

describe("getCheckoutIndicatorCss", () => {
  it("exposes the floored indicator at the seller style's root scope", () => {
    expect(getCheckoutIndicatorCss({ ...theme("#ffffff"), accent_color: "#ffffff", indicator_color: "#949494" })).toBe(
      ":root { --indicator: 148 148 148; }",
    );
  });
});

describe("useCheckoutStyle", () => {
  const checkoutStyle: CheckoutStyle = {
    css: ":root { --accent: 0 154 73; }",
    seller_id: "seller-a",
    theme: theme("#f8efe3"),
  };

  const renderCheckoutStyle = (initialProps: { style: CheckoutStyle | null; cartSellerIds: string[] }) =>
    renderHook(({ style, cartSellerIds }: typeof initialProps) => useCheckoutStyle(style, cartSellerIds), {
      initialProps,
    });

  it("tracks the live cart before a purchase is captured", () => {
    const { result, rerender } = renderCheckoutStyle({ style: checkoutStyle, cartSellerIds: ["seller-a"] });
    expect(result.current[0]).toBe(checkoutStyle);

    rerender({ style: checkoutStyle, cartSellerIds: ["seller-a", "seller-b"] });
    expect(result.current[0]).toBeNull();
  });

  // The purchase empties the cart and the follow-up save nulls the prop, so anything that recomputes
  // from either one un-themes a receipt the buyer is already looking at.
  it("keeps the purchased theme after the cart empties and the prop refreshes to null", () => {
    const { result, rerender } = renderCheckoutStyle({ style: checkoutStyle, cartSellerIds: ["seller-a"] });

    act(() => result.current[1](["seller-a"]));
    rerender({ style: null, cartSellerIds: [] });

    expect(result.current[0]).toBe(checkoutStyle);
  });

  it("keeps a mixed-seller receipt neutral even while the cart still looks single-seller", () => {
    const { result } = renderCheckoutStyle({ style: checkoutStyle, cartSellerIds: ["seller-a"] });

    act(() => result.current[1](["seller-a", "seller-b"]));

    expect(result.current[0]).toBeNull();
  });

  // Payment spans awaits, so the capture the payment started with is from an older render. A cart
  // save landing mid-payment can deliver the seller's style after that render, and the receipt has
  // to show the theme the purchase resolved to rather than whatever was on screen at submit.
  it("captures the style the purchase resolved to, not the one from the submitting render", () => {
    const { result, rerender } = renderCheckoutStyle({ style: null, cartSellerIds: ["seller-a", "seller-b"] });
    const captureFromSubmittingRender = result.current[1];

    rerender({ style: checkoutStyle, cartSellerIds: ["seller-a"] });
    act(() => captureFromSubmittingRender(["seller-a"]));

    expect(result.current[0]).toBe(checkoutStyle);
  });
});

describe("useNeutralCheckoutThemeColors", () => {
  // The hook reads the live palette off the document root, so the test sets the same custom
  // properties _definitions.scss does rather than stubbing the getter.
  const withNeutralPalette = (background: string) => {
    document.documentElement.style.setProperty("--neutral-color", background === "0 0 0" ? "255 255 255" : "0 0 0");
    document.documentElement.style.setProperty("--neutral-filled", background);
    document.documentElement.style.setProperty("--neutral-border-alpha", "0.25");
    document.documentElement.style.setProperty("--neutral-accent", "255 144 232");
    document.documentElement.style.setProperty("--neutral-danger", "155 28 18");
    document.documentElement.style.setProperty("--gray-3", "0.5");
  };

  afterEach(() => document.documentElement.removeAttribute("style"));

  it("floors the stock pink indicator on the light background it fails against", () => {
    withNeutralPalette("255 255 255");

    const { result } = renderHook(() => useNeutralCheckoutThemeColors());

    // Pink is 2.02:1 on white — below the 3:1 non-text floor. #d075bd is 3.02:1, same hue.
    expect(result.current.indicator).toBe("rgb(208,117,189)");
    expect(getContrastRatio(rgbToHex(result.current.indicator.slice(4, -1)), "#ffffff")).toBeGreaterThanOrEqual(
      WCAG_AA_NON_TEXT,
    );
  });

  it("leaves the indicator alone in dark mode, where the stock pink already clears the floor", () => {
    withNeutralPalette("0 0 0");

    const { result } = renderHook(() => useNeutralCheckoutThemeColors());

    // 10.41:1 on black. Flooring here would change a colour that is already compliant.
    expect(result.current.indicator).toBe("rgb(255,144,232)");
  });

  it("does not move the fill accent, which carries text and is governed by the 4.5:1 rule instead", () => {
    withNeutralPalette("255 255 255");

    const { result } = renderHook(() => useNeutralCheckoutThemeColors());

    expect(result.current.accent).toBe("rgb(255,144,232)");
  });
});
