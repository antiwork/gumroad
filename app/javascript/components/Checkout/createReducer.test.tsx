// @vitest-environment happy-dom
import { act, cleanup, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { SurchargesResponse } from "$app/data/customer_surcharge";

import { createReducer } from "$app/components/Checkout/payment";

const getSurcharges = vi.hoisted(() => vi.fn());
vi.mock("$app/data/customer_surcharge", () => ({ getSurcharges }));

const showAlert = vi.hoisted(() => vi.fn());
vi.mock("$app/components/server-components/Alert", () => ({ showAlert }));

// payment.ts reads Routes.checkout_path() on mount to decide whether to rewrite the URL.
vi.stubGlobal("Routes", { checkout_path: () => "/checkout" });

const surchargesResponse = (overrides: Partial<SurchargesResponse> = {}): SurchargesResponse => ({
  vat_id_valid: false,
  has_vat_id_input: false,
  shipping_rate_cents: 0,
  tax_cents: 0,
  tax_included_cents: 0,
  subtotal: 1_000,
  buyer_currency_quote: null,
  ...overrides,
});

const quote = (token: string) => ({
  token,
  currency: "cad" as const,
  canonical_total_cents: 1_000,
  presentment_total_cents: 1_400,
  rate: 1.4,
  subunit_to_unit: 100,
  expires_at: "2999-01-01T00:00:00Z",
});

const initialArgs = {
  countries: { US: "United States" },
  usStates: ["NY"],
  caProvinces: ["QC"],
  tipOptions: [0, 10, 20],
  defaultTipOption: 0,
  country: "US",
  email: "buyer@example.com",
  state: "NY",
  address: null,
  savedCreditCard: null,
  products: [
    {
      permalink: "abc",
      name: "Product",
      creator: { id: "creator", name: "Creator", profile_url: "", avatar_url: "" },
      quantity: 1,
      price: 1_000,
      payInInstallments: false,
      requireShipping: false,
      customFields: [],
      bundleProductCustomFields: [],
      supportsPaypal: null,
      testPurchase: false,
      requirePayment: true,
      hasFreeTrial: false,
      hasTippingEnabled: true,
      isPreorder: false,
      canGift: true,
      nativeType: "digital" as const,
      recurrence: null,
      shippableCountryCodes: [],
    },
  ],
  recaptchaKey: null,
  paypalClientId: "",
  gift: null,
  requireEmailTypoAcknowledgment: false,
};

// A getSurcharges stub the test resolves by hand, so two overlapping requests can complete
// out of order — the shape of the race that let a stale quote overwrite a fresh one. Each
// call to the stub returns a fresh deferred promise, collected in order.
const stubSurchargeRequests = () => {
  const requests: {
    resolve: (result: SurchargesResponse) => void;
    reject: (error: unknown) => void;
    signal: AbortSignal | undefined;
  }[] = [];
  getSurcharges.mockImplementation(
    (_data: unknown, signal?: AbortSignal) =>
      new Promise<SurchargesResponse>((resolve, reject) => {
        requests.push({ resolve, reject, signal });
      }),
  );
  return requests;
};

describe("createReducer surcharge refetches", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    cleanup();
    vi.useRealTimers();
    vi.resetAllMocks();
  });

  const renderCheckout = () => renderHook(() => createReducer(initialArgs));

  it("passes an abort signal to getSurcharges and aborts it when a newer change invalidates", async () => {
    const requests = stubSurchargeRequests();
    const { result } = renderCheckout();

    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(requests).toHaveLength(1);
    expect(requests[0]?.signal).toBeInstanceOf(AbortSignal);

    // A total-affecting change while the first request is in flight aborts it.
    act(() => result.current[1]({ type: "set-value", tip: { type: "fixed", amount: 2_00 } }));
    expect(requests[0]?.signal?.aborted).toBe(true);
  });

  it("ignores a stale response that lands after a newer request already resolved", async () => {
    // The abort above is best-effort: the stale response can already be past the fetch when the
    // newer request starts. Without a generation check it would restore the old quote (and old
    // totals), re-enabling Pay on numbers that no longer match what will be charged.
    const requests = stubSurchargeRequests();
    const { result } = renderCheckout();
    await act(() => vi.advanceTimersByTimeAsync(300));

    act(() => result.current[1]({ type: "set-value", tip: { type: "fixed", amount: 2_00 } }));
    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(requests).toHaveLength(2);

    const freshResult = surchargesResponse({ subtotal: 1_200, buyer_currency_quote: quote("fresh-token") });
    await act(async () => {
      requests[1]?.resolve(freshResult);
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(result.current[0].surcharges).toEqual({ type: "loaded", result: freshResult });

    // The stale response arrives last — it must not overwrite the fresh quote.
    await act(async () => {
      requests[0]?.resolve(surchargesResponse({ buyer_currency_quote: quote("stale-token") }));
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(result.current[0].surcharges).toEqual({ type: "loaded", result: freshResult });
  });

  it("ignores a stale response that resolves during the debounce window, before the next request starts", async () => {
    // Trickiest shape of the race: a total-affecting edit marks surcharges "pending", but the
    // previous request's response resolves inside the 300ms debounce window — before the fresh
    // request (and its new generation) even exists. The stale response must not publish a
    // "loaded" quote over the pending state, which would re-enable Pay on the old totals and
    // suppress the refetch's effect on the visible quote.
    const requests = stubSurchargeRequests();
    const { result } = renderCheckout();
    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(requests).toHaveLength(1);

    // Total-affecting change → surcharges go pending, debounced refetch scheduled but not fired.
    act(() => result.current[1]({ type: "set-value", tip: { type: "fixed", amount: 2_00 } }));
    expect(result.current[0].surcharges.type).toBe("pending");

    // The original request resolves while the debounce is still pending — it must be ignored.
    await act(async () => {
      requests[0]?.resolve(surchargesResponse({ buyer_currency_quote: quote("stale-token") }));
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(result.current[0].surcharges.type).toBe("pending");
    expect(requests).toHaveLength(1);

    // The debounce fires, the fresh request runs, and its quote is the one that lands.
    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(requests).toHaveLength(2);
    const freshResult = surchargesResponse({ subtotal: 1_200, buyer_currency_quote: quote("fresh-token") });
    await act(async () => {
      requests[1]?.resolve(freshResult);
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(result.current[0].surcharges).toEqual({ type: "loaded", result: freshResult });
  });

  it("ignores a stale failure while a fresh request is still loading", async () => {
    // A stale request erroring must not flip the fresh request's loading state to error (which
    // would both surface a bogus alert and leave the checkout stuck until the fresh response
    // overwrote it — or worse, arrive after it).
    const requests = stubSurchargeRequests();
    const { result } = renderCheckout();
    await act(() => vi.advanceTimersByTimeAsync(300));

    act(() => result.current[1]({ type: "set-value", tip: { type: "fixed", amount: 2_00 } }));
    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(requests).toHaveLength(2);

    const { ResponseError } = await import("$app/utils/request");
    await act(async () => {
      requests[0]?.reject(new ResponseError());
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(result.current[0].surcharges.type).toBe("loading");
    expect(showAlert).not.toHaveBeenCalled();

    const freshResult = surchargesResponse({ subtotal: 1_200 });
    await act(async () => {
      requests[1]?.resolve(freshResult);
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(result.current[0].surcharges).toEqual({ type: "loaded", result: freshResult });
  });
});
