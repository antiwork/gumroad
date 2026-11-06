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
    "1": { productId: "1", optionIds: [], kind: "product" as const },
    "2:opt-a": { productId: "2", optionIds: ["opt-a"], kind: "option" as const },
    "2:opt-b": { productId: "2", optionIds: ["opt-b"], kind: "option" as const },
    "2:deleted": { productId: "2", optionIds: ["opt-gone"], kind: "deleted" as const },
  };

  it("keeps a product row as a whole-product requirement", () => {
    expect(ownershipScopesFromSelection(["1"], targets)).toEqual({ productIds: ["1"], optionIdsByProduct: {} });
  });

  it("records the picked options under their product", () => {
    expect(ownershipScopesFromSelection(["2:opt-a", "2:opt-b"], targets)).toEqual({
      productIds: [],
      optionIdsByProduct: { "2": ["opt-a", "opt-b"] },
    });
  });

  it("carries a product row and another product's option row together", () => {
    expect(ownershipScopesFromSelection(["1", "2:opt-a"], targets)).toEqual({
      productIds: ["1"],
      optionIdsByProduct: { "2": ["opt-a"] },
    });
  });

  it("keeps deleted options next to live options of the same product", () => {
    expect(ownershipScopesFromSelection(["2:opt-a", "2:deleted"], targets)).toEqual({
      productIds: [],
      optionIdsByProduct: { "2": ["opt-a", "opt-gone"] },
    });
  });

  it("drops selections the menu no longer knows about", () => {
    expect(ownershipScopesFromSelection(["missing"], targets)).toEqual({ productIds: [], optionIdsByProduct: {} });
  });

  it("narrows a whole-product row to the option added for that product", () => {
    expect(
      ownershipScopesFromSelection(
        ["1", "2", "2:opt-a"],
        { ...targets, "2": { productId: "2", optionIds: [], kind: "product" } },
        "2:opt-a",
      ),
    ).toEqual({
      productIds: ["1"],
      optionIdsByProduct: { "2": ["opt-a"] },
    });
  });

  it("widens a product's option rows to the whole product when its product row is added", () => {
    expect(
      ownershipScopesFromSelection(
        ["2:opt-a", "2:deleted", "2"],
        { ...targets, "2": { productId: "2", optionIds: [], kind: "product" } },
        "2",
      ),
    ).toEqual({
      productIds: ["2"],
      optionIdsByProduct: {},
    });
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
