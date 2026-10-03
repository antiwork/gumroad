// @vitest-environment happy-dom
import { renderHook } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { useSelectionFromUrl, type Product } from "$app/components/Product";
import type { Option } from "$app/components/Product/ConfigurationSelector";

const location = vi.hoisted(() => ({ url: "https://example.com/l/free" }));

vi.mock("$app/components/useOriginalLocation", () => ({ useOriginalLocation: () => location.url }));

const option = (overrides: Partial<Option> = {}): Option => ({
  id: "option",
  name: "Option",
  quantity_left: null,
  description: "",
  price_difference_cents: 0,
  recurrence_price_values: null,
  is_pwyw: false,
  duration_in_minutes: null,
  ...overrides,
});

const freeProduct = (overrides: Partial<Product> = {}): Product => ({
  id: "free",
  name: "Free",
  seller: null,
  collaborating_user: null,
  covers: [],
  main_cover_id: null,
  quantity_remaining: null,
  currency_code: "usd",
  long_url: "https://example.com/l/free",
  duration_in_months: null,
  is_sales_limited: false,
  price_cents: 0,
  pwyw: { suggested_price_cents: null, default_price_cents: 0 },
  installment_plan: null,
  ratings: null,
  is_legacy_subscription: false,
  is_tiered_membership: false,
  is_recurring_billing: false,
  is_physical: false,
  custom_view_content_button_text: null,
  custom_button_text_option: null,
  permalink: "free",
  preorder: null,
  description_html: "",
  is_compliance_blocked: false,
  is_published: true,
  is_stream_only: false,
  streamable: false,
  is_quantity_enabled: false,
  is_multiseat_license: false,
  is_licensed: false,
  native_type: "digital",
  sales_count: null,
  summary: null,
  attributes: [],
  free_trial: null,
  rental: null,
  recurrences: null,
  options: [],
  analytics: { google_analytics_id: null, facebook_pixel_id: null, tiktok_pixel_id: null, free_sales: true },
  has_third_party_analytics: false,
  ppp_details: null,
  can_edit: false,
  refund_policy: null,
  bundle_products: [],
  public_files: [],
  ...overrides,
});

const priceFor = (product: Product, search = "") => {
  location.url = `https://example.com/l/free${search}`;
  return renderHook(() => useSelectionFromUrl(product)).result.current[0].price;
};

describe("useSelectionFromUrl price", () => {
  it("starts at the default amount the server sends", () => {
    expect(priceFor(freeProduct())).toEqual({ value: 0, error: false });
  });

  it("starts at the default amount when the product has options", () => {
    expect(priceFor(freeProduct({ options: [option(), option({ id: "other" })] }))).toEqual({ value: 0, error: false });
  });

  it("keeps the ?price= prefill", () => {
    expect(priceFor(freeProduct(), "?price=5")).toEqual({ value: 500, error: false });
  });

  it("keeps an explicit ?price=0", () => {
    expect(priceFor(freeProduct(), "?price=0")).toEqual({ value: 0, error: false });
  });

  it("leaves the box empty for an invalid ?price= value", () => {
    expect(priceFor(freeProduct(), "?price=abc")).toEqual({ value: null, error: false });
  });

  it("leaves the box empty when the server sends no default", () => {
    expect(priceFor(freeProduct({ pwyw: { suggested_price_cents: 500, default_price_cents: null } }))).toEqual({
      value: null,
      error: false,
    });
    expect(priceFor(freeProduct({ pwyw: { suggested_price_cents: null } }))).toEqual({ value: null, error: false });
  });

  it("leaves a product that is not pay-what-you-want untouched", () => {
    expect(priceFor(freeProduct({ pwyw: null }))).toEqual({ value: null, error: false });
  });
});
