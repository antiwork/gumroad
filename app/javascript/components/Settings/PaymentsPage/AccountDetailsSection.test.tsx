// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import type { ComplianceInfo, User } from "$app/types/payments";

import AccountDetailsSection from "$app/components/Settings/PaymentsPage/AccountDetailsSection";

afterEach(cleanup);

const makeUser = (overrides: Partial<User> = {}): User => ({
  country_supports_native_payouts: true,
  no_payout_rail_in_country: false,
  country_supports_iban: false,
  need_full_ssn: false,
  country_code: "US",
  payout_currency: "usd",
  is_from_europe: false,
  individual_tax_id_needed_countries: ["US"],
  individual_tax_id_entered: true,
  individual_tax_id_last_four: "6789",
  individual_tax_id_is_last_four: false,
  has_outstanding_full_ssn_requirement: false,
  has_outstanding_nationality_requirement: false,
  business_tax_id_entered: false,
  business_tax_id_last_four: null,
  requires_credit_card: false,
  is_charged_paypal_payout_fee: false,
  joined_at: "2026-01-01",
  ...overrides,
});

const complianceInfo: ComplianceInfo = {
  is_business: false,
  business_name: null,
  business_type: null,
  business_street_address: null,
  business_city: null,
  business_state: null,
  business_country: null,
  business_zip_code: null,
  business_phone: null,
  job_title: null,
  first_name: "Test",
  last_name: "Seller",
  street_address: "123 Main St",
  city: "San Francisco",
  state: "CA",
  country: "US",
  zip_code: "94103",
  phone: "+14155551234",
  nationality: null,
  dob_month: 1,
  dob_day: 1,
  dob_year: 2000,
};

const usBusinessTypes = [
  { code: "sole_proprietorship", name: "Sole Proprietorship" },
  { code: "single_member_llc", name: "LLC (single member)" },
  { code: "multi_member_llc", name: "LLC (multi-member)" },
  { code: "partnership", name: "Partnership" },
  { code: "corporation", name: "Corporation" },
  { code: "profit", name: "Non Profit" },
];

const renderSection = (user: User, complianceOverrides: Partial<ComplianceInfo> = {}) =>
  render(
    <AccountDetailsSection
      user={user}
      complianceInfo={{ ...complianceInfo, ...complianceOverrides }}
      updateComplianceInfo={() => {}}
      isFormDisabled={false}
      minDobYear={2008}
      countries={{ US: "United States", GB: "United Kingdom" }}
      usBusinessTypes={usBusinessTypes}
      uaeBusinessTypes={[]}
      indiaBusinessTypes={[]}
      canadaBusinessTypes={[]}
      states={{ us: [{ code: "CA", name: "California" }], ca: [], au: [], mx: [], ae: [], ir: [], br: [], jp: [] }}
      errorFieldNames={new Set()}
      saveCounter={0}
    />,
  );

