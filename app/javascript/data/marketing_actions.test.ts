// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { approveMarketingAction } from "$app/data/marketing_actions";
import { ResponseError } from "$app/utils/request";

describe("marketing action errors", () => {
  beforeEach(() =>
    vi.stubGlobal("Routes", { approve_product_marketing_action_path: () => "/marketing-actions/1/approve" }),
  );
  afterEach(() => vi.unstubAllGlobals());

  it("preserves the server's explanation", async () => {
    vi.stubGlobal(
      "fetch",
      vi
        .fn()
        .mockResolvedValue(
          new Response(JSON.stringify({ success: false, error: "Connect X first." }), { status: 422 }),
        ),
    );
    await expect(approveMarketingAction("p1", "a1")).rejects.toThrow("Connect X first.");
  });

  it("does not use an error body of the wrong shape as the message", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(new Response(JSON.stringify({ success: false, error: 42 }), { status: 422 })),
    );
    const error = await approveMarketingAction("p1", "a1").catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResponseError);
    expect(String(error)).not.toContain("42");
  });
});
