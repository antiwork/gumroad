// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import type { User } from "$app/types/payments";

import BankAccountSection from "$app/components/Settings/PaymentsPage/BankAccountSection";
import type { BankAccount, BankAccountDetails } from "$app/components/Settings/PaymentsPage/BankAccountSection";

afterEach(cleanup);

const bankAccountDetails: BankAccountDetails = {
  show_bank_account: true,
  show_paypal: false,
  is_a_card: false,
  routing_number: null,
  account_number_visual: null,
  card: null,
  card_data_handling_mode: null,
  bank_account: null,
};

const makeUser = (countryCode: string): User => ({
  country_supports_native_payouts: true,
  country_supports_iban: false,
  need_full_ssn: false,
  country_code: countryCode,
  payout_currency: "usd",
  is_from_europe: false,
  individual_tax_id_needed_countries: [],
  individual_tax_id_entered: false,
  individual_tax_id_last_four: null,
  business_tax_id_entered: false,
  business_tax_id_last_four: null,
  requires_credit_card: false,
  is_charged_paypal_payout_fee: false,
  joined_at: "2026-01-01",
});

// The section keeps the entered account number in its parent, so a stateful wrapper is what
// lets these tests exercise the rendered field rather than a single passed-in prop.
const renderForCountry = (countryCode: string) => {
  const Harness = () => {
    const [bankAccount, setBankAccount] = React.useState<Partial<BankAccount> | null>(null);
    return (
      <BankAccountSection
        bankAccountDetails={bankAccountDetails}
        bankAccount={bankAccount}
        updateBankAccount={(next) => setBankAccount((prev) => ({ ...prev, ...next }))}
        hasConnectedStripe={false}
        user={makeUser(countryCode)}
        isFormDisabled={false}
        feeInfoText=""
        showNewBankAccount
        setShowNewBankAccount={() => {}}
        errorFieldNames={new Set()}
      />
    );
  };
  render(<Harness />);
};

const accountNumberField = (label: string) => {
  const field = screen.getByLabelText<HTMLInputElement>(label);
  if (!(field instanceof HTMLInputElement)) throw new Error(`expected ${label} to be an <input>`);
  return field;
};

// Each entry is a country whose bank-account model rejects the generic "1234567890" example,
// paired with the value its model does accept (mirrors spec/requests/settings/payments_spec.rb).
const COUNTRY_EXAMPLES: { code: string; label: string; example: string; maxLength: number }[] = [
  { code: "MZ", label: "Account #", example: "001234567890123456789", maxLength: 21 },
  { code: "QA", label: "IBAN", example: "QA87CITI123456789012345678901", maxLength: 29 },
  { code: "MK", label: "IBAN", example: "MK49250120000058907", maxLength: 19 },
  { code: "GA", label: "Account #", example: "00001234567890123456789", maxLength: 23 },
  { code: "DZ", label: "Account #", example: "00001234567890123456", maxLength: 20 },
  { code: "ET", label: "Account #", example: "0000000012345", maxLength: 16 },
  { code: "BD", label: "Account #", example: "0000123456789", maxLength: 17 },
];

describe("BankAccountSection account-number hints", () => {
  it.each(COUNTRY_EXAMPLES)(
    "shows $code an example its bank-account model accepts, not the generic one",
    ({ code, label, example, maxLength }) => {
      renderForCountry(code);
      const field = accountNumberField(label);

      expect(field.placeholder).toBe(example);
      expect(field.placeholder).not.toBe("1234567890");
      expect(field.maxLength).toBe(maxLength);
      // A hint longer than the field allows would be un-enterable, so it has to fit.
      expect(example.length).toBeLessThanOrEqual(maxLength);
    },
  );

  it.each(COUNTRY_EXAMPLES)("gives $code a pattern that rejects the generic example", ({ code, label, example }) => {
    renderForCountry(code);
    const field = accountNumberField(label);

    expect(field.pattern).not.toBe("");
    const pattern = new RegExp(`^(?:${field.pattern})$`, "u");
    expect(pattern.test(example)).toBe(true);
    expect(pattern.test("1234567890")).toBe(false);
  });

  it.each(COUNTRY_EXAMPLES)("applies $code's hint to the confirmation field too", ({ code, label, example }) => {
    renderForCountry(code);

    const confirmLabel = label === "IBAN" ? "Confirm IBAN" : "Confirm account #";
    expect(accountNumberField(confirmLabel).placeholder).toBe(example);
  });

  // Stripe rejects a bare local account number for these two with "must be an IBAN of the
  // form ...", so the field is labelled IBAN. Mozambique is the opposite case: Stripe wants
  // the bare 21-character NIB and rejects the full MZ IBAN, so it keeps the generic label.
  it("labels Qatar and North Macedonia as IBAN fields", () => {
    for (const code of ["QA", "MK"]) {
      cleanup();
      renderForCountry(code);
      expect(screen.getByLabelText("IBAN")).toBeTruthy();
      expect(screen.queryByLabelText("Account #")).toBeNull();
    }
  });

  it("keeps Mozambique on the account-number label rather than IBAN", () => {
    renderForCountry("MZ");

    expect(screen.getByLabelText("Account #")).toBeTruthy();
    expect(screen.queryByLabelText("IBAN")).toBeNull();
  });

  // Countries whose models accept "1234567890" must be untouched by this change.
  it.each(["NG", "PH"])("leaves %s on the generic hint", (code) => {
    renderForCountry(code);
    const field = accountNumberField("Account #");

    expect(field.placeholder).toBe("1234567890");
    expect(field.pattern).toBe("");
  });
});
