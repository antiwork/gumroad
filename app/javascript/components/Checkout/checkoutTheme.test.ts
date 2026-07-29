// @vitest-environment happy-dom
import { act, cleanup, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";

import {
  type CheckoutStyle,
  type CheckoutTheme,
  getApplicableCheckoutStyle,
  getCheckoutIndicatorCss,
  shouldInvertNativePayPalButton,
  useCheckoutStyle,
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
});
