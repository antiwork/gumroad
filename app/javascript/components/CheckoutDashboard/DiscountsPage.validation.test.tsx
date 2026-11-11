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

const openEditor = (overrides: Partial<OfferCode> = {}) => {
  render(<DiscountsPage {...props} offer_codes={[{ ...offerCode, ...overrides }]} />);
  fireEvent.click(screen.getByRole("button", { name: "Edit" }));
};

const save = () => fireEvent.click(screen.getByRole("button", { name: "Save changes" }));

const describedBy = (field: HTMLElement) =>
  (field.getAttribute("aria-describedby") ?? "")
    .split(" ")
    .filter(Boolean)
    .map((id) => document.getElementById(id)?.textContent);

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

  it("describes each invalid tier field by its own reason", () => {
    openEditor();
    fireEvent.click(screen.getByLabelText("Tier discount by ownership duration"));
    fireEvent.click(screen.getByRole("button", { name: "Add tier" }));

    const tier1Percentage = screen.getByLabelText("Tier 1 percentage");
    const tier2Months = screen.getByLabelText("Tier 2 starting month");
    fireEvent.change(tier1Percentage, { target: { value: "" } });
    fireEvent.change(tier2Months, { target: { value: "0" } });
    save();

    expect(describedBy(tier1Percentage)).toEqual(["Each tier percentage must be between 0 and 100."]);
    expect(tier2Months.getAttribute("aria-invalid")).toBe("true");
    expect(describedBy(tier2Months)).toEqual(["Each tier needs a different starting month."]);
  });

  it("keeps a tier's reason when another tier is fixed or removed", () => {
    openEditor();
    fireEvent.click(screen.getByLabelText("Tier discount by ownership duration"));
    fireEvent.click(screen.getByRole("button", { name: "Add tier" }));
    fireEvent.click(screen.getByRole("button", { name: "Add tier" }));

    const message = "Each tier percentage must be between 0 and 100.";
    const tier1Percentage = screen.getByLabelText("Tier 1 percentage");
    const tier2Percentage = screen.getByLabelText("Tier 2 percentage");
    fireEvent.change(tier1Percentage, { target: { value: "" } });
    fireEvent.change(tier2Percentage, { target: { value: "" } });
    save();

    fireEvent.change(tier1Percentage, { target: { value: "5" } });
    expect(tier1Percentage.getAttribute("aria-invalid")).not.toBe("true");
    expect(describedBy(tier1Percentage)).toEqual([]);
    expect(tier2Percentage.getAttribute("aria-invalid")).toBe("true");
    expect(describedBy(tier2Percentage)).toEqual([message]);

    fireEvent.click(screen.getByRole("button", { name: "Remove tier 3" }));
    expect(tier2Percentage.getAttribute("aria-invalid")).toBe("true");
    expect(describedBy(tier2Percentage)).toEqual([message]);
  });

  it("asks for a starting month when a tier's is emptied", () => {
    openEditor();
    fireEvent.click(screen.getByLabelText("Tier discount by ownership duration"));
    fireEvent.click(screen.getByRole("button", { name: "Add tier" }));

    const message = "Please enter a starting month.";
    const tier2Months = screen.getByLabelText("Tier 2 starting month");
    fireEvent.change(tier2Months, { target: { value: "" } });
    save();

    expect(mocks.showAlert).toHaveBeenCalledWith(message, "error");
    expect(document.activeElement).toBe(tier2Months);
    expect(screen.getByText(message)).toBeTruthy();
    expect(describedBy(tier2Months)).toEqual([message]);
  });

  it("names the first tier's start under its row when it does not start at 0 months", () => {
    openEditor({
      ownership_duration_tiers: [
        { months: 3, amount_percentage: 10 },
        { months: 6, amount_percentage: 20 },
      ],
    });
    save();

    const message = "The first tier must start at 0 months.";
    const tier1Percentage = screen.getByLabelText("Tier 1 percentage");
    expect(mocks.showAlert).toHaveBeenCalledWith(message, "error");
    expect(document.activeElement).toBe(tier1Percentage);
    expect(screen.getByText(message).parentElement?.contains(tier1Percentage)).toBe(true);
    expect(screen.getByText(message).parentElement?.contains(screen.getByLabelText("Tier 2 percentage"))).toBe(false);
    expect(tier1Percentage.getAttribute("aria-invalid")).toBe("true");
    expect(describedBy(tier1Percentage)).toEqual([message]);
  });

  it("focuses the first tier's start reason before a later tier's reason", () => {
    openEditor({
      ownership_duration_tiers: [
        { months: 3, amount_percentage: 10 },
        { months: 6, amount_percentage: 20 },
      ],
    });
    fireEvent.change(screen.getByLabelText("Tier 2 percentage"), { target: { value: "" } });
    save();

    expect(mocks.showAlert).toHaveBeenCalledWith("The first tier must start at 0 months.", "error");
    expect(document.activeElement).toBe(screen.getByLabelText("Tier 1 percentage"));
  });

  it("keeps the first tier's start reason with the other tier reasons when tiers are turned off and on", () => {
    openEditor({
      ownership_duration_tiers: [
        { months: 3, amount_percentage: 10 },
        { months: 6, amount_percentage: 20 },
      ],
    });
    fireEvent.change(screen.getByLabelText("Tier 2 percentage"), { target: { value: "" } });
    save();

    const tiersToggle = screen.getByLabelText("Tier discount by ownership duration");
    fireEvent.click(tiersToggle);
    fireEvent.change(screen.getByLabelText("Name"), { target: { value: "" } });
    save();
    fireEvent.click(tiersToggle);

    expect(describedBy(screen.getByLabelText("Tier 1 percentage"))).toEqual(["The first tier must start at 0 months."]);
    expect(describedBy(screen.getByLabelText("Tier 2 percentage"))).toEqual([
      "Each tier percentage must be between 0 and 100.",
    ]);
  });

  it("clears the first tier's start reason once a tier starting at 0 months is added", () => {
    openEditor({
      ownership_duration_tiers: [
        { months: 3, amount_percentage: 10 },
        { months: 6, amount_percentage: 20 },
      ],
    });
    save();

    const message = "The first tier must start at 0 months.";
    expect(document.activeElement).toBe(screen.getByLabelText("Tier 1 percentage"));
    expect(describedBy(screen.getByLabelText("Tier 1 percentage"))).toEqual([message]);

    fireEvent.click(screen.getByRole("button", { name: "Add tier" }));
    const tier3Months = screen.getByLabelText("Tier 3 starting month");
    fireEvent.change(tier3Months, { target: { value: "0" } });
    fireEvent.blur(tier3Months);

    expect(screen.queryByText(message)).toBeNull();
    for (const field of screen.getAllByLabelText(/^Tier \d+ (percentage|starting month)$/u)) {
      expect(field.getAttribute("aria-invalid")).not.toBe("true");
      expect(describedBy(field)).toEqual([]);
    }
  });

  it("clears a duplicate starting month reason as soon as the other tier is changed", () => {
    openEditor();
    fireEvent.click(screen.getByLabelText("Tier discount by ownership duration"));
    fireEvent.click(screen.getByRole("button", { name: "Add tier" }));
    fireEvent.click(screen.getByRole("button", { name: "Add tier" }));

    const message = "Each tier needs a different starting month.";
    const tier2Months = screen.getByLabelText("Tier 2 starting month");
    const tier3Months = screen.getByLabelText("Tier 3 starting month");
    fireEvent.change(tier2Months, { target: { value: "5" } });
    fireEvent.change(tier3Months, { target: { value: "5" } });
    save();
    expect(describedBy(tier3Months)).toEqual([message]);

    fireEvent.change(tier2Months, { target: { value: "4" } });

    expect(tier3Months.getAttribute("aria-invalid")).not.toBe("true");
    expect(describedBy(tier3Months)).toEqual([]);
    expect(screen.queryByText(message)).toBeNull();
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
