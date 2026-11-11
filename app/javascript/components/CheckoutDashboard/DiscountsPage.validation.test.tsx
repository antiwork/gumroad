// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getPagedDiscounts: vi.fn(() => ({
    response: Promise.resolve({ offer_codes: [], pagination: { page: 1, pages: 1 } }),
    cancel: () => {},
  })),
  getStatistics: vi.fn(() => Promise.resolve({ uses: { total: 0, products: {} }, revenue_cents: 0 })),
  showAlert: vi.fn(),
}));

vi.mock("$app/data/offer_code", async (importOriginal) => {
  const actual = await importOriginal<typeof import("$app/data/offer_code")>();
  return {
    ...actual,
    getPagedDiscounts: mocks.getPagedDiscounts,
    getStatistics: mocks.getStatistics,
  };
});

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: mocks.showAlert }));

// The layout renders the checkout nav through the generated Routes helper and Inertia links, neither
// of which these tests are about.
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
  ownership_option_ids_by_product: {},
  ownership_options: {},
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

const openEditor = () => {
  render(<DiscountsPage {...props} />);
  fireEvent.click(screen.getByRole("button", { name: "Edit" }));
};

const save = () => fireEvent.click(screen.getByRole("button", { name: "Save changes" }));

// A field that only fails one of the checks the form runs on submit used to return with no alert at
// all, so "Save changes" read as a broken button.
describe("DiscountsPage save validation", () => {
  beforeEach(() => {
    mocks.showAlert.mockReset();
  });

  afterEach(() => cleanup());

  it("names the date order problem when the end date is before the start date", () => {
    openEditor();
    fireEvent.click(screen.getByLabelText("Limit validity period"));
    fireEvent.click(screen.getByLabelText("No end date"));

    const validUntil = screen.getByLabelText("Valid until");
    fireEvent.change(validUntil, { target: { value: "2020-01-01T00:00" } });
    fireEvent.blur(validUntil);
    save();

    expect(mocks.showAlert).toHaveBeenCalledWith(
      "The discount code's start date must be earlier than its end date.",
      "error",
    );
    expect(document.activeElement).toBe(validUntil);
  });

  it("rejects an end date equal to the start date", () => {
    openEditor();
    fireEvent.click(screen.getByLabelText("Limit validity period"));
    fireEvent.click(screen.getByLabelText("No end date"));

    const message = "The discount code's start date must be earlier than its end date.";
    const validFrom = screen.getByLabelText("Valid from");
    const validUntil = screen.getByLabelText("Valid until");
    for (const field of [validFrom, validUntil]) {
      fireEvent.change(field, { target: { value: "2030-01-01T00:00" } });
      fireEvent.blur(field);
    }
    save();

    expect(mocks.showAlert).toHaveBeenCalledWith(message, "error");
    expect(document.activeElement).toBe(validUntil);
    expect(validUntil.getAttribute("aria-invalid")).toBe("true");
    expect(validUntil.closest("fieldset")?.textContent).toContain(message);
  });

  it("keeps the reason under the field until the field is corrected", () => {
    openEditor();
    fireEvent.click(screen.getByLabelText("Limit validity period"));
    fireEvent.click(screen.getByLabelText("No end date"));

    const message = "The discount code's start date must be earlier than its end date.";
    const validUntil = screen.getByLabelText("Valid until");
    fireEvent.change(validUntil, { target: { value: "2020-01-01T00:00" } });
    fireEvent.blur(validUntil);
    expect(screen.queryByText(message)).toBeNull();
    save();

    expect(validUntil.closest("fieldset")?.textContent).toContain(message);
    expect(validUntil.getAttribute("aria-describedby")).toBe(screen.getByText(message).id);

    fireEvent.change(validUntil, { target: { value: "2999-01-01T00:00" } });
    fireEvent.blur(validUntil);
    expect(screen.queryByText(message)).toBeNull();
    expect(validUntil.getAttribute("aria-describedby")).toBeNull();
  });

  it.each([
    [
      "Valid from is moved before the end date",
      () => {
        const validFrom = screen.getByLabelText("Valid from");
        fireEvent.change(validFrom, { target: { value: "2019-01-01T00:00" } });
        fireEvent.blur(validFrom);
      },
    ],
    ["No end date is chosen", () => fireEvent.click(screen.getByLabelText("No end date"))],
  ])("clears the date reason when %s", (_name, correct) => {
    openEditor();
    fireEvent.click(screen.getByLabelText("Limit validity period"));
    fireEvent.click(screen.getByLabelText("No end date"));

    const message = "The discount code's start date must be earlier than its end date.";
    const validUntil = screen.getByLabelText("Valid until");
    fireEvent.change(validUntil, { target: { value: "2020-01-01T00:00" } });
    fireEvent.blur(validUntil);
    save();
    expect(screen.getByText(message)).toBeTruthy();

    correct();
    expect(screen.queryByText(message)).toBeNull();
    expect(validUntil.getAttribute("aria-invalid")).not.toBe("true");
  });

  it("shows the amount and tier reasons inline", () => {
    openEditor();
    const percentage = screen.getByRole("textbox", { name: "Percentage" });
    fireEvent.change(percentage, { target: { value: "" } });
    save();
    expect(percentage.getAttribute("aria-describedby")).toBe(screen.getByText("Please enter a discount amount.").id);
    fireEvent.change(percentage, { target: { value: "10" } });
    expect(screen.queryByText("Please enter a discount amount.")).toBeNull();

    fireEvent.click(screen.getByLabelText("Tier discount by ownership duration"));
    const tierPercentage = screen.getByLabelText("Tier 1 percentage");
    fireEvent.change(tierPercentage, { target: { value: "" } });
    save();
    expect(tierPercentage.getAttribute("aria-describedby")).toBe(
      screen.getByText("Each tier percentage must be between 0 and 100.").id,
    );
    fireEvent.change(tierPercentage, { target: { value: "5" } });
    expect(screen.queryByText("Each tier percentage must be between 0 and 100.")).toBeNull();
  });

  it("asks for the amount when the discount field is emptied", () => {
    openEditor();

    // Not getByLabelText: the "Percentage" radio shares that accessible name.
    const percentage = screen.getByRole("textbox", { name: "Percentage" });
    fireEvent.change(percentage, { target: { value: "" } });
    save();

    expect(mocks.showAlert).toHaveBeenCalledWith("Please enter a discount amount.", "error");
    expect(document.activeElement).toBe(percentage);
  });

  it("names the tier problem when a tier percentage is emptied", () => {
    openEditor();
    fireEvent.click(screen.getByLabelText("Tier discount by ownership duration"));

    const tierPercentage = screen.getByLabelText("Tier 1 percentage");
    fireEvent.change(tierPercentage, { target: { value: "" } });
    save();

    expect(mocks.showAlert).toHaveBeenCalledWith("Each tier percentage must be between 0 and 100.", "error");
    expect(document.activeElement).toBe(tierPercentage);
  });

  it("reports the tier percentage before the starting month when both are cleared", () => {
    openEditor();
    fireEvent.click(screen.getByLabelText("Tier discount by ownership duration"));
    fireEvent.click(screen.getByRole("button", { name: "Add tier" }));

    const tierPercentage = screen.getByLabelText("Tier 2 percentage");
    fireEvent.change(tierPercentage, { target: { value: "" } });
    fireEvent.change(screen.getByLabelText("Tier 2 starting month"), { target: { value: "" } });
    save();

    expect(mocks.showAlert).toHaveBeenCalledWith("Each tier percentage must be between 0 and 100.", "error");
    expect(document.activeElement).toBe(tierPercentage);
  });
});
