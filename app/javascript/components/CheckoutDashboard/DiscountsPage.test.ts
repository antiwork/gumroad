import { describe, it, expect } from "vitest";

import {
  extractParams,
  findWholeProductScopeIds,
  isQueryParams,
  ownershipScopesFromSelection,
} from "$app/components/CheckoutDashboard/DiscountsPage";

describe("extractParams", () => {
  it("restores a query containing a literal % without throwing (double-decode regression)", () => {
    // "100%" is stored in the URL as query=100%25; URLSearchParams.get()
    // already decodes it back to "100%". A second decodeURIComponent used to
    // throw URIError here and crash the page on reload.
    const params = extractParams(new URLSearchParams("?query=100%25"));
    expect(params.query).toBe("100%");
  });

  it("returns an empty query when the param is absent", () => {
    expect(extractParams(new URLSearchParams("")).query).toBe("");
  });

  it("parses sort and page params", () => {
    const params = extractParams(new URLSearchParams("?column=revenue&sort=desc&page=3"));
    expect(params.sort).toEqual({ key: "revenue", direction: "desc" });
    expect(params.page).toBe(3);
  });

  it("ignores unknown sort columns", () => {
    expect(extractParams(new URLSearchParams("?column=bogus&sort=desc")).sort).toBeNull();
  });
});

describe("findWholeProductScopeIds", () => {
  it("marks a product scoped to the whole product, whose menu row react-select hides", () => {
    expect(findWholeProductScopeIds([{ id: "1" }, { id: "2" }], { "2": ["opt-a"] })).toEqual(new Set(["1"]));
  });

  it("keeps a product visible when its scope lists options, including an empty list", () => {
    expect(findWholeProductScopeIds([{ id: "1" }, { id: "2" }], { "1": ["opt-a"], "2": [] })).toEqual(new Set());
  });
});

describe("ownershipScopesFromSelection", () => {
  const targets = {
    "1": { productId: "1", kind: "product" as const },
    "2:opt-a": { productId: "2", optionId: "opt-a", kind: "option" as const },
    "2:opt-b": { productId: "2", optionId: "opt-b", kind: "option" as const },
    "3:deleted": { productId: "3", kind: "deleted" as const },
  };

  it("keeps a product row as a whole-product requirement", () => {
    expect(ownershipScopesFromSelection(["1"], targets, {})).toEqual({ productIds: ["1"], optionIdsByProduct: {} });
  });

  it("records the picked options under their product", () => {
    expect(ownershipScopesFromSelection(["2:opt-a", "2:opt-b"], targets, {})).toEqual({
      productIds: [],
      optionIdsByProduct: { "2": ["opt-a", "opt-b"] },
    });
  });

  it("carries a product row and another product's option row together", () => {
    expect(ownershipScopesFromSelection(["1", "2:opt-a"], targets, {})).toEqual({
      productIds: ["1"],
      optionIdsByProduct: { "2": ["opt-a"] },
    });
  });

  it("keeps the recorded options behind a deleted row", () => {
    expect(ownershipScopesFromSelection(["3:deleted"], targets, { "3": ["opt-gone"] })).toEqual({
      productIds: [],
      optionIdsByProduct: { "3": ["opt-gone"] },
    });
  });

  it("drops selections the menu no longer knows about", () => {
    expect(ownershipScopesFromSelection(["missing"], targets, {})).toEqual({ productIds: [], optionIdsByProduct: {} });
  });
});

describe("isQueryParams", () => {
  it("accepts the state the page pushes, with or without a sort", () => {
    expect(isQueryParams({ sort: { key: "revenue", direction: "desc" }, query: "black", page: 2 })).toBe(true);
    expect(isQueryParams({ sort: null, query: null, page: null })).toBe(true);
  });

  it("rejects state another page left in history", () => {
    expect(isQueryParams(null)).toBe(false);
    expect(isQueryParams({ sort: { key: "price", direction: "desc" }, query: null, page: null })).toBe(false);
    expect(isQueryParams({ sort: null, query: null })).toBe(false);
    expect(isQueryParams({ sort: null, query: 1, page: null })).toBe(false);
  });
});
