// @vitest-environment happy-dom
import { afterEach, describe, expect, it } from "vitest";

import { readBuyerCurrencyPreference, writeBuyerCurrencyPreference } from "$app/components/Checkout/payment";

afterEach(() => {
  document.cookie = "gumroad_buyer_currency=; path=/; max-age=0";
  window.history.replaceState({}, "", "/checkout");
});

describe("readBuyerCurrencyPreference", () => {
  it("reads a valid cookie", () => {
    writeBuyerCurrencyPreference("gbp");
    expect(readBuyerCurrencyPreference()).toBe("gbp");
  });

  it("does not throw on a malformed percent-encoded cookie", () => {
    document.cookie = "gumroad_buyer_currency=%E0%A4%A; path=/";
    expect(readBuyerCurrencyPreference()).toBeNull();
  });
});
