// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { getPagedCustomers } from "$app/data/customers";
import { ResponseError } from "$app/utils/request";

describe("getPagedCustomers", () => {
  beforeEach(() => vi.stubGlobal("Routes", { customers_paged_path: () => "/customers/paged" }));
  afterEach(() => vi.unstubAllGlobals());

  it("rejects a failed search instead of returning its error body as customers", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(JSON.stringify({ success: false, error: "search failed" }), {
          status: 400,
          headers: { "content-type": "application/json" },
        }),
      ),
    );

    await expect(
      getPagedCustomers({
        page: 1,
        query: null,
        sort: null,
        products: [],
        variants: [],
        excludedProducts: [],
        excludedVariants: [],
        minimumAmount: null,
        maximumAmount: null,
        createdAfter: null,
        createdBefore: null,
        country: null,
        activeCustomersOnly: false,
        minimumLicenseUses: null,
      }).response,
    ).rejects.toBeInstanceOf(ResponseError);
  });
});
