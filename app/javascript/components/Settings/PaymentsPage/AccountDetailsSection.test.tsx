// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
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

const renderSection = (user: User) =>
  render(
    <AccountDetailsSection
      user={user}
      complianceInfo={complianceInfo}
      updateComplianceInfo={() => {}}
      isFormDisabled={false}
      minDobYear={2008}
      countries={{ US: "United States" }}
      uaeBusinessTypes={[]}
      indiaBusinessTypes={[]}
      canadaBusinessTypes={[]}
      states={{ us: [{ code: "CA", name: "California" }], ca: [], au: [], mx: [], ae: [], ir: [], br: [], jp: [] }}
      errorFieldNames={new Set()}
      saveCounter={0}
    />,
  );

describe("AccountDetailsSection SSN field", () => {
  it("renders the masked completed display when the full SSN is already on file", () => {
    renderSection(makeUser({ need_full_ssn: true, individual_tax_id_is_last_four: false }));

    const input = screen.getByLabelText<HTMLInputElement>("Social Security Number");
    expect(input.disabled).toBe(true);
    expect(screen.getByRole("button", { name: "Change" })).toBeTruthy();
  });

  it("renders the masked completed display when only last-4 is on file and the full SSN is not required", () => {
    renderSection(makeUser({ need_full_ssn: false, individual_tax_id_is_last_four: true }));

    const input = screen.getByLabelText<HTMLInputElement>("Last 4 digits of SSN");
    expect(input.disabled).toBe(true);
  });

  it("forces the full-SSN input open with an explanation when Stripe requires id_number but only last-4 is on file", () => {
    renderSection(makeUser({ need_full_ssn: true, individual_tax_id_is_last_four: true }));

    const input = screen.getByLabelText<HTMLInputElement>("Social Security Number");
    expect(input.disabled).toBe(false);
    expect(input.required).toBe(true);
    expect(screen.queryByRole("button", { name: "Change" })).toBeNull();
    expect(screen.getByText(/payments provider now requires your full 9-digit Social Security Number/u)).toBeTruthy();
  });
});
