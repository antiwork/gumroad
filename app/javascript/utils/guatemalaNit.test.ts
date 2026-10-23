import { describe, expect, it } from "vitest";

import { isValidGuatemalaNit } from "$app/utils/guatemalaNit";

describe("isValidGuatemalaNit", () => {
  it("accepts the shapes Stripe accepts", () => {
    for (const value of [
      "805813-K",
      "805813K",
      "4829137",
      "48291374",
      "482913749",
      "4829137K",
      "4829137-K",
      "4829137-k",
      "48291374K",
      "4829137 4",
    ]) {
      expect(isValidGuatemalaNit(value)).toBe(true);
    }
  });

  it("rejects the shapes Stripe refuses", () => {
    for (const value of ["80581", "80581K", "4829-13", "482913749K", "4829137490", "", "ABCDEFGH"]) {
      expect(isValidGuatemalaNit(value)).toBe(false);
    }
  });
});
