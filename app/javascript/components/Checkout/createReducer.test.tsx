// @vitest-environment happy-dom
import { act, cleanup, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { SurchargesResponse } from "$app/data/customer_surcharge";

import { createReducer, type CheckoutPaymentConfig } from "$app/components/Checkout/payment";

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
  line_allocations: [
    { permalink: "prod", price_cents: 1_400, tip_cents: 0, tax_cents: 0, shipping_cents: 0, total_cents: 1_400 },
  ],
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
      uid: "abc ",
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
    payload: unknown;
  }[] = [];
  getSurcharges.mockImplementation(
    (data: unknown, signal?: AbortSignal) =>
      new Promise<SurchargesResponse>((resolve, reject) => {
        requests.push({ resolve, reject, signal, payload: data });
      }),
  );
  return requests;
};

describe("createReducer surcharge refetches", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    document.cookie = "gumroad_buyer_currency=; path=/; max-age=0";
  });

  afterEach(() => {
    cleanup();
    vi.useRealTimers();
    vi.resetAllMocks();
  });

  const directListedCheckoutPayment: CheckoutPaymentConfig = {
    integration: "payment_element_client_confirm" as const,
    fallback_reason: null,
    recurring_upi_registration: false,
    disable_wallets: true,
    request_apple_pay_merchant_tokens: false,
    payment_element_wallets: false,
    flat_payment_methods: true,
    elements_options: {
      stripe_elements_mode: "payment" as const,
      currency: "cad",
      buyer_currency_presentment: false,
      presentment_amount_cents: 1_000,
      listed_currency_display: { currency: "cad", subunit_to_unit: 100 },
      payment_method_types: ["card"],
      payment_method_list_token: null,
      stripe_link_enabled: false,
      stripe_connect_account_id: null,
      direct_listed_card: true,
    },
  };

  // iDEAL forces the element into the listed currency without the direct-listed CARD shape, and
  // its charge converts each line's tax separately — so it needs the same per-line allocations.
  const methodForcedCheckoutPayment: CheckoutPaymentConfig = {
    ...directListedCheckoutPayment,
    elements_options: {
      ...directListedCheckoutPayment.elements_options,
      currency: "eur",
      listed_currency_display: { currency: "eur", subunit_to_unit: 100 },
      payment_method_types: ["card", "ideal"],
      direct_listed_card: false,
    },
  };

  const renderCheckout = (overrides: Partial<Parameters<typeof createReducer>[0]> = {}) =>
    renderHook(() => createReducer({ ...initialArgs, ...overrides }));

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

  it("passes the direct-listed Payment Element mount to the surcharge request", async () => {
    const requests = stubSurchargeRequests();
    renderCheckout({ checkoutPayment: directListedCheckoutPayment });

    await act(() => vi.advanceTimersByTimeAsync(300));

    expect(requests[0]?.payload).toMatchObject({
      // Production uid is computed in Show.tsx getProducts (see cartItemUidMapping.test.ts).
      // This example only proves loadSurcharges forwards a product that already has one.
      products: [expect.objectContaining({ permalink: "abc", uid: "abc " })],
      payment_details_source: "payment_element",
      payment_element_mount_currency: "cad",
      payment_element_direct_listed_currency: "cad",
    });
  });

  it("requests per-line allocations for a method-forced listed mount", async () => {
    const requests = stubSurchargeRequests();
    renderCheckout({
      checkoutPayment: methodForcedCheckoutPayment,
      products: initialArgs.products.map((product) => ({ ...product, listedChargePriceCents: 1_000 })),
    });

    await act(() => vi.advanceTimersByTimeAsync(300));

    expect(requests[0]?.payload).toMatchObject({
      products: [expect.objectContaining({ listed_price_cents: 1_000 })],
      payment_details_source: "payment_element",
      payment_element_mount_currency: "eur",
      payment_element_direct_listed_currency: "eur",
    });
  });

  it("keeps the listed selector capability while requesting USD", async () => {
    const requests = stubSurchargeRequests();
    const { result } = renderCheckout({ checkoutPayment: directListedCheckoutPayment });

    await act(() => vi.advanceTimersByTimeAsync(300));
    await act(async () => {
      requests[0]?.resolve(
        surchargesResponse({
          detected_buyer_currency: "cad",
          available_buyer_currencies: [
            { code: "usd", label: "$ (US Dollars)" },
            { code: "cad", label: "CA$ (Canadian Dollars)" },
          ],
        }),
      );
      await vi.advanceTimersByTimeAsync(0);
    });

    act(() => result.current[1]({ type: "set-value", buyerCurrency: "usd" }));
    await act(() => vi.advanceTimersByTimeAsync(300));

    expect(requests[1]?.payload).toMatchObject({
      buyer_currency: "usd",
      payment_details_source: "payment_element",
      payment_element_mount_currency: "usd",
      payment_element_direct_listed_currency: "cad",
    });
  });

  it("uses but does not overwrite a stale stored buyer currency before publishing a USD-only surcharge response", async () => {
    document.cookie = "gumroad_buyer_currency=cad; path=/";
    const requests = stubSurchargeRequests();
    const { result } = renderCheckout({ checkoutPayment: directListedCheckoutPayment });

    await act(() => vi.advanceTimersByTimeAsync(300));
    await act(async () => {
      requests[0]?.resolve(
        surchargesResponse({
          detected_buyer_currency: "usd",
          available_buyer_currencies: [{ code: "usd", label: "$ (US Dollars)" }],
        }),
      );
      await vi.advanceTimersByTimeAsync(0);
    });

    expect(result.current[0].buyerCurrency).toBe("usd");
    expect(document.cookie).toContain("gumroad_buyer_currency=cad");
  });

  it("requotes an implicit fallback when the replacement currency is not the response currency", async () => {
    document.cookie = "gumroad_buyer_currency=cad; path=/";
    const requests = stubSurchargeRequests();
    const { result } = renderCheckout();

    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(requests[0]?.payload).toMatchObject({ buyer_currency: "cad" });
    await act(async () => {
      requests[0]?.resolve(
        surchargesResponse({
          detected_buyer_currency: "gbp",
          available_buyer_currencies: [
            { code: "gbp", label: "£ (British Pounds)" },
            { code: "usd", label: "$ (US Dollars)" },
          ],
        }),
      );
      await vi.advanceTimersByTimeAsync(0);
    });

    expect(result.current[0].buyerCurrency).toBe("gbp");
    expect(result.current[0].surcharges.type).toBe("pending");
    expect(document.cookie).toContain("gumroad_buyer_currency=cad");
    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(requests[1]?.payload).toMatchObject({ buyer_currency: "gbp" });
  });

  it("does not reuse a CAD exact tip when a tipped direct-listed cart requests USD", async () => {
    const requests = stubSurchargeRequests();
    const { result } = renderCheckout({ checkoutPayment: directListedCheckoutPayment });

    await act(() => vi.advanceTimersByTimeAsync(300));
    await act(async () => {
      requests[0]?.resolve(
        surchargesResponse({
          detected_buyer_currency: "cad",
          available_buyer_currencies: [
            { code: "usd", label: "$ (US Dollars)" },
            { code: "cad", label: "CA$ (Canadian Dollars)" },
          ],
          buyer_currency_quote: quote("cad-token"),
        }),
      );
      await vi.advanceTimersByTimeAsync(0);
    });

    act(() =>
      result.current[1]({
        type: "set-value",
        tip: { type: "fixed", amount: 350, presentmentAmount: 437, presentmentCurrency: "cad" },
      }),
    );
    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(requests.at(-1)?.payload).toMatchObject({
      buyer_currency: "cad",
      products: [expect.objectContaining({ presentment_tip_cents: 437 })],
    });

    act(() => result.current[1]({ type: "set-value", buyerCurrency: "usd" }));
    await act(() => vi.advanceTimersByTimeAsync(300));

    expect(requests.at(-1)?.payload).toMatchObject({
      buyer_currency: "usd",
      payment_details_source: "payment_element",
      payment_element_mount_currency: "usd",
    });
    expect(requests.at(-1)?.payload).not.toMatchObject({
      products: [expect.objectContaining({ presentment_tip_cents: expect.anything() })],
    });
  });

  it("keeps an explicit USD pick through the tipped direct-listed payment-configuration refresh", async () => {
    const requests = stubSurchargeRequests();
    const { result } = renderCheckout({ checkoutPayment: directListedCheckoutPayment });

    await act(() => vi.advanceTimersByTimeAsync(300));
    await act(async () => {
      requests[0]?.resolve(
        surchargesResponse({
          detected_buyer_currency: "cad",
          available_buyer_currencies: [
            { code: "usd", label: "$ (US Dollars)" },
            { code: "cad", label: "CA$ (Canadian Dollars)" },
          ],
          buyer_currency_quote: quote("cad-token"),
        }),
      );
      await vi.advanceTimersByTimeAsync(0);
    });

    act(() =>
      result.current[1]({
        type: "set-value",
        tip: { type: "fixed", amount: 350, presentmentAmount: 437, presentmentCurrency: "cad" },
      }),
    );
    await act(() => vi.advanceTimersByTimeAsync(300));
    await act(async () => {
      requests.at(-1)?.resolve(
        surchargesResponse({
          detected_buyer_currency: "cad",
          available_buyer_currencies: [
            { code: "usd", label: "$ (US Dollars)" },
            { code: "cad", label: "CA$ (Canadian Dollars)" },
          ],
          buyer_currency_quote: quote("cad-tip-token"),
        }),
      );
      await vi.advanceTimersByTimeAsync(0);
    });

    act(() => result.current[1]({ type: "set-value", buyerCurrency: "usd" }));
    expect(document.cookie).toContain("gumroad_buyer_currency=usd");
    act(() =>
      result.current[1]({
        type: "update-checkout-payment",
        checkoutPayment: {
          ...directListedCheckoutPayment,
          elements_options: {
            ...directListedCheckoutPayment.elements_options,
            currency: "eur",
            listed_currency_display: { currency: "eur", subunit_to_unit: 100 },
            direct_listed_card: false,
          },
        },
      }),
    );
    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(requests.at(-1)?.payload).toMatchObject({ buyer_currency: "usd" });
    expect(requests.at(-1)?.payload).not.toMatchObject({
      products: [expect.objectContaining({ presentment_tip_cents: expect.anything() })],
    });
    await act(async () => {
      requests.at(-1)?.resolve(
        surchargesResponse({
          detected_buyer_currency: "cad",
          available_buyer_currencies: [
            { code: "usd", label: "$ (US Dollars)" },
            { code: "cad", label: "CA$ (Canadian Dollars)" },
          ],
        }),
      );
      await vi.advanceTimersByTimeAsync(0);
    });

    expect(result.current[0].unavailableBuyerCurrency).toBeNull();
    expect(result.current[0].buyerCurrency).toBe("usd");
    expect(result.current[0].surcharges.type).toBe("loaded");
    expect(document.cookie).toContain("gumroad_buyer_currency=usd");
  });

  it("marks saved-card surcharge requests so direct-listed currencies are not advertised", async () => {
    const requests = stubSurchargeRequests();
    renderCheckout({
      checkoutPayment: directListedCheckoutPayment,
      savedCreditCard: { type: "visa", number: "**** 4242", expiration_date: "12/30", requires_mandate: false },
    });

    await act(() => vi.advanceTimersByTimeAsync(300));

    expect(requests[0]?.payload).toMatchObject({ payment_details_source: "saved_payment_method" });
    expect(requests[0]?.payload).not.toHaveProperty("payment_element_mount_currency");
    expect(requests[0]?.payload).not.toHaveProperty("payment_element_direct_listed_currency");
  });

  it("refetches direct-listed selector options when the buyer switches from a saved card to a new card", async () => {
    const requests = stubSurchargeRequests();
    const { result } = renderCheckout({
      checkoutPayment: directListedCheckoutPayment,
      savedCreditCard: { type: "visa", number: "**** 4242", expiration_date: "12/30", requires_mandate: false },
    });

    await act(() => vi.advanceTimersByTimeAsync(300));
    await act(async () => {
      requests[0]?.resolve(surchargesResponse());
      await vi.advanceTimersByTimeAsync(0);
    });

    act(() => result.current[1]({ type: "set-value", usingSavedCard: false }));
    expect(result.current[0].surcharges.type).toBe("pending");
    // The refetch still happens, but the amounts the summary was showing are held for it: the
    // switch changes which currencies the server advertises, not what the cart costs.
    expect(result.current[0].buyerCurrencyRemint?.surcharges).toEqual(surchargesResponse());
    expect(result.current[0].buyerCurrencyRemint?.surfaceSwitch).toBe(true);
    await act(() => vi.advanceTimersByTimeAsync(300));

    expect(requests[1]?.payload).toMatchObject({
      payment_details_source: "payment_element",
      payment_element_mount_currency: "cad",
      payment_element_direct_listed_currency: "cad",
    });
  });

  it("sends an exact presentment tip only when the selected currency matches its tag", async () => {
    const requests = stubSurchargeRequests();
    const { result } = renderCheckout();
    await act(() => vi.advanceTimersByTimeAsync(300));

    act(() =>
      result.current[1]({
        type: "set-value",
        tip: { type: "fixed", amount: 350, presentmentAmount: 437, presentmentCurrency: "cad" },
      }),
    );
    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(requests.at(-1)?.payload).toMatchObject({
      buyer_currency: "cad",
      products: [expect.objectContaining({ presentment_tip_cents: 437 })],
    });

    act(() => result.current[1]({ type: "set-value", buyerCurrency: "gbp" }));
    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(requests.at(-1)?.payload).toMatchObject({
      buyer_currency: "gbp",
      products: [expect.not.objectContaining({ presentment_tip_cents: expect.anything() })],
    });

    act(() => result.current[1]({ type: "set-value", buyerCurrency: "cad" }));
    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(requests.at(-1)?.payload).toMatchObject({
      buyer_currency: "cad",
      products: [expect.objectContaining({ presentment_tip_cents: 437 })],
    });
  });

  it("does not reinterpret rapid custom-tip edits while currency quotes are being replaced", async () => {
    const requests = stubSurchargeRequests();
    const { result } = renderCheckout();
    await act(() => vi.advanceTimersByTimeAsync(300));
    await act(async () => {
      requests[0]?.resolve(
        surchargesResponse({
          detected_buyer_currency: "cad",
          available_buyer_currencies: ["usd", "cad", "gbp", "eur", "jpy"].map((code) => ({ code, label: code })),
          buyer_currency_quote: quote("cad-token"),
        }),
      );
      await vi.advanceTimersByTimeAsync(0);
    });

    for (const buyerCurrency of ["gbp", "eur", "jpy", "cad"])
      act(() => result.current[1]({ type: "set-value", buyerCurrency }));
    for (const presentmentAmount of [111, 222, 333])
      act(() =>
        result.current[1]({
          type: "set-value",
          tip: {
            type: "fixed",
            amount: Math.round(presentmentAmount / 1.4),
            presentmentAmount,
            presentmentCurrency: "cad",
          },
        }),
      );

    expect(result.current[0].buyerCurrencyRemint?.previousCurrency).toBe("cad");
    expect(result.current[0].tip).toMatchObject({ presentmentAmount: 333, presentmentCurrency: "cad" });

    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(requests.at(-1)?.payload).toMatchObject({
      buyer_currency: "cad",
      products: [expect.objectContaining({ presentment_tip_cents: 333 })],
    });
  });

  it("passes the selected buyer currency on the next surcharge fetch", async () => {
    const requests = stubSurchargeRequests();
    const { result } = renderCheckout();
    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(requests).toHaveLength(1);
    expect(requests[0]?.payload).not.toHaveProperty("buyer_currency");

    act(() => result.current[1]({ type: "set-value", buyerCurrency: "gbp" }));
    expect(result.current[0].surcharges.type).toBe("pending");
    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(requests).toHaveLength(2);
    expect(requests[1]?.payload).toMatchObject({ buyer_currency: "gbp" });
  });
});
