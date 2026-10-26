// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getPagedDiscounts: vi.fn(),
  getStatistics: vi.fn(() => Promise.resolve({ revenue_cents: 0, uses: 0 })),
  showAlert: vi.fn(),
}));

vi.mock("$app/data/offer_code", async (importOriginal) => {
  const actual = await importOriginal<typeof import("$app/data/offer_code")>();
  return { ...actual, getPagedDiscounts: mocks.getPagedDiscounts, getStatistics: mocks.getStatistics };
});

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: mocks.showAlert }));

// The layout renders the checkout nav through the generated Routes helper and Inertia links, neither
// of which this test is about.
vi.mock("$app/components/CheckoutDashboard/Layout", () => ({
  Layout: ({ children, actions }: { children: React.ReactNode; actions?: React.ReactNode }) => (
    <div>
      {actions}
      {children}
    </div>
  ),
}));

vi.mock("$app/components/LoggedInUser", () => ({
  useLoggedInUser: () => ({ policies: { checkout_offer_code: { create: true } } }),
}));
vi.mock("$app/components/CurrentSeller", () => ({
  useCurrentSeller: () => ({ timeZone: { name: "UTC" } }),
}));
vi.mock("$app/components/UserAgent", () => ({ useUserAgentInfo: () => ({ locale: "en-US" }) }));
vi.mock("$app/components/useOriginalLocation", () => ({
  useOriginalLocation: () => "http://localhost/checkout/discounts",
}));

import { AbortError, ResponseError } from "$app/utils/request";

import DiscountsPage, { DiscountsPageProps, OfferCode } from "./DiscountsPage";

vi.stubGlobal("SSR", false);

const offerCode: OfferCode = {
  id: "offer-code-1",
  can_update: true,
  name: "Launch",
  code: "launch",
  products: null,
  excluded_products: [],
  discount: { type: "percent", value: 10 },
  limit: null,
  currency_type: "usd",
  valid_at: null,
  expires_at: null,
  duration_in_billing_cycles: null,
  minimum_quantity: null,
  minimum_amount_cents: null,
  once_per_cart: false,
  existing_customers_only: false,
  new_customers_only: false,
  auto_apply: false,
  sale_label: null,
  ownership_products: [],
  ownership_duration_tiers: null,
  option_ids_by_product: {},
};

const props: DiscountsPageProps = {
  offer_codes: [offerCode],
  pages: ["discounts" as const],
  products: [],
  pagination: { page: 1, pages: 1 },
  show_black_friday_banner: false,
  black_friday_code: "blackfriday",
  black_friday_code_name: "Black Friday",
};

const renderPage = () => render(<DiscountsPage {...props} />);

const clickSort = () => fireEvent.click(screen.getByRole("columnheader", { name: "Discount" }));
const button = (name: string) => screen.getByRole<HTMLButtonElement>("button", { name });

describe("DiscountsPage loading state", () => {
  beforeEach(() => {
    mocks.getPagedDiscounts.mockReset();
    mocks.showAlert.mockReset();
  });

  afterEach(() => cleanup());

  it("leaves the create form usable after a failed list request", async () => {
    mocks.getPagedDiscounts.mockReturnValue({
      response: Promise.reject(new ResponseError("Something went wrong.")),
      cancel: () => {},
    });
    renderPage();

    clickSort();
    await waitFor(() => expect(mocks.showAlert).toHaveBeenCalledWith("Something went wrong.", "error"));

    fireEvent.click(button("New discount"));

    expect(button("Add discount").disabled).toBe(false);
    expect(button("Cancel").disabled).toBe(false);
  });

  it("keeps the flag while the newest request is still in flight after an earlier one is cancelled", async () => {
    let rejectFirst: (reason: unknown) => void = () => {};
    let resolveNewest: (value: {
      offer_codes: OfferCode[];
      pagination: { page: number; pages: number };
    }) => void = () => {};
    mocks.getPagedDiscounts
      .mockReturnValueOnce({
        response: new Promise((_, reject) => (rejectFirst = reject)),
        cancel: () => rejectFirst(new AbortError()),
      })
      .mockReturnValueOnce({
        response: new Promise((resolve) => (resolveNewest = resolve)),
        cancel: () => {},
      });
    renderPage();

    clickSort();
    clickSort();
    expect(mocks.getPagedDiscounts).toHaveBeenCalledTimes(2);
    // Let the cancelled request's rejection settle before reading the flag.
    await new Promise((resolve) => setTimeout(resolve, 0));
    fireEvent.click(button("New discount"));
    expect(button("Adding discount...").disabled).toBe(true);

    resolveNewest({ offer_codes: [offerCode], pagination: { page: 1, pages: 1 } });
    await waitFor(() => expect(button("Add discount").disabled).toBe(false));
  });
});
