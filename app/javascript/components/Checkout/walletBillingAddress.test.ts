import { describe, expect, it } from "vitest";

import { applyWalletBillingAddressToCheckout } from "$app/components/Checkout/walletBillingAddress";

const checkout = { country: "US", state: "CA", zipCode: "94103" };

const applied = (
  billingAddress: Parameters<typeof applyWalletBillingAddressToCheckout>[0],
  checkoutState: Parameters<typeof applyWalletBillingAddressToCheckout>[1] = checkout,
) => {
  const actions: Parameters<Parameters<typeof applyWalletBillingAddressToCheckout>[2]>[0][] = [];
  const taxLocationChanged = applyWalletBillingAddressToCheckout(billingAddress, checkoutState, (action) =>
    actions.push(action),
  );
  return { actions, taxLocationChanged };
};

const dispatched = (billingAddress: Parameters<typeof applyWalletBillingAddressToCheckout>[0]) =>
  applied(billingAddress).actions;

describe("applyWalletBillingAddressToCheckout", () => {
  it("does nothing when the wallet shared no billing address", () => {
    expect(applied(null)).toEqual({ actions: [], taxLocationChanged: false });
    expect(applied({ country: null, postal_code: "10001", state: "NY" })).toEqual({
      actions: [],
      taxLocationChanged: false,
    });
  });

  it("adopts the wallet's country, ZIP, and state", () => {
    expect(dispatched({ country: "US", postal_code: "10001", state: "NY" })).toEqual([
      { type: "set-wallet-billing-address", country: "US", zipCode: "10001", state: "NY" },
    ]);
  });

  it("clears a stale state when the wallet omits one for a non-Canadian country", () => {
    expect(dispatched({ country: "DE", postal_code: "10115", state: null })).toEqual([
      { type: "set-wallet-billing-address", country: "DE", zipCode: "10115", state: "" },
    ]);
  });

  it("derives the Canadian province from the postal code when the wallet omits the state", () => {
    expect(dispatched({ country: "CA", postal_code: "H2X 1Y4", state: null })).toEqual([
      { type: "set-wallet-billing-address", country: "CA", zipCode: "H2X 1Y4", state: "QC" },
    ]);
  });

  it("keeps the existing checkout state and ZIP when the wallet's country matches checkout's country", () => {
    expect(dispatched({ country: "US", postal_code: null, state: null })).toEqual([
      { type: "set-wallet-billing-address", country: "US", zipCode: "94103", state: "CA" },
    ]);
  });

  it("falls back to GST-only Alberta for Canada when no province can be determined", () => {
    expect(dispatched({ country: "CA", postal_code: null, state: null })).toEqual([
      { type: "set-wallet-billing-address", country: "CA", zipCode: undefined, state: "AB" },
    ]);
  });

  // The return value mirrors the checkout reducer's surcharge-invalidation rules — it tells the
  // wallet submission whether it must wait for a surcharges reload before charging.
  describe("tax-location change reporting", () => {
    it("reports a change when the wallet's country differs from checkout's", () => {
      expect(applied({ country: "DE", postal_code: "10115", state: null }).taxLocationChanged).toBe(true);
    });

    it("reports a change when a US wallet shares a different 5-digit ZIP", () => {
      expect(applied({ country: "US", postal_code: "10001", state: "NY" }).taxLocationChanged).toBe(true);
    });

    it("reports a change when a US wallet shares a ZIP+4 — the reducer invalidates on any US ZIP change", () => {
      expect(applied({ country: "US", postal_code: "10001-1234", state: "NY" }).taxLocationChanged).toBe(true);
    });

    it("reports a change when a Canadian wallet's province differs from checkout's", () => {
      expect(
        applied({ country: "CA", postal_code: "H2X 1Y4", state: null }, { country: "CA", state: "ON", zipCode: "" })
          .taxLocationChanged,
      ).toBe(true);
    });

    it("reports no change when the wallet's tax location matches checkout's — the submission need not wait", () => {
      expect(applied({ country: "US", postal_code: "94103", state: "CA" }).taxLocationChanged).toBe(false);
      // Same country, no ZIP shared: checkout's existing ZIP is kept, so the reducer does not
      // invalidate surcharges either.
      expect(applied({ country: "US", postal_code: null, state: null }).taxLocationChanged).toBe(false);
      expect(
        applied({ country: "CA", postal_code: "H2X 1Y4", state: "QC" }, { country: "CA", state: "QC", zipCode: "" })
          .taxLocationChanged,
      ).toBe(false);
    });

    it("does not treat a non-US postal code change as a tax-location change (mirrors the reducer's US-only ZIP rule)", () => {
      expect(
        applied({ country: "DE", postal_code: "10115", state: null }, { country: "DE", state: "", zipCode: "80331" })
          .taxLocationChanged,
      ).toBe(false);
    });
  });
});
