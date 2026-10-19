// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, renderHook, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { SelectionDiscountsRequest } from "$app/data/offer_code";
import type { Discount } from "$app/parsers/checkout";
import { AbortError, ResponseError } from "$app/utils/request";

import { Product, type Product as ProductData, type ProductDiscount } from "$app/components/Product";
import type { Option, PriceSelection } from "$app/components/Product/ConfigurationSelector";
import { type SelectionDiscounts, useSelectionDiscounts } from "$app/components/Product/selectionDiscounts";

type Pending = {
  params: SelectionDiscountsRequest;
  resolve: (quote: SelectionDiscounts) => void;
  reject: (error: unknown) => void;
  cancelled: boolean;
};
const requests: Pending[] = [];
vi.mock("$app/data/offer_code", () => ({
  getSelectionDiscounts: (params: SelectionDiscountsRequest) => {
    let resolve!: Pending["resolve"];
    let reject!: Pending["reject"];
    const response = new Promise<SelectionDiscounts>((res, rej) => {
      resolve = res;
      reject = rej;
    });
    const pending: Pending = { params, resolve, reject, cancelled: false };
    requests.push(pending);
    // Like the real helper, a cancel only rejects a request that has not answered yet.
    return {
      response,
      cancel: () => {
        pending.cancelled = true;
        reject(new AbortError());
      },
    };
  },
}));

vi.stubGlobal("SSR", false);
vi.stubGlobal("Routes", {
  checkout_url: () => "https://example.com/checkout",
  edit_link_url: () => "https://example.com/edit",
  license_key_lookup_url: () => "https://example.com/license-key-lookup",
});
vi.mock("$app/data/user_action_event", () => ({ trackUserProductAction: vi.fn().mockResolvedValue(undefined) }));
vi.mock("$app/data/view_event", () => ({ incrementProductViews: vi.fn() }));
vi.mock("$app/utils/user_analytics", () => ({
  startTrackingForSeller: vi.fn(),
  trackBuyerCurrencyDisplayView: vi.fn(),
  trackProductEvent: vi.fn(),
}));
vi.mock("$app/components/LoggedInUser", () => ({ useLoggedInUser: () => null }));
vi.mock("$app/components/RichTextEditor", () => ({ useRichTextEditor: () => null }));
vi.mock("$app/components/useAddThirdPartyAnalytics", () => ({ useAddThirdPartyAnalytics: () => vi.fn() }));
vi.mock("$app/components/useOriginalLocation", () => ({
  useOriginalLocation: () => "https://example.com/l/membership",
}));
vi.mock("$app/components/useRunOnce", () => ({ useRunOnce: vi.fn() }));
vi.mock("$app/components/DomainSettings", () => ({
  useAppDomain: () => "example.com",
  useDomains: () => ({ scheme: "https", rootDomain: "example.com" }),
}));
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => false }));
// The selector UI is stubbed so the test can read the per-row discount the page hands it.
type SelectorProps = { rowDiscount?: ((selection: PriceSelection) => Discount | null) | undefined };
const selectorProps: SelectorProps[] = [];
vi.mock("$app/components/Product/ConfigurationSelector", async (importOriginal) => {
  const ConfigurationSelector = React.forwardRef((props: SelectorProps, _ref) => {
    selectorProps.push(props);
    return null;
  });
  ConfigurationSelector.displayName = "ConfigurationSelector";
  return { ...(await importOriginal<object>()), ConfigurationSelector };
});
vi.mock("$app/components/Product/Thumbnail", () => ({ Thumbnail: () => null }));
vi.mock("$app/components/Product/ShareSection", () => ({ ShareSection: () => null }));

beforeEach(() => {
  requests.length = 0;
  selectorProps.length = 0;
});
afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

const tier = (id: string, monthlyPriceCents: number): Option => ({
  id,
  name: id,
  quantity_left: null,
  description: "",
  price_difference_cents: 0,
  recurrence_price_values: { monthly: { price_cents: monthlyPriceCents, suggested_price_cents: null } },
  is_pwyw: false,
  duration_in_minutes: null,
});

