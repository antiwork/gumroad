import { describe, expect, it } from "vitest";

import { type CheckoutTheme, shouldInvertNativePayPalButton } from "$app/components/Checkout/checkoutTheme";

const theme = (background_color: string): CheckoutTheme => ({
  accent_color: "#009a49",
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
