import { describe, expect, it, vi } from "vitest";

import { AbortError, ResponseError } from "$app/utils/request";

vi.stubGlobal("Routes", {
  products_affiliated_index_path: () => "/products/affiliated",
  products_affiliated_path: (id: string) => `/products/affiliated/${id}`,
});

const { AffiliationAlreadyRemovedError, getPagedAffiliatedProducts, removeSelfAsAffiliate } = await import(
  "$app/data/affiliated_products"
);

// A response whose body only resolves when the test says so, so a cancellation can land in the gap
// between fetch resolving and the body being read — the window where the platform AbortError is
// raised outside request()'s conversion boundary.
const responseWithPendingBody = (signal: AbortSignal | null | undefined) =>
  new Response(
    new ReadableStream({
      start(controller) {
        signal?.addEventListener("abort", () => controller.error(new DOMException("aborted", "AbortError")));
      },
    }),
    { headers: { "content-type": "application/json" } },
  );

describe("getPagedAffiliatedProducts", () => {
  it("converts an abort during body parsing into the application AbortError", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn((_url: string, init: RequestInit) => Promise.resolve(responseWithPendingBody(init.signal))),
    );

    const { response, cancel } = getPagedAffiliatedProducts(1);
    // Let the fetch settle first: aborting before it resolves is the already-handled case.
    await Promise.resolve();
    cancel();

    await expect(response).rejects.toBeInstanceOf(AbortError);
  });

  it("still reports a genuine body failure as a ResponseError", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.resolve(new Response("not json", { status: 200 }))),
    );

    const { response } = getPagedAffiliatedProducts(1);

    const error = await response.catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResponseError);
    expect(error).not.toBeInstanceOf(AbortError);
  });
});

describe("removeSelfAsAffiliate", () => {
  const send = async () => {
    try {
      return await removeSelfAsAffiliate("abc123");
    } catch (e: unknown) {
      return e;
    }
  };

  it("reports a stale row distinctly from a generic failure", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() =>
        Promise.resolve(
          new Response("<html>The page you were looking for doesn't exist.</html>", {
            status: 404,
            headers: { "content-type": "text/html" },
          }),
        ),
      ),
    );

    const error = await send();
    expect(error).toBeInstanceOf(AffiliationAlreadyRemovedError);
    if (!(error instanceof AffiliationAlreadyRemovedError)) throw error;
    expect(error.message).toBe("This affiliation was already removed. Refreshing your affiliations.");
  });

  it("surfaces the server's own message for a role that may not remove affiliations", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() =>
        Promise.resolve(
          new Response(JSON.stringify({ error: "Your role as marketing cannot perform this action." }), {
            status: 401,
            headers: { "content-type": "application/json" },
          }),
        ),
      ),
    );

    const error = await send();
    expect(error).toBeInstanceOf(ResponseError);
    expect(error).not.toBeInstanceOf(AffiliationAlreadyRemovedError);
    if (!(error instanceof ResponseError)) throw error;
    expect(error.message).toBe("Your role as marketing cannot perform this action.");
  });

  it("keeps the generic message for a non-JSON failure that is not a stale row", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() =>
        Promise.resolve(new Response("<html>nope</html>", { status: 403, headers: { "content-type": "text/html" } })),
      ),
    );

    const error = await send();
    expect(error).toBeInstanceOf(ResponseError);
    expect(error).not.toBeInstanceOf(AffiliationAlreadyRemovedError);
    if (!(error instanceof ResponseError)) throw error;
    expect(error.message).toBe("Sorry, something went wrong. Please try again.");
  });
});
