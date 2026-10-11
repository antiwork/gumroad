import { describe, expect, it } from "vitest";

import { isOfferCode } from "$app/utils/offer-code";

describe("isOfferCode", () => {
  it("accepts fixed and percent discounts", () => {
    expect(isOfferCode({ type: "fixed", cents: 500 })).toBe(true);
    expect(isOfferCode({ type: "percent", percents: 20 })).toBe(true);
  });

  it("rejects a discount whose amount does not match its type", () => {
    expect(isOfferCode({ type: "fixed", percents: 20 })).toBe(false);
    expect(isOfferCode({ type: "percent", cents: "20" })).toBe(false);
    expect(isOfferCode(null)).toBe(false);
  });
});
