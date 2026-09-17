// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { fetchCartRecovery, updateCartRecovery } from "$app/data/marketing_cart_recovery";
import { ResponseError } from "$app/utils/request";

describe("cart recovery responses", () => {
  beforeEach(() => vi.stubGlobal("Routes", { product_marketing_abandoned_cart_path: () => "/cart-recovery" }));
  afterEach(() => vi.unstubAllGlobals());

  it.each([fetchCartRecovery, (id: string) => updateCartRecovery(id, false)])(
    "turns an empty 404 into a recoverable response error",
    async (call) => {
      vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(null, { status: 404 })));
      await expect(call("abc")).rejects.toBeInstanceOf(ResponseError);
    },
  );

  it("preserves the server's explanation", async () => {
    vi.stubGlobal(
      "fetch",
      vi
        .fn()
        .mockResolvedValue(
          new Response(JSON.stringify({ success: false, error: "Turns on after your first payout." }), { status: 422 }),
        ),
    );
    await expect(updateCartRecovery("abc", true)).rejects.toThrow("Turns on after your first payout.");
  });
  it("turns a non-JSON forbidden response into a recoverable error", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response("<html>Forbidden</html>", { status: 403 })));
    await expect(updateCartRecovery("abc", true, "token")).rejects.toBeInstanceOf(ResponseError);
  });
  it("includes the reviewed activation token in the request", async () => {
    const fetch = vi.fn().mockResolvedValue(new Response(null, { status: 404 }));
    vi.stubGlobal("fetch", fetch);
    await expect(updateCartRecovery("abc", true, "reviewed-token")).rejects.toBeInstanceOf(ResponseError);
    expect(fetch.mock.calls[0]?.[1].body).toBe(JSON.stringify({ enabled: true, activation_token: "reviewed-token" }));
  });
});
