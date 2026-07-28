import { describe, expect, it, vi } from "vitest";

import { AbortError, RateLimitError, ResponseError, request } from "$app/utils/request";

const jsonResponse = (status: number, body: unknown, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });

const stubFetch = (response: Response | Error) =>
  vi.stubGlobal(
    "fetch",
    vi.fn(() => (response instanceof Error ? Promise.reject(response) : Promise.resolve(response))),
  );

// Send a request and return whatever it rejected with. Typed as unknown, then narrowed per test with
// instanceof, so the assertions prove the error's class rather than assuming it.
const sendAndCatch = async (): Promise<unknown> => {
  try {
    return await request({ method: "GET", accept: "json", url: "/anything" });
  } catch (e: unknown) {
    return e;
  }
};

// Narrow a caught value to a RateLimitError, failing the test with a readable message otherwise.
const asRateLimitError = (error: unknown): RateLimitError => {
  expect(error).toBeInstanceOf(RateLimitError);
  if (!(error instanceof RateLimitError)) throw error;
  return error;
};

describe("request", () => {
  it("resolves non-error responses", async () => {
    stubFetch(jsonResponse(200, { ok: true }));

    await expect(request({ method: "GET", accept: "json", url: "/anything" })).resolves.toMatchObject({ status: 200 });
  });

  it("throws a plain ResponseError on 5xx", async () => {
    stubFetch(jsonResponse(500, { error: "boom" }));

    const error = await sendAndCatch();
    expect(error).toBeInstanceOf(ResponseError);
    expect(error).not.toBeInstanceOf(RateLimitError);
  });

  describe("on 429", () => {
    it("surfaces the server's explanation and Retry-After instead of a generic message", async () => {
      stubFetch(
        jsonResponse(
          429,
          { error: "You've used all 30 agent requests for this hour.", retry_after: 900 },
          { "Retry-After": "900" },
        ),
      );

      const error = asRateLimitError(await sendAndCatch());
      expect(error.message).toBe("You've used all 30 agent requests for this hour.");
      expect(error.retryAfter).toBe(900);
    });

    it("falls back to the body's retry_after when the header is missing", async () => {
      stubFetch(jsonResponse(429, { error: "Slow down.", retry_after: 42 }));

      expect(asRateLimitError(await sendAndCatch()).retryAfter).toBe(42);
    });

    it("still produces a usable rate-limit error when the body isn't JSON", async () => {
      stubFetch(
        new Response("<html>Too Many Requests</html>", { status: 429, headers: { "content-type": "text/html" } }),
      );

      const error = asRateLimitError(await sendAndCatch());
      expect(error.message).toBe("You're making requests too quickly. Please wait a moment and try again.");
      expect(error.retryAfter).toBeNull();
    });

    it("ignores a non-positive Retry-After rather than reporting a countdown of zero", async () => {
      stubFetch(jsonResponse(429, {}, { "Retry-After": "-1" }));

      expect(asRateLimitError(await sendAndCatch()).retryAfter).toBeNull();
    });
  });

  it("reports an aborted request as an AbortError", async () => {
    stubFetch(new DOMException("aborted", "AbortError"));

    expect(await sendAndCatch()).toBeInstanceOf(AbortError);
  });

  it("reports a network failure as a generic ResponseError", async () => {
    stubFetch(new TypeError("network error"));

    const error = await sendAndCatch();
    expect(error).toBeInstanceOf(ResponseError);
    expect(error).toMatchObject({ message: "Something went wrong." });
  });
});
