import { describe, expect, it } from "vitest";

import { applyWalletBillingAddressToCheckout } from "$app/components/Checkout/walletBillingAddress";

const checkout = { country: "US", state: "CA" };

const dispatched = (billingAddress: Parameters<typeof applyWalletBillingAddressToCheckout>[0]) => {
  const actions: Parameters<Parameters<typeof applyWalletBillingAddressToCheckout>[2]>[0][] = [];
  applyWalletBillingAddressToCheckout(billingAddress, checkout, (action) => actions.push(action));
  return actions;
};

describe("applyWalletBillingAddressToCheckout", () => {
  it("does nothing when the wallet shared no billing address", () => {
    expect(dispatched(null)).toEqual([]);
    expect(dispatched({ country: null, postal_code: "10001", state: "NY" })).toEqual([]);
  });

  it("adopts the wallet's country, ZIP, and state", () => {
    expect(dispatched({ country: "US", postal_code: "10001", state: "NY" })).toEqual([
      { type: "set-value", country: "US" },
      { type: "set-value", zipCode: "10001" },
      { type: "set-value", state: "NY" },
    ]);
  });

  it("clears a stale state when the wallet omits one for a non-Canadian country", () => {
    expect(dispatched({ country: "DE", postal_code: "10115", state: null })).toEqual([
      { type: "set-value", country: "DE" },
      { type: "set-value", zipCode: "10115" },
      { type: "set-value", state: "" },
    ]);
  });

  it("derives the Canadian province from the postal code when the wallet omits the state", () => {
    expect(dispatched({ country: "CA", postal_code: "H2X 1Y4", state: null })).toEqual([
      { type: "set-value", country: "CA" },
      { type: "set-value", zipCode: "H2X 1Y4" },
      { type: "set-value", state: "QC" },
    ]);
  });

  it("keeps the existing checkout state when the wallet's country matches checkout's country", () => {
    expect(dispatched({ country: "US", postal_code: null, state: null })).toEqual([
      { type: "set-value", country: "US" },
      { type: "set-value", zipCode: undefined },
      { type: "set-value", state: "CA" },
    ]);
  });

  it("falls back to GST-only Alberta for Canada when no province can be determined", () => {
    expect(dispatched({ country: "CA", postal_code: null, state: null })).toEqual([
      { type: "set-value", country: "CA" },
      { type: "set-value", zipCode: undefined },
      { type: "set-value", state: "AB" },
    ]);
  });
});
