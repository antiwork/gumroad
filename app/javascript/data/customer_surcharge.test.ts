import { afterEach, describe, expect, it, vi } from "vitest";

import { getSurcharges, type SurchargesResponse } from "$app/data/customer_surcharge";

const request = vi.hoisted(() => vi.fn());
vi.mock("$app/utils/request", () => ({ request, ResponseError: class extends Error {} }));
vi.stubGlobal("Routes", { customer_surcharges_path: () => "/customer_surcharges" });
afterEach(() => {
  vi.useRealTimers();
  vi.resetAllMocks();
});

describe("quote expiry clock", () => {
  it.each([-3600000, 3600000])("uses the server Date when the buyer clock is offset by %s ms", async (skew) => {
    vi.useFakeTimers();
    const serverNow = Date.parse("2026-09-08T12:00:00Z");
    vi.setSystemTime(serverNow + skew);
    const payload: SurchargesResponse = {
      vat_id_valid: false,
      has_vat_id_input: false,
      shipping_rate_cents: 0,
      tax_cents: 0,
      tax_included_cents: 0,
      subtotal: 1000,
      buyer_currency_quote: {
        token: "quote",
        currency: "cad",
        canonical_total_cents: 1000,
        presentment_total_cents: 1400,
        rate: 1.4,
        subunit_to_unit: 100,
        expires_at: "2026-09-08T12:05:00Z",
        line_allocations: [],
      },
    };
    request.mockImplementation(async () => {
      vi.setSystemTime(Date.now() + 2000);
      return new Response(JSON.stringify(payload), { headers: { Date: "Tue, 08 Sep 2026 12:00:00 GMT" } });
    });
    const result = await getSurcharges({ products: [], country: "US" });
    expect(result.buyer_currency_quote?.client_expires_at).toBe(serverNow + skew + 299000);
    expect((result.buyer_currency_quote?.client_expires_at ?? 0) - Date.now()).toBe(297000);
    expect(result.buyer_currency_quote?.expires_at).toBe(payload.buyer_currency_quote?.expires_at);
    expect(result.buyer_currency_quote?.token).toBe("quote");
  });
});