const product = (overrides: Partial<ProductData> = {}): ProductData => ({
  id: "membership",
  name: "Membership",
  seller: null,
  collaborating_user: null,
  covers: [],
  main_cover_id: null,
  quantity_remaining: null,
  currency_code: "usd",
  long_url: "https://example.com/l/membership",
  duration_in_months: null,
  is_sales_limited: false,
  price_cents: 0,
  pwyw: null,
  installment_plan: null,
  ratings: null,
  is_legacy_subscription: false,
  is_tiered_membership: true,
  is_recurring_billing: true,
  is_physical: false,
  custom_view_content_button_text: null,
  custom_button_text_option: null,
  permalink: "membership",
  preorder: null,
  description_html: "",
  is_compliance_blocked: false,
  is_published: true,
  is_stream_only: false,
  streamable: false,
  is_quantity_enabled: true,
  is_multiseat_license: false,
  is_licensed: false,
  native_type: "membership",
  sales_count: null,
  summary: null,
  attributes: [],
  free_trial: null,
  rental: null,
  recurrences: { default: "monthly", enabled: [{ recurrence: "monthly", price_cents: 0, id: "monthly" }] },
  options: [tier("basic", 1_000), tier("pro", 10_000)],
  analytics: { google_analytics_id: null, facebook_pixel_id: null, tiktok_pixel_id: null, free_sales: true },
  has_third_party_analytics: false,
  ppp_details: null,
  can_edit: false,
  refund_policy: null,
  bundle_products: [],
  public_files: [],
  ...overrides,
});

const percentOff = (percents: number, expiresAt: string | null = null): Discount => ({
  type: "percent",
  percents,
  product_ids: null,
  expires_at: expiresAt,
  minimum_quantity: null,
  duration_in_billing_cycles: null,
  minimum_amount_cents: null,
});
const code = (name: string, percents: number, expiresAt: string | null = null): ProductDiscount => ({
  valid: true,
  code: name,
  discount: percentOff(percents, expiresAt),
});

const selectionFor = (overrides: Partial<PriceSelection> = {}): PriceSelection => ({
  rent: false,
  optionId: "pro",
  price: { error: false, value: null },
  quantity: 1,
  recurrence: "monthly",
  callStartTime: null,
  payInInstallments: false,
  ...overrides,
});

const quoteFor = (quantity: number, proCode: ProductDiscount | null, inputs: Partial<SelectionDiscounts> = {}) => ({
  url_code: null,
  quantity,
  recurrence: "monthly" as const,
  option_id: null,
  price_cents: null,
  options: {
    basic: { discount_code: code("SHOP5", 5), sale_label: null },
    pro: { discount_code: proCode, sale_label: null },
  },
  rent_options: null,
  ...inputs,
});

const settle = () => act(() => vi.runOnlyPendingTimersAsync());
// Settles request `index` with a quote, or fails it with an error, and lets React apply the result.
const answer = (index: number, outcome: SelectionDiscounts | Error) =>
  act(async () => {
    if (outcome instanceof Error) requests[index]?.reject(outcome);
    else requests[index]?.resolve(outcome);
    await Promise.resolve();
  });

const renderQuotes = (initial: SelectionDiscounts | null, selection = selectionFor()) =>
  renderHook(
    ({ selection }: { selection: PriceSelection }) =>
      useSelectionDiscounts({ product: product(), discountCode: null, saleLabel: null, initial, selection }),
    { initialProps: { selection } },
  );

