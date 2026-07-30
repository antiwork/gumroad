// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { type CheckoutTheme, CheckoutThemeProvider } from "$app/components/Checkout/checkoutTheme";
import { CreditCardInput } from "$app/components/Checkout/CreditCardInput";

const stripeRender = vi.hoisted<{
  cardOptions: { style?: { base?: unknown } } | null;
  elementsOptions: { fonts?: unknown } | null;
}>(() => ({ cardOptions: null, elementsOptions: null }));

const stripeFontsCssSource =
  "https://fonts.googleapis.com/css2?family=Domine:wght@400;600&family=Inter:wght@400;600&family=Merriweather:wght@400;600&family=Roboto%20Mono:wght@400;600&family=Roboto%20Slab:wght@400;600&display=swap";
let prefersDark = false;

vi.mock("@stripe/react-stripe-js", () => ({
  CardElement: ({ options }: { options: { style?: { base?: unknown } } }) => {
    stripeRender.cardOptions = options;
    return null;
  },
  Elements: ({ children, options }: { children: React.ReactNode; options: { fonts?: unknown } }) => {
    stripeRender.elementsOptions = options;
    return children;
  },
}));

vi.mock("$app/utils/stripe_loader", () => ({ getStripeInstance: vi.fn() }));
vi.mock("$app/utils/styles", () => ({
  getCssVariable: (name: string) =>
    ({
      "gray-3": "0.5",
      "neutral-accent": "255 144 232",
      "neutral-border-alpha": prefersDark ? "0.35" : "1",
      "neutral-color": prefersDark ? "221 221 221" : "0 0 0",
      "neutral-danger": "220 52 30",
      "neutral-filled": prefersDark ? "0 0 0" : "255 255 255",
    })[name] ?? "9 9 9",
}));
vi.mock("$app/components/DesignSettings", () => ({ useFont: () => ({ name: "Inter", url: "inter.woff2" }) }));
vi.mock("$app/components/ui/Fieldset", () => ({
  Fieldset: ({ children }: { children: React.ReactNode }) => children,
  FieldsetTitle: ({ children }: { children: React.ReactNode }) => children,
}));
vi.mock("$app/components/ui/InputGroup", () => ({
  InputGroup: ({ children }: { children: React.ReactNode }) => children,
}));
vi.mock("$app/components/ui/Label", () => ({
  Label: ({ children }: { children: React.ReactNode }) => children,
}));

describe("CreditCardInput", () => {
  beforeEach(() => {
    prefersDark = false;
    vi.stubGlobal(
      "matchMedia",
      vi.fn(() => ({
        matches: prefersDark,
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
      })),
    );
    stripeRender.cardOptions = null;
    stripeRender.elementsOptions = null;
  });

  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it("uses the seller theme instead of CSS sampled before the Inertia head update", () => {
    const theme: CheckoutTheme = {
      accent_color: "#009a49",
      indicator_color: "#009a49",
      background_color: "#f8efe3",
      text_color: "#000000",
      danger_color: "#9b1c12",
      font_family: '"Roboto Mono", "ABC Favorit", monospace',
    };

    const { rerender } = render(
      <CheckoutThemeProvider value={{ theme, stripe_fonts_css_source: stripeFontsCssSource }}>
        <CreditCardInput savedCreditCard={null} onReady={vi.fn()} useSavedCard={false} setUseSavedCard={vi.fn()} />
      </CheckoutThemeProvider>,
    );

    expect(stripeRender.elementsOptions?.fonts).toEqual([
      { family: "Inter", src: "url(inter.woff2)" },
      { cssSrc: stripeFontsCssSource },
    ]);
    expect(stripeRender.cardOptions?.style?.base).toEqual({
      fontFamily: theme.font_family,
      color: "rgb(0,0,0)",
      iconColor: "rgb(0,0,0, 0.5)",
      "::placeholder": { color: "rgb(0,0,0, 0.5)" },
    });

    rerender(
      <CheckoutThemeProvider value={{ theme: null, stripe_fonts_css_source: stripeFontsCssSource }}>
        <CreditCardInput savedCreditCard={null} onReady={vi.fn()} useSavedCard={false} setUseSavedCard={vi.fn()} />
      </CheckoutThemeProvider>,
    );
    expect(stripeRender.cardOptions?.style?.base).toEqual({
      fontFamily: 'Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
      color: "rgb(0,0,0)",
      iconColor: "rgb(0,0,0, 0.5)",
      "::placeholder": { color: "rgb(0,0,0, 0.5)" },
    });
  });
});
