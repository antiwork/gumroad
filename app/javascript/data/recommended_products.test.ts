import { describe, expect, it } from "vitest";

import { isRecommendationType } from "$app/data/recommended_products";

describe("isRecommendationType", () => {
  it("accepts the recommendation types only", () => {
    expect(isRecommendationType("own_products")).toBe(true);
    expect(isRecommendationType("everything")).toBe(false);
    expect(isRecommendationType(undefined)).toBe(false);
  });
});
