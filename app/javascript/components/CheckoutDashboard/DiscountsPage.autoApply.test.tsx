// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { buildDiscountPayload, DiscountPayload } from "$app/data/offer_code";

import DiscountsPage, {
  DiscountsPageProps,
  MAX_SALE_LABEL_LENGTH,
  OfferCode,
} from "$app/components/CheckoutDashboard/DiscountsPage";

vi.mock("$app/components/UserAgent", () => ({ useUserAgentInfo: () => ({ isMobile: false, locale: "en-US" }) }));
vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
vi.mock("$app/components/LoggedInUser", () => ({
  useLoggedInUser: () => ({ policies: { checkout_offer_code: { create: true, update: true } } }),
}));
vi.mock("$app/components/CurrentSeller", () => ({ useCurrentSeller: () => ({ timeZone: { name: "UTC" } }) }));
vi.mock("$app/components/useOriginalLocation", () => ({
  useOriginalLocation: () => "https://gumroad.com/checkout/discounts",
}));
vi.mock("$app/components/CheckoutDashboard/Layout", () => ({
  Layout: ({ children, actions }: { children: React.ReactNode; actions: React.ReactNode }) => (
    <div>
      {actions}
      {children}
    </div>
  ),
}));
vi.mock("$app/data/offer_code", async (importOriginal) => ({
  ...(await importOriginal<typeof import("$app/data/offer_code")>()),
  getStatistics: () => new Promise(() => {}),
}));

const offerCode = (overrides: Partial<OfferCode> = {}): OfferCode => ({
  id: "oc1",
  can_update: true,
  name: "Black Friday",
  code: "bf30",
  discount: { type: "percent", value: 30 },
  products: null,
  excluded_products: [],
  limit: null,
  currency_type: "usd",
  valid_at: null,
  expires_at: null,
  minimum_quantity: null,
  duration_in_billing_cycles: null,
  minimum_amount_cents: null,
  once_per_cart: false,
  existing_customers_only: false,
  auto_apply: false,
  sale_label: null,
  ownership_products: [],
  ownership_duration_tiers: null,
  option_ids_by_product: {},
  ...overrides,
});

const props = (codes: OfferCode[]): DiscountsPageProps => ({
  offer_codes: codes,
  pages: [],
  products: [],
  pagination: { page: 1, pages: 1 },
  show_black_friday_banner: false,
  black_friday_code: "BLACKFRIDAY2025",
  black_friday_code_name: "Black Friday",
});

describe("DiscountsPage shop-wide auto-apply", () => {
  afterEach(cleanup);

  it("serializes auto_apply and sale_label, dropping the label when auto apply is off", () => {
    const base: Omit<DiscountPayload, "autoApply" | "saleLabel"> = {
      name: "BF",
      code: "bf30",
      discount: { type: "percent", value: 30 },
      selectedProductIds: [],
      selectedOptionIds: [],
      excludedProductIds: [],
      currencyCode: null,
      maxQuantity: null,
      universal: true,
      validAt: null,
      expiresAt: null,
      minimumQuantity: null,
      durationInBillingCycles: null,
      minimumAmount: null,
      oncePerCart: false,
      existingCustomersOnly: false,
      ownershipProductIds: [],
      ownershipDurationTiers: null,
    };

    expect(buildDiscountPayload({ ...base, autoApply: true, saleLabel: "Black Friday" })).toMatchObject({
      auto_apply: true,
      sale_label: "Black Friday",
    });
    expect(buildDiscountPayload({ ...base, autoApply: false, saleLabel: "Black Friday" })).toMatchObject({
      auto_apply: false,
      sale_label: null,
    });
  });

  it("shows the toggle for an All products code and reveals the label input when turned on", () => {
    render(<DiscountsPage {...props([offerCode()])} />);
    fireEvent.click(screen.getByRole("button", { name: "New discount" }));

    expect(screen.queryByLabelText("Apply automatically on product pages")).toBeNull();
    fireEvent.click(screen.getByLabelText("All products"));
    const toggle = screen.getByLabelText("Apply automatically on product pages");
    expect(screen.queryByLabelText("Sale label (optional)")).toBeNull();

    fireEvent.click(toggle);
    const label = screen.getByLabelText("Sale label (optional)");
    fireEvent.change(label, { target: { value: "Cyber week" } });
    expect(label).toHaveProperty("value", "Cyber week");
  });

  it("puts the sale label in its own field after the toggle, with a running character count", () => {
    render(<DiscountsPage {...props([offerCode()])} />);
    fireEvent.click(screen.getByRole("button", { name: "New discount" }));
    fireEvent.click(screen.getByLabelText("All products"));
    const toggle = screen.getByLabelText("Apply automatically on product pages");
    fireEvent.click(toggle);

    const input = screen.getByLabelText("Sale label (optional)");
    const inputs = [...document.querySelectorAll("input")];
    expect(inputs.indexOf(toggle)).toBeLessThan(inputs.indexOf(input));
    const toggleLegends = [...(toggle.closest("fieldset")?.querySelectorAll("legend") ?? [])];
    expect(toggleLegends.some((legend) => legend.textContent.includes("Sale label"))).toBe(false);
    expect(input).toHaveProperty("maxLength", MAX_SALE_LABEL_LENGTH);

    const hint = document.getElementById(input.getAttribute("aria-describedby") ?? "");
    expect(hint?.textContent).toContain(`0 of ${MAX_SALE_LABEL_LENGTH} characters used`);
    fireEvent.change(input, { target: { value: "Cyber week" } });
    expect(hint?.textContent).toContain(`10 of ${MAX_SALE_LABEL_LENGTH} characters used`);
  });

  it("preloads the saved values when editing and marks the code as applied automatically", () => {
    render(<DiscountsPage {...props([offerCode({ auto_apply: true, sale_label: "Easter" })])} />);
    fireEvent.click(screen.getByText("Black Friday"));
    expect(screen.getByText("Applied automatically")).toBeTruthy();
    expect(screen.getByText("On product pages (Easter)")).toBeTruthy();
  });
});
