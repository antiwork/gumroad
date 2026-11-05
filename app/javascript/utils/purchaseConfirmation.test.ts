import { describe, it, expect } from "vitest";

import { purchaseConfirmationMessage } from "$app/utils/purchaseConfirmation";

describe("purchaseConfirmationMessage", () => {
  it("keeps the receipt sentence for paid purchases", () => {
    expect(purchaseConfirmationMessage({ free: false, sellerName: "Ana", email: "buyer@example.com" })).toBe(
      "Your purchase was successful! We sent a receipt to buyer@example.com.",
    );
  });

  it("names the seller and email for free signups", () => {
    expect(purchaseConfirmationMessage({ free: true, sellerName: "Ana", email: "buyer@example.com" })).toBe(
      "You're in! Your free signup with Ana is confirmed. We sent a confirmation to buyer@example.com.",
    );
  });

  it("omits the seller when there is none", () => {
    expect(purchaseConfirmationMessage({ free: true, sellerName: null, email: "buyer@example.com" })).toBe(
      "You're in! Your free signup is confirmed. We sent a confirmation to buyer@example.com.",
    );
  });
});
