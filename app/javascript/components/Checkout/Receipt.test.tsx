// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { ErrorLineItemResult } from "$app/data/purchase";
import { cast } from "$app/utils/cast";

import type { CartItem } from "$app/components/Checkout/cartState";
import { LineItemResultEntry, Receipt } from "$app/components/Checkout/Receipt";
import { DomainSettingsProvider } from "$app/components/DomainSettings";

vi.mock("$app/components/Checkout/payment", () => ({
  useState: () => [
    { status: { type: "finished", paymentMethod: { type: "not-applicable" } }, email: "repeat.buyer@example.com" },
  ],
}));
vi.mock("$app/components/LoggedInUser", () => ({ useLoggedInUser: () => null }));

const domains = {
  scheme: "https",
  appDomain: "app.example.com",
  rootDomain: "example.com",
  shortDomain: "short.example.com",
  discoverDomain: "discover.example.com",
  thirdPartyAnalyticsDomain: "analytics.example.com",
  apiDomain: "api.example.com",
};

const failedResult = (overrides: Partial<Extract<ErrorLineItemResult, { error_code: string | null }>> = {}) =>
  ({
    success: false,
    error_message: "The transaction could not complete.",
    name: "Free download",
    formatted_price: null,
    error_code: "product_temporarily_blocked",
    is_tax_mismatch: false,
    card_country: null,
    ip_country: null,
    updated_product: null,
    ...overrides,
  }) satisfies ErrorLineItemResult;

const renderEntry = (result: ErrorLineItemResult) =>
  render(
    <DomainSettingsProvider value={domains}>
      <LineItemResultEntry name="Free download" result={result} />
    </DomainSettingsProvider>,
  );

describe("LineItemResultEntry for a failed line item", () => {
  beforeEach(() => {
    vi.stubGlobal("Routes", {
      login_url: ({ host, next }: { host: string; next: string }) =>
        `https://${host}/login?next=${encodeURIComponent(next)}`,
      checkout_url: ({ host }: { host: string }) => `https://${host}/checkout`,
    });
    window.history.replaceState({}, "", "/checkout?cart=1");
  });

  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it("keeps the generic message and offers the sign-in remedy when the server flags it", () => {
    renderEntry(failedResult({ owner_sign_in_remedy: true }));

    expect(screen.getByText("The transaction could not complete.")).toBeTruthy();
    expect(screen.getByText(/If you own this product,/u)).toBeTruthy();
    const link = screen.getByRole<HTMLAnchorElement>("link", { name: "sign in to Gumroad" });
    expect(link.getAttribute("href")).toBe(
      `https://app.example.com/login?next=${encodeURIComponent(window.location.href)}`,
    );
  });

  it("opens the sign-in link in the top window so a framed checkout can keep the login cookie", () => {
    renderEntry(failedResult({ owner_sign_in_remedy: true }));

    expect(screen.getByRole<HTMLAnchorElement>("link", { name: "sign in to Gumroad" }).getAttribute("target")).toBe(
      "_top",
    );
  });

  it("shows only the generic message when the server does not flag the remedy", () => {
    renderEntry(failedResult());

    expect(screen.getByText("The transaction could not complete.")).toBeTruthy();
    expect(screen.queryByText(/If you own this product,/u)).toBeNull();
    expect(screen.queryByRole("link", { name: "sign in to Gumroad" })).toBeNull();
  });

  it("shows only the generic message when the remedy flag is false", () => {
    renderEntry(failedResult({ owner_sign_in_remedy: false }));

    expect(screen.queryByRole("link", { name: "sign in to Gumroad" })).toBeNull();
  });

  it("leaves an unrelated risk error without the remedy", () => {
    renderEntry(failedResult({ error_code: "blocked_email_domain" }));

    expect(screen.getByText("The transaction could not complete.")).toBeTruthy();
    expect(screen.queryByRole("link", { name: "sign in to Gumroad" })).toBeNull();
  });

  describe("refused new-customer code", () => {
    const refusal =
      "This code is only for new customers of this store. The account or email used for this order has a previous purchase.";
    const refused = (overrides: Partial<Extract<ErrorLineItemResult, { error_code: string | null }>> = {}) =>
      failedResult({
        error_message: refusal,
        error_code: "offer_code_invalid",
        new_customer_offer_code_refused: true,
        ...overrides,
      });

    it("sends the buyer back to the cart the server kept, where the code can be removed", () => {
      renderEntry(refused({ cart_retained: true }));

      expect(screen.getByText(refusal)).toBeTruthy();
      expect(screen.getByText("Go back to checkout to continue without this code.")).toBeTruthy();
      expect(screen.getByRole<HTMLAnchorElement>("link", { name: "Back to checkout" }).getAttribute("href")).toBe(
        "https://app.example.com/checkout",
      );
    });

    it("explains the refusal without a way back when the server did not keep the cart", () => {
      renderEntry(refused());

      expect(screen.getByText(refusal)).toBeTruthy();
      expect(screen.queryByText(/Go back to checkout/u)).toBeNull();
      expect(screen.queryByRole("link", { name: "Back to checkout" })).toBeNull();
    });

    it("leaves every other failure without the way back", () => {
      renderEntry(failedResult({ error_code: "offer_code_invalid", cart_retained: true }));

      expect(screen.queryByRole("link", { name: "Back to checkout" })).toBeNull();
    });

    // A paid line is still being charged when the server decides the cart, so a later decline
    // leaves every line failed after the cart is already gone.
    it("offers no way back when every line failed but the server did not keep the cart", () => {
      const item = (name: string) => cast<CartItem>({ product: { name, is_preorder: false, free_trial: null } });
      render(
        <DomainSettingsProvider value={domains}>
          <Receipt
            results={[
              { item: item("Pro Course"), result: refused() },
              {
                item: item("Starter Pack"),
                result: failedResult({ error_message: "Your card was declined.", error_code: "card_declined" }),
              },
            ]}
            discoverUrl="https://discover.example.com"
            canBuyerSignUp={false}
          />
        </DomainSettingsProvider>,
      );

      expect(screen.getByText(refusal)).toBeTruthy();
      expect(screen.getByText("Your card was declined.")).toBeTruthy();
      expect(screen.queryByText(/Go back to checkout/u)).toBeNull();
      expect(screen.queryByRole("link", { name: "Back to checkout" })).toBeNull();
    });
  });
});