describe("useSelectionDiscounts", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  it("uses the page's quote for the inputs it was quoted for, without asking again", () => {
    const { result } = renderQuotes(quoteFor(1, code("RENEW20", 20)));

    expect(result.current.quote.state).toBe("ready");
    expect(result.current.discountCode).toEqual(code("RENEW20", 20));
    expect(result.current.selectionDiscountCode?.("basic", false)).toEqual(code("SHOP5", 5));
    expect(requests).toHaveLength(0);
  });

  it("shows no code until the answer for the new inputs lands, then shows that answer", async () => {
    const { result, rerender } = renderQuotes(quoteFor(1, code("RENEW20", 20)));

    rerender({ selection: selectionFor({ quantity: 2 }) });
    await settle();
    expect(result.current.quote.state).toBe("loading");
    expect(result.current.discountCode).toBeNull();
    expect(result.current.selectionDiscountCode?.("basic", false)).toBeNull();
    expect(requests.map(({ params }) => params.quantity)).toEqual([2]);

    await answer(0, quoteFor(2, code("BULK50", 50)));
    expect(result.current.quote.state).toBe("ready");
    expect(result.current.discountCode).toEqual(code("BULK50", 50));
  });

  it("never lets an answer for earlier inputs replace the current one, even when it arrives after cancelling", async () => {
    const { result, rerender } = renderQuotes(quoteFor(1, code("RENEW20", 20)));

    rerender({ selection: selectionFor({ quantity: 2 }) });
    await settle();
    rerender({ selection: selectionFor({ quantity: 3 }) });
    await settle();
    expect(requests.map(({ params }) => params.quantity)).toEqual([2, 3]);
    expect(requests[0]?.cancelled).toBe(true);

    await answer(1, quoteFor(3, code("BULK50", 50)));
    // The quantity-2 request had already answered when it was cancelled.
    await answer(0, quoteFor(2, code("SHOP5", 5)));

    expect(result.current.discountCode).toEqual(code("BULK50", 50));
  });

  it("goes back to an earlier answer for the same inputs without a new request", async () => {
    const { result, rerender } = renderQuotes(quoteFor(1, code("RENEW20", 20)));

    rerender({ selection: selectionFor({ quantity: 2 }) });
    await settle();
    rerender({ selection: selectionFor({ quantity: 1 }) });
    await settle();
    // The quantity-2 answer arrives late and is kept only for quantity 2.
    await answer(0, quoteFor(2, code("BULK50", 50)));

    expect(result.current.quote.state).toBe("ready");
    expect(result.current.discountCode).toEqual(code("RENEW20", 20));
    expect(requests).toHaveLength(1);
  });

  it("refuses an answer that echoes other inputs", async () => {
    const { result, rerender } = renderQuotes(quoteFor(1, code("RENEW20", 20)));

    rerender({ selection: selectionFor({ quantity: 2 }) });
    await settle();
    await answer(0, quoteFor(3, code("BULK50", 50)));

    expect(result.current.quote.state).toBe("failed");
    expect(result.current.discountCode).toBeNull();
  });

  it("reports a failed quote with no code, and recovers on retry", async () => {
    const { result, rerender } = renderQuotes(quoteFor(1, code("RENEW20", 20)));

    rerender({ selection: selectionFor({ quantity: 2 }) });
    await settle();
    await answer(0, new ResponseError());
    expect(result.current.quote.state).toBe("failed");
    expect(result.current.discountCode).toBeNull();
    expect(result.current.selectionDiscountCode?.("pro", false)).toBeNull();

    act(() => result.current.quote.retry());
    await settle();
    expect(result.current.quote.state).toBe("loading");
    expect(requests.map(({ params }) => params.quantity)).toEqual([2, 2]);
    await answer(1, quoteFor(2, code("BULK50", 50)));

    expect(result.current.quote.state).toBe("ready");
    expect(result.current.discountCode).toEqual(code("BULK50", 50));
  });

  it("prices renting from the rental's own quote, without asking again", async () => {
    const rentOptions = { pro: { discount_code: code("SHOP5", 5), sale_label: null } };
    const { result, rerender } = renderQuotes({ ...quoteFor(1, code("RENEW20", 20)), rent_options: rentOptions });

    rerender({ selection: selectionFor({ rent: true }) });
    await settle();
    expect(result.current.discountCode).toEqual(code("SHOP5", 5));
    expect(result.current.selectionDiscountCode?.("pro", false)).toEqual(code("RENEW20", 20));

    rerender({ selection: selectionFor({ rent: false }) });
    await settle();
    expect(result.current.discountCode).toEqual(code("RENEW20", 20));
    expect(requests).toHaveLength(0);
  });

  it("waits quietly, without asking, while the quantity is cleared, then quotes the quantity the buyer types", async () => {
    const { result, rerender } = renderQuotes(quoteFor(1, code("RENEW20", 20)));

    rerender({ selection: selectionFor({ quantity: 0 }) });
    await settle();
    expect(result.current.quote.state).toBe("incomplete");
    expect(result.current.discountCode).toBeNull();
    expect(requests).toHaveLength(0);

    rerender({ selection: selectionFor({ quantity: 3 }) });
    await settle();
    expect(result.current.quote.state).toBe("loading");
    expect(requests.map(({ params }) => params.quantity)).toEqual([3]);
    await answer(0, quoteFor(3, code("BULK50", 50)));

    expect(result.current.quote.state).toBe("ready");
    expect(result.current.discountCode).toEqual(code("BULK50", 50));
  });

  it("with no option picked, shows the code every option shares once the answer for the new inputs lands", async () => {
    const shop5 = code("SHOP5", 5);
    const { result, rerender } = renderQuotes(quoteFor(1, shop5), selectionFor({ optionId: null }));
    expect(result.current.discountCode).toBeNull();

    rerender({ selection: selectionFor({ optionId: null, quantity: 2 }) });
    await settle();
    expect(result.current.quote.state).toBe("loading");
    expect(result.current.discountCode).toBeNull();
    await answer(0, quoteFor(2, shop5));

    expect(result.current.discountCode).toEqual(shop5);
  });

  it("with no option picked, shows no code when the options get different ones", async () => {
    const { result, rerender } = renderQuotes(quoteFor(1, code("RENEW20", 20)), selectionFor({ optionId: null }));

    rerender({ selection: selectionFor({ optionId: null, quantity: 2 }) });
    await settle();
    await answer(0, quoteFor(2, code("RENEW20", 20)));

    expect(result.current.quote.state).toBe("ready");
    expect(result.current.discountCode).toBeNull();
    expect(result.current.selectionDiscountCode?.("pro", false)).toEqual(code("RENEW20", 20));
  });

  it("never asks, nor holds the buy button, when there is no code to weigh", async () => {
    const { result, rerender } = renderQuotes({ ...quoteFor(1, null), options: {} });

    rerender({ selection: selectionFor({ quantity: 5 }) });
    await settle();

    expect(result.current.quote.state).toBe("ready");
    expect(requests).toHaveLength(0);
  });
});

