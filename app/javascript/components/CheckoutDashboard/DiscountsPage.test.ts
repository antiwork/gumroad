import { describe, it, expect } from "vitest";

import { extractParams } from "$app/components/CheckoutDashboard/DiscountsPage";

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
