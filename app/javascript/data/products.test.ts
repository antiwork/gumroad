import { describe, expect, it } from "vitest";

import { isRecurringProductType } from "$app/data/products";

describe("isRecurringProductType", () => {
  it("accepts the recurring product types only", () => {
    expect(isRecurringProductType("membership")).toBe(true);
    expect(isRecurringProductType("newsletter")).toBe(true);
    expect(isRecurringProductType("podcast")).toBe(true);
    expect(isRecurringProductType("digital")).toBe(false);
    expect(isRecurringProductType(undefined)).toBe(false);
  });
});
