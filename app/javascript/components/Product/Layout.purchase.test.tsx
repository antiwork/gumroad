// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { Product as ProductData, ProductDiscount, Purchase } from "$app/components/Product";
import { Layout } from "$app/components/Product/Layout";
import { showAlert } from "$app/components/server-components/Alert";

const session = vi.hoisted(() => ({ loggedIn: false }));
vi.stubGlobal("SSR", false);
vi.stubGlobal("Routes", {
  checkout_url: () => "https://example.com/checkout",
  license_key_lookup_url: () => "https://example.com/license-key-lookup",
});
vi.mock("$app/data/user_action_event", () => ({ trackUserProductAction: vi.fn().mockResolvedValue(undefined) }));
vi.mock("$app/data/view_event", () => ({ incrementProductViews: vi.fn() }));
vi.mock("$app/utils/user_analytics", () => ({
  startTrackingForSeller: vi.fn(),
  trackBuyerCurrencyDisplayView: vi.fn(),
  trackProductEvent: vi.fn(),
}));
vi.mock("$app/components/LoggedInUser", () => ({ useLoggedInUser: () => (session.loggedIn ? { id: "buyer" } : null) }));
vi.mock("$app/components/RichTextEditor", () => ({ useRichTextEditor: () => null }));
vi.mock("$app/components/useAddThirdPartyAnalytics", () => ({ useAddThirdPartyAnalytics: () => vi.fn() }));
vi.mock("$app/components/useOriginalLocation", () => ({
  useOriginalLocation: () => "https://example.com/products/bundle",
}));
vi.mock("$app/components/useRunOnce", () => ({ useRunOnce: vi.fn() }));
vi.mock("$app/components/DomainSettings", () => ({
  useAppDomain: () => "example.com",
  useDomains: () => ({ scheme: "https", rootDomain: "example.com" }),
}));
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => false }));
vi.mock("$app/components/Product/ShareSection", () => ({ ShareSection: () => null }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

let setInlineVisible: (visible: boolean) => void;
let notifyResize: () => void;
const disconnectIntersection = vi.fn();
const resizeObservers: {
  notify: () => void;
  observe: ReturnType<typeof vi.fn>;
  disconnect: ReturnType<typeof vi.fn>;
}[] = [];

beforeEach(() => {
  session.loggedIn = false;
  resizeObservers.length = 0;
  notifyResize = () => resizeObservers.forEach((observer) => observer.notify());
  vi.stubGlobal(
    "IntersectionObserver",
    class {
      constructor(callback: (entries: { isIntersecting: boolean }[]) => void) {
        setInlineVisible = (visible) => callback([{ isIntersecting: visible }]);
      }
      observe() {}
      disconnect = disconnectIntersection;
    },
  );
  vi.stubGlobal(
    "ResizeObserver",
    class {
      constructor(callback: () => void) {
        this.notify = callback;
        resizeObservers.push(this);
      }
      notify: () => void;
      observe = vi.fn();
      disconnect = vi.fn();
    },
  );
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.clearAllMocks();
});

const product: ProductData = {
  id: "bundle",
  name: "Bundle",
  seller: {
    id: "seller",
    name: "Measure Twice Digital With A Very Long Creator Name",
    avatar_url: "https://example.com/avatar.png",
    profile_url: "https://example.com/measure-twice",
    is_verified: false,
  },
  collaborating_user: null,
  covers: [],
  main_cover_id: null,
  quantity_remaining: null,
  currency_code: "usd",
  long_url: "https://example.com/products/bundle",
  duration_in_months: null,
  is_sales_limited: false,
  price_cents: 1_000,
  pwyw: null,
  installment_plan: null,
  ratings: null,
  is_legacy_subscription: false,
  is_tiered_membership: false,
  is_recurring_billing: false,
  is_physical: false,
  custom_view_content_button_text: null,
  custom_button_text_option: null,
  permalink: "bundle",
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
};

const option = (id: string): ProductData["options"][number] => ({
  id,
  name: id,
  quantity_left: null,
  description: "",
  price_difference_cents: 0,
  recurrence_price_values: null,
  is_pwyw: false,
  duration_in_minutes: null,
});

const renderLayout = (p: ProductData, discountCode: ProductDiscount = null, purchase: Purchase | null = null) => {
  const view = render(
    <Layout
      product={p}
      purchase={purchase}
      discount_code={discountCode}
      wishlists={[]}
      main_section_index={0}
      sections={[]}
      currency_code="usd"
      creator_profile={{
        external_id: "seller",
        name: "Seller",
        avatar_url: "https://example.com/avatar.png",
        twitter_handle: null,
        subdomain: null,
        is_verified: false,
        can_edit: false,
      }}
    />,
  );
  const bar = screen.getByRole("region", { name: "Product information bar" });
  act(() => setInlineVisible(false));
  return { ...view, bar };
};

const getCta = (bar: HTMLElement, surface: "sticky" | "inline", name: string) => {
  const scope = surface === "sticky" ? bar : screen.getByRole("article");
  return within(scope).getByRole("link", { name });
};

const checkoutParams = (link: HTMLElement) => new URL(link.getAttribute("href") ?? "").searchParams;

const halfOff: ProductDiscount = {
  valid: true,
  code: "HALF",
  discount: {
    type: "percent",
    percents: 50,
    product_ids: null,
    expires_at: null,
    minimum_quantity: null,
    duration_in_billing_cycles: null,
    minimum_amount_cents: null,
  },
};

for (const surface of ["sticky", "inline"] as const) {
  describe(`${surface} purchase flow`, () => {
    it("checks out with the SKU selected in the page", () => {
      const { bar } = renderLayout({ ...product, options: [option("standard"), option("deluxe")] });
      expect(fireEvent.click(getCta(bar, surface, "Choose an option"))).toBe(false);
      expect(document.activeElement).toBe(screen.getByRole("radio", { name: "standard" }));
      fireEvent.click(screen.getByRole("radio", { name: "deluxe" }));
      const cta = getCta(bar, surface, "I want this!");
      expect(fireEvent.click(cta)).toBe(true);
      expect(checkoutParams(cta).get("option")).toBe("deluxe");
      expect(checkoutParams(cta).get("product")).toBe(product.permalink);
    });

    it.each([
      ["", false, null],
      ["4", false, null],
      ["5", true, "1000"],
      ["7", true, "1400"],
    ] as const)("validates a discounted PWYW amount of '%s'", (amount, navigates, checkoutPrice) => {
      const { bar } = renderLayout({ ...product, pwyw: { suggested_price_cents: null } }, halfOff);
      const input = screen.getByLabelText("Name a fair price:");
      if (amount) fireEvent.change(input, { target: { value: amount } });
      const cta = getCta(bar, surface, "I want this!");
      expect(fireEvent.click(cta)).toBe(navigates);
      if (navigates) {
        expect(checkoutParams(cta).get("price")).toBe(checkoutPrice);
        expect(checkoutParams(cta).get("code")).toBe("HALF");
        expect(showAlert).not.toHaveBeenCalled();
      } else {
        expect(document.activeElement).toBe(input);
        expect(input.closest("fieldset")?.classList.contains("danger")).toBe(true);
        expect(showAlert).toHaveBeenCalledWith(
          amount ? "Minimum price for this product is $5." : "You must input an amount",
          amount ? "error" : "warning",
        );
      }
    });

    it.each([false, true])("offers subscription choices for a lapsed=%s subscriber", (lapsed) => {
      session.loggedIn = true;
      const membershipProduct: ProductData = {
        ...product,
        is_recurring_billing: true,
        is_tiered_membership: true,
        recurrences: { default: "monthly", enabled: [{ recurrence: "monthly", price_cents: 1000, id: "monthly" }] },
        options: ["standard", "deluxe"].map((id) => ({
          ...option(id),
          recurrence_price_values: { monthly: { price_cents: 1000, suggested_price_cents: null } },
        })),
      };
      const purchase: Purchase = {
        id: "purchase",
        email_digest: "",
        created_at: "2026-01-01",
        review: null,
        review_account_name: null,
        should_show_receipt: false,
        was_paid: true,
        is_gift_receiver_purchase: false,
        content_url: null,
        show_view_content_button_on_product_page: false,
        total_price_including_tax_and_shipping: "$10",
        subscription_has_lapsed: lapsed,
        membership: { tier_name: "standard", tier_description: null, manage_url: "https://example.com/subscription" },
      };
      const { bar } = renderLayout(membershipProduct, null, purchase);
      expect(fireEvent.click(getCta(bar, surface, "Choose an option"))).toBe(false);
      expect(screen.queryByRole("dialog")).toBeNull();
      fireEvent.click(screen.getByRole("radio", { name: "deluxe" }));
      expect(fireEvent.click(getCta(bar, surface, "Purchase again"))).toBe(false);
      const dialog = screen.getByRole("dialog", {
        name: lapsed ? "Resume your previous subscription?" : "You already have an active subscription",
      });
      const params = checkoutParams(within(dialog).getByRole("link", { name: "Start a new subscription" }));
      expect(params.get("force_new_subscription")).toBe("true");
      expect(params.get("option")).toBe("deluxe");
      expect(params.get("recurrence")).toBe("monthly");
      if (lapsed)
        expect(within(dialog).getByRole("link", { name: "Resume subscription" }).getAttribute("href")).toBe(
          purchase.membership?.manage_url,
        );
      fireEvent.click(within(dialog).getByRole("button", { name: "Close" }));
      expect(screen.queryByRole("dialog")).toBeNull();
    });
  });
}

it("updates sticky height after selecting a SKU and resizing, then disconnects observers", () => {
  let extraHeight = 0;
  vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
    return new DOMRect(0, 0, 0, (this.querySelector("[itemprop='price']") ? 120 : 80) + extraHeight);
  });
  const { bar, unmount } = renderLayout({ ...product, options: [option("standard"), option("deluxe")] });
  expect(bar.style.height).toBe("80px");
  fireEvent.click(screen.getByRole("radio", { name: "deluxe" }));
  act(() => notifyResize());
  expect(bar.style.height).toBe("120px");
  const observer = resizeObservers.find((observer) =>
    observer.observe.mock.calls.some(([element]) => element === bar.firstElementChild),
  );
  expect(observer).toBeDefined();
  extraHeight = 20;
  act(() => notifyResize());
  expect(bar.style.height).toBe("140px");
  act(() => setInlineVisible(true));
  expect(bar.style.height).toBe("0px");
  act(() => setInlineVisible(false));
  expect(bar.style.height).toBe("140px");
  unmount();
  expect(observer?.disconnect).toHaveBeenCalledTimes(1);
  expect(disconnectIntersection).toHaveBeenCalledTimes(1);
});
