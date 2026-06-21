import { describe, it, expect } from "vitest";

import { reorderShownIds } from "$app/components/Profile/reorderShownIds";

describe("reorderShownIds", () => {
  it("keeps ids missing from the new order at the end instead of moving them to the front", () => {
    expect(reorderShownIds(["a", "b", "c", "x", "y"], ["c", "a", "b"])).toEqual(["c", "a", "b", "x", "y"]);
  });

  it("returns an unchanged order when the available ids already match the new order", () => {
    const shown = ["a", "b", "c", "x", "y"];
    expect(reorderShownIds(shown, ["a", "b", "c"])).toEqual(shown);
  });

  it("preserves the relative order of missing ids", () => {
    expect(reorderShownIds(["x", "a", "y", "b"], ["b", "a"])).toEqual(["b", "a", "x", "y"]);
  });
});
