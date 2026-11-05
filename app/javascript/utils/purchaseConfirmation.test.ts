import { describe, it, expect } from "vitest";

import { purchaseConfirmationMessage } from "$app/utils/purchaseConfirmation";

describe("purchaseConfirmationMessage", () => {
  it("keeps the receipt sentence for paid purchases", () => {
    expect(purchaseConfirmationMessage({ free: false, creatorName: "Ana", email: "a@b.co" })).toBe(
      "Your purchase was successful! We sent a receipt to a@b.co.",
    );
  });

  it("names the creator and email for free signups", () => {
    expect(purchaseConfirmationMessage({ free: true, creatorName: "Ana", email: "a@b.co" })).toBe(
      "You're in! Your free signup with Ana is confirmed. We sent a confirmation to a@b.co.",
    );
  });

  it("omits the creator when there is none", () => {
    expect(purchaseConfirmationMessage({ free: true, creatorName: null, email: "a@b.co" })).toBe(
      "You're in! Your free signup is confirmed. We sent a confirmation to a@b.co.",
    );
  });
});
