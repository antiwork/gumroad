// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { duplicateProduct } from "$app/data/product_dashboard";
import { ResponseError } from "$app/utils/request";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

describe("duplicateProduct", () => {
  beforeEach(() =>
    vi.stubGlobal("Routes", {
      product_duplicates_path: () => "/products/duplicates",
      product_duplicate_path: () => "/products/demo/duplicate",
    }),
  );
  afterEach(() => vi.unstubAllGlobals());

  it("stops polling when the status check answers with an error status", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(json({ success: true }))
      .mockResolvedValueOnce(json({ error: "Unauthorized" }, 401));
    vi.stubGlobal("fetch", fetchMock);

    await expect(duplicateProduct("demo", "Demo")).rejects.toBeInstanceOf(ResponseError);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});
