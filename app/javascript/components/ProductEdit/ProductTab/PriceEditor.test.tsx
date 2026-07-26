// @vitest-environment happy-dom
import { describe, expect, it } from "vitest";

import { pwywMinimumNote } from "$app/components/ProductEdit/ProductTab/PriceEditor";

// The note replaces a disabled "Minimum amount" field that mirrored Amount. Sellers read the faded
// mirror as an empty box and concluded no floor was set, so the floor is now stated in words.
describe("pwywMinimumNote", () => {
  it("states the product's amount as the floor", () => {
    expect(pwywMinimumNote("usd", 300)).toBe("Customers must pay at least $3.");
  });

  it("keeps cents when the amount is not whole", () => {
    expect(pwywMinimumNote("usd", 1250)).toBe("Customers must pay at least $12.50.");
  });

  // A $0 product is the one case where paying nothing is allowed, but a customer who chooses to pay
  // still has to clear the currency's processing minimum — so the note has to say both things.
  it("explains that a free product allows paying nothing but has a processing floor", () => {
    expect(pwywMinimumNote("usd", 0)).toBe("Customers can pay nothing, or at least $0.99 if they choose to pay.");
  });

  it("uses the product's own currency, not dollars", () => {
    expect(pwywMinimumNote("gbp", 500)).toBe("Customers must pay at least £5.");
    // GBP's processing minimum differs from USD's, so the free-product floor has to follow currency.
    expect(pwywMinimumNote("gbp", 0)).toBe("Customers can pay nothing, or at least £0.59 if they choose to pay.");
  });

  // Single-unit currencies have no subdivision, so the amount must not gain a decimal point.
  it("formats single-unit currencies without cents", () => {
    expect(pwywMinimumNote("jpy", 500)).toBe("Customers must pay at least ¥500.");
  });
});