describe("product page while the selection's discount is being quoted", () => {
  const renderPage = (quote: { state: "ready" | "loading" | "failed" | "incomplete"; retry: () => void }) =>
    render(
      <Product
        product={product()}
        purchase={null}
        discountCode={null}
        quote={quote}
        selection={selectionFor()}
        disableAnalytics
      />,
    );

  it("gives the buy button no checkout link, and no alert or spinner, while the selection is incomplete", () => {
    renderPage({ state: "incomplete", retry: vi.fn() });

    const button = screen.getByText("Subscribe").closest("a");
    expect(button?.hasAttribute("href")).toBe(false);
    expect(button?.getAttribute("aria-busy")).toBe("false");
    expect(screen.queryByRole("progressbar")).toBeNull();
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("gives the buy button no checkout link while the quote loads", () => {
    renderPage({ state: "loading", retry: vi.fn() });

    const button = screen.getByText("Subscribe").closest("a");
    expect(button?.hasAttribute("href")).toBe(false);
    expect(button?.getAttribute("aria-busy")).toBe("true");
    expect(screen.getByRole("progressbar")).toBeTruthy();
  });

  it("offers a retry when the quote fails, and links to checkout once it is ready", () => {
    const retry = vi.fn();
    const { rerender } = renderPage({ state: "failed", retry });

    expect(screen.getByRole("alert").textContent).toContain("We couldn't check the discount for this selection.");
    expect(screen.getByText("Subscribe").closest("a")?.hasAttribute("href")).toBe(false);
    expect(screen.queryByRole("progressbar")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Try again" }));
    expect(retry).toHaveBeenCalledTimes(1);

    rerender(
      <Product
        product={product()}
        purchase={null}
        discountCode={null}
        quote={{ state: "ready", retry }}
        selection={selectionFor()}
        disableAnalytics
      />,
    );
    expect(screen.queryByRole("alert")).toBeNull();
    expect(screen.getByText("Subscribe").closest("a")?.getAttribute("href")).toContain("product=membership");
  });
});

describe("product page when the shown code expires", () => {
  it("drops the expired code from every option row, and does not bring it back when another option's code shows", () => {
    const expired = code("FLASH30", 30, new Date(Date.now() - 1_000).toISOString());
    const selectionDiscountCode = () => expired;
    const page = (discountCode: ProductDiscount) => (
      <Product
        product={product()}
        purchase={null}
        discountCode={discountCode}
        selectionDiscountCode={selectionDiscountCode}
        selection={selectionFor()}
        disableAnalytics
      />
    );
    const { rerender } = render(page(expired));

    expect(screen.getByText("Sorry, the discount code you wish to use is inactive.")).toBeTruthy();
    expect(selectorProps.at(-1)?.rowDiscount?.(selectionFor({ optionId: "basic" }))).toBeNull();

    rerender(page(code("RENEW20", 20)));
    rerender(page(expired));

    expect(screen.getByText("Sorry, the discount code you wish to use is inactive.")).toBeTruthy();
    expect(selectorProps.at(-1)?.rowDiscount?.(selectionFor({ optionId: "pro", rent: true }))).toBeNull();
  });

  it("counts down to the code now shown when the selection switches to another expiring code", async () => {
    vi.useFakeTimers();
    try {
      const later = code("LATER30", 30, new Date(Date.now() + 60_000).toISOString());
      const soon = code("SOON20", 20, new Date(Date.now() + 5_000).toISOString());
      const page = (discountCode: ProductDiscount) => (
        <Product
          product={product()}
          purchase={null}
          discountCode={discountCode}
          selectionDiscountCode={() => discountCode}
          selection={selectionFor()}
          disableAnalytics
        />
      );
      const { rerender } = render(page(later));
      rerender(page(soon));

      await act(() => vi.advanceTimersByTimeAsync(6_000));

      expect(screen.getByText("Sorry, the discount code you wish to use is inactive.")).toBeTruthy();
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("product page discount copy for the picked option", () => {
  const shop5: ProductDiscount = {
    valid: true,
    code: "SHOP5",
    discount: { ...percentOff(0), type: "fixed", cents: 500 },
  };
  const renew20 = code("RENEW20", 20);
  const codes: Record<string, ProductDiscount> = { basic: shop5, pro: renew20 };
  const page = (optionId: string | null, overrides: Partial<React.ComponentProps<typeof Product>> = {}) => (
    <Product
      product={product({ options: [tier("First Tier", 1_000), tier("Second Tier", 10_000)] })}
      purchase={null}
      discountCode={optionId ? (codes[optionId === "First Tier" ? "basic" : "pro"] ?? null) : null}
      selectionDiscountCode={(id) => codes[id === "First Tier" ? "basic" : "pro"] ?? null}
      selection={selectionFor({ optionId })}
      disableAnalytics
      {...overrides}
    />
  );
  const checkoutCode = () =>
    new URL(screen.getByText("Subscribe").closest("a")?.getAttribute("href") ?? "").searchParams.get("code");
  const rowCode = (optionId: string) => selectorProps.at(-1)?.rowDiscount?.(selectionFor({ optionId }));

  it("names the picked tier in the loyalty code's terms when another tier gets a different code", () => {
    render(page("Second Tier"));

    expect(screen.getByRole("status").textContent).toBe(
      "20% off Second Tier will be applied at checkout (Code RENEW20)",
    );
    expect(checkoutCode()).toBe("RENEW20");
    expect(rowCode("First Tier")).toMatchObject({ type: "fixed", cents: 500 });
    expect(rowCode("Second Tier")).toMatchObject({ type: "percent", percents: 20 });
  });

  it("names the picked tier in the sale banner, keeps the seller's label, and follows reselection", () => {
    const { rerender } = render(page("First Tier", { saleLabel: "Spring sale" }));

    expect(screen.getByTestId("sale-label").textContent).toBe("Spring sale");
    expect(screen.getByTestId("sale-banner").textContent).toBe("Spring sale$5 off First Tier");
    expect(checkoutCode()).toBe("SHOP5");

    rerender(page("Second Tier", { saleLabel: null }));
    expect(screen.queryByTestId("sale-banner")).toBeNull();
    expect(screen.getByRole("status").textContent).toBe(
      "20% off Second Tier will be applied at checkout (Code RENEW20)",
    );
    expect(checkoutCode()).toBe("RENEW20");
  });

  it("keeps the product-wide terms when every tier gets the same code", () => {
    const half = code("HALF", 50);
    render(page("Second Tier", { selectionDiscountCode: () => half, discountCode: half }));

    expect(screen.getByRole("status").textContent).toBe("50% off will be applied at checkout (Code HALF)");
    expect(checkoutCode()).toBe("HALF");
  });

  it("names no option on a product without options", () => {
    render(
      <Product
        product={product({
          options: [],
          is_tiered_membership: false,
          is_recurring_billing: false,
          recurrences: null,
          price_cents: 1_000,
        })}
        purchase={null}
        discountCode={renew20}
        selectionDiscountCode={() => renew20}
        selection={selectionFor({ optionId: null, recurrence: null })}
        disableAnalytics
      />,
    );

    expect(screen.getByRole("status").textContent).toBe("20% off will be applied at checkout (Code RENEW20)");
  });
});
