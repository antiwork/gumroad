// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { type Product as ProductData } from "$app/components/Product";
import type { PriceSelection } from "$app/components/Product/ConfigurationSelector";
import { ShareSection } from "$app/components/Product/ShareSection";

vi.stubGlobal("SSR", false);
vi.stubGlobal("Routes", {
  login_url: () => "https://example.com/login",
  wishlists_url: () => "https://example.com/wishlists",
});

vi.mock("$app/components/LoggedInUser", () => ({ useLoggedInUser: () => null }));
vi.mock("$app/components/DomainSettings", () => ({
  useAppDomain: () => "example.com",
  useDomains: () => ({ scheme: "https", rootDomain: "example.com" }),
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

afterEach(cleanup);

const selection: PriceSelection = {
  rent: false,
  optionId: null,
  price: { error: false, value: null },
  quantity: 1,
  recurrence: "monthly",
  callStartTime: null,
  payInInstallments: false,
};

const product = (waitlistEnabled: boolean): ProductData => ({
  id: "membership",
  name: "Membership",
  seller: {
    id: "seller-1",
    name: "Testy",
    avatar_url: "",
    profile_url: "https://example.com/testy",
    is_verified: false,
  },
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
  is_published: false,
  is_stream_only: false,
  streamable: false,
  is_quantity_enabled: false,
  is_multiseat_license: false,
  is_licensed: false,
  native_type: "membership",
  sales_count: null,
  summary: null,
  attributes: [],
  free_trial: null,
  rental: null,
  recurrences: { default: "monthly", enabled: [{ recurrence: "monthly", price_cents: 0, id: "monthly" }] },
  options: [],
  analytics: { google_analytics_id: null, facebook_pixel_id: null, tiktok_pixel_id: null, free_sales: true },
  has_third_party_analytics: false,
  ppp_details: null,
  can_edit: false,
  waitlist_enabled: waitlistEnabled,
  waitlist_count: null,
  follow_recaptcha_site_key: null,
  refund_policy: null,
  bundle_products: [],
  public_files: [],
});

describe("share section on a waitlist page", () => {
  it("keeps the share button and drops the wishlist", () => {
    render(<ShareSection product={product(true)} selection={selection} wishlists={[]} />);

    expect(screen.getByLabelText("Share")).toBeTruthy();
    expect(screen.queryByLabelText("Add to wishlist")).toBeNull();
  });

  it("keeps the wishlist on every other page", () => {
    render(<ShareSection product={product(false)} selection={selection} wishlists={[]} />);

    expect(screen.getByLabelText("Add to wishlist")).toBeTruthy();
  });
});