describe("AccountDetailsSection foreign representative tax ID", () => {
  it("renders a generic field for an unmapped representative country on a US business", () => {
    renderSection(makeUser({ individual_tax_id_entered: false }), {
      is_business: true,
      business_country: "US",
      country: "DZ",
    });
    expect(screen.getByLabelText<HTMLInputElement>("Personal tax ID").disabled).toBe(false);
    expect(screen.getByText(/US ITIN or SSN \(9 digits\)/u)).toBeTruthy();
    expect(screen.getByText(/upload a passport/u)).toBeTruthy();
  });

  it("keeps a mapped foreign-ID field's existing length behavior", () => {
    renderSection(makeUser({ individual_tax_id_entered: false }), {
      is_business: true,
      business_country: "US",
      country: "BO",
    });
    const input = screen.getByLabelText<HTMLInputElement>("Cédula de Identidad (CI)");
    expect([input.minLength, input.maxLength]).toEqual([8, 8]);
    fireEvent.change(input, { target: { value: "12345678" } });
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("keeps the mapped Canadian field unchanged", () => {
    renderSection(makeUser({ individual_tax_id_entered: false }), {
      is_business: true,
      business_country: "US",
      country: "CA",
    });
    const input = screen.getByLabelText<HTMLInputElement>("Social Insurance Number");
    expect([input.placeholder, input.minLength, input.maxLength]).toEqual(["•••••••••", 9, 9]);
    expect(screen.queryByLabelText("Personal tax ID")).toBeNull();
  });

  it.each(["1234", "12345678", "1234567890", "abcdefghi"])(
    "shows an inline error for invalid US tax ID %s",
    (value) => {
      renderSection(makeUser({ individual_tax_id_entered: false }), {
        is_business: true,
        business_country: "US",
        country: "DZ",
      });
      const input = screen.getByLabelText("Personal tax ID");
      fireEvent.change(input, { target: { value } });
      expect(screen.getByRole("alert").textContent).toBe("Enter a 9-digit US ITIN or SSN.");
      expect(input.getAttribute("aria-invalid")).toBe("true");
      fireEvent.change(input, { target: { value: "000000000" } });
      expect(screen.queryByRole("alert")).toBeNull();
    },
  );

  it("does not show a fallback when no country requires an ID", () => {
    renderSection(makeUser(), { country: "DZ" });
    expect(screen.queryByLabelText("Personal tax ID")).toBeNull();
  });
});

describe("AccountDetailsSection SSN field", () => {
  it("accepts only four digits on the permitted US-resident last-four path", () => {
    renderSection(makeUser({ individual_tax_id_entered: false }));
    const input = screen.getByLabelText("Last 4 digits of SSN");
    fireEvent.change(input, { target: { value: "000" } });
    expect(screen.getByRole("alert").textContent).toBe("Enter the last 4 digits of your SSN.");
    fireEvent.change(input, { target: { value: "0000" } });
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("renders the masked completed display when the full SSN is already on file", () => {
    renderSection(
      makeUser({
        need_full_ssn: true,
        has_outstanding_full_ssn_requirement: true,
        individual_tax_id_is_last_four: false,
      }),
    );

    const input = screen.getByLabelText<HTMLInputElement>("Social Security Number");
    expect(input.disabled).toBe(true);
    expect(screen.getByRole("button", { name: "Change" })).toBeTruthy();
  });

  it("renders the masked completed display when only last-4 is on file and the full SSN is not required", () => {
    renderSection(
      makeUser({
        need_full_ssn: false,
        has_outstanding_full_ssn_requirement: false,
        individual_tax_id_is_last_four: true,
      }),
    );

    const input = screen.getByLabelText<HTMLInputElement>("Last 4 digits of SSN");
    expect(input.disabled).toBe(true);
  });

  it("forces the full-SSN input open with an explanation when Stripe requires id_number but only last-4 is on file", () => {
    renderSection(
      makeUser({
        need_full_ssn: true,
        has_outstanding_full_ssn_requirement: true,
        individual_tax_id_is_last_four: true,
      }),
    );

    const input = screen.getByLabelText<HTMLInputElement>("Social Security Number");
    expect(input.disabled).toBe(false);
    expect(input.required).toBe(true);
    expect(screen.queryByRole("button", { name: "Change" })).toBeNull();
    expect(screen.getByText(/payments provider now requires your full 9-digit Social Security Number/u)).toBeTruthy();
  });
  it("keeps the masked display when the full-SSN request was already satisfied another way (e.g. document upload)", () => {
    renderSection(
      makeUser({
        need_full_ssn: true,
        has_outstanding_full_ssn_requirement: false,
        individual_tax_id_is_last_four: true,
      }),
    );

    const input = screen.getByLabelText<HTMLInputElement>("Social Security Number");
    expect(input.disabled).toBe(true);
    expect(screen.getByRole("button", { name: "Change" })).toBeTruthy();
  });
});

describe("AccountDetailsSection business type", () => {
  const optionValues = () =>
    Array.from(screen.getByLabelText<HTMLSelectElement>("Type").options).map((option) => option.value);

  it("offers the US list, split by LLC membership, for a US legal entity", () => {
    renderSection(makeUser({ country_code: "AE" }), { is_business: true, business_country: "US" });

    expect(optionValues()).toEqual([
      "",
      "sole_proprietorship",
      "single_member_llc",
      "multi_member_llc",
      "partnership",
      "corporation",
      "profit",
    ]);
  });

  it("keeps the generic list for a legal entity without its own list", () => {
    renderSection(makeUser(), { is_business: true, business_country: "GB" });

    expect(optionValues()).toEqual(["", "llc", "partnership", "profit", "sole_proprietorship", "corporation"]);
  });

  it.each([
    ["US", "llc"],
    ["GB", "registered_charity"],
  ])("requires a new selection for an unsupported %s business type %s", (business_country, business_type) => {
    renderSection(makeUser(), { is_business: true, business_country, business_type });

    const select = screen.getByLabelText<HTMLSelectElement>("Type");
    expect(optionValues()).not.toContain(business_type);
    expect(select.value).toBe("");
    expect(select.selectedOptions[0]?.text).toBe("Select a type");
    expect(select.validity.valueMissing).toBe(true);
    expect(screen.getByText("Your saved type is no longer offered. Choose a new one before saving.")).toBeTruthy();
  });

  it("does not explain a dropped type when the saved type is still an option", () => {
    renderSection(makeUser(), { is_business: true, business_country: "US", business_type: "single_member_llc" });

    expect(screen.queryByText("Your saved type is no longer offered. Choose a new one before saving.")).toBeNull();
  });

  it("does not repeat a saved type that is already an option", () => {
    renderSection(makeUser(), { is_business: true, business_country: "US", business_type: "single_member_llc" });

    expect(optionValues()).toEqual([
      "",
      "sole_proprietorship",
      "single_member_llc",
      "multi_member_llc",
      "partnership",
      "corporation",
      "profit",
    ]);
  });
});

describe("AccountDetailsSection nationality field", () => {
  it("renders when Stripe requires individual.nationality, outside the four hardcoded countries", () => {
    renderSection(makeUser({ country_code: "GR", has_outstanding_nationality_requirement: true }));

    expect(screen.getByLabelText("Nationality")).toBeTruthy();
  });

  it("does not render when nothing is asking for it", () => {
    renderSection(makeUser({ country_code: "GR", has_outstanding_nationality_requirement: false }));

    expect(screen.queryByLabelText("Nationality")).toBeNull();
  });

  it("keeps rendering for the four countries it used to be hardcoded to", () => {
    for (const country_code of ["AE", "SG", "PK", "BD"]) {
      cleanup();
      renderSection(makeUser({ country_code, has_outstanding_nationality_requirement: false }));

      expect(screen.getByLabelText("Nationality")).toBeTruthy();
    }
  });

  // The select silently omits four nationalities; without this the seller cannot tell that from a bug.
  it("says why the sanctioned nationalities are missing", () => {
    renderSection(makeUser({ country_code: "AE" }));

    expect(
      screen.getByText(
        "Nationals of Cuba, Iran, North Korea and Syria cannot be verified, so their nationalities are not listed.",
      ),
    ).toBeTruthy();
  });

  it("does not carry the note when the field is not rendered", () => {
    renderSection(makeUser({ country_code: "GR", has_outstanding_nationality_requirement: false }));

    expect(screen.queryByText(/Nationals of Cuba/u)).toBeNull();
  });
});
