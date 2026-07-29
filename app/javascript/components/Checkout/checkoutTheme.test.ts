import { describe, expect, it } from "vitest";

import {
  type CheckoutStyle,
  type CheckoutTheme,
  getApplicableCheckoutStyle,
  getCheckoutIndicatorStyle,
  shouldInvertNativePayPalButton,
} from "$app/components/Checkout/checkoutTheme";

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

describe("getCheckoutIndicatorStyle", () => {
  it("exposes the floored indicator without replacing the seller accent", () => {
    expect(
      getCheckoutIndicatorStyle({ ...theme("#ffffff"), accent_color: "#ffffff", indicator_color: "#949494" }),
    ).toEqual({ "--indicator": "148 148 148" });
    expect(getCheckoutIndicatorStyle(null)).toBeUndefined();
  });
});
