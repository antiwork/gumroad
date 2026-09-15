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

const makeUser = (countryCode: string, supportsIban = false): User => ({
  country_supports_native_payouts: true,
  no_payout_rail_in_country: false,
  country_supports_iban: supportsIban,
  need_full_ssn: false,
  country_code: countryCode,
  payout_currency: "usd",
  is_from_europe: false,
  individual_tax_id_needed_countries: [],
  individual_tax_id_entered: false,
  individual_tax_id_last_four: null,
  individual_tax_id_is_last_four: false,
  has_outstanding_full_ssn_requirement: false,
  business_tax_id_entered: false,
  business_tax_id_last_four: null,
  requires_credit_card: false,
  is_charged_paypal_payout_fee: false,
  joined_at: "2026-01-01",
});

// The section keeps the entered account number in its parent, so a stateful wrapper is what
// lets these tests exercise the rendered field rather than a single passed-in prop.
const renderForCountry = (countryCode: string, supportsIban = false) => {
  const Harness = () => {
    const [bankAccount, setBankAccount] = React.useState<Partial<BankAccount> | null>(null);
    return (
      <BankAccountSection
        bankAccountDetails={bankAccountDetails}
        bankAccount={bankAccount}
        updateBankAccount={(next) => setBankAccount((prev) => ({ ...prev, ...next }))}
        hasConnectedStripe={false}
        user={makeUser(countryCode, supportsIban)}
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

// Every country in COUNTRY_ACCOUNT_NUMBER_HINTS, paired with the field label it renders and a
// value its bank-account model accepts (the same fixtures spec/requests/settings/payments_spec.rb
// posts). The `pattern` is pinned literally rather than read back off the element, because a
// pattern that merely rejects "1234567890" can still be the wrong pattern for the country.
//
// Labels differ by country: countries whose expected value is an IBAN say "IBAN", the handful
// listed in the section as using the spelled-out label say "Account number", and the rest get the
// abbreviated "Account #".
const COUNTRY_EXAMPLES: {
  code: string;
  label: string;
  example: string;
  pattern: string;
}[] = [
  { code: "MA", label: "IBAN", example: "MA64011519000001205000534921", pattern: "MA[0-9]{26}" },
  { code: "SN", label: "IBAN", example: "SN08SN0100152000048500003035", pattern: "SN[0-9SN]{20,26}" },
  { code: "RS", label: "IBAN", example: "RS35260005601001611379", pattern: "RS[0-9]{18,20}" },
  { code: "MD", label: "IBAN", example: "MD24AG000225100013104168", pattern: "MD[0-9]{2}[A-Z0-9]{20}" },
  { code: "GM", label: "Account #", example: "000123000456000789", pattern: "[0-9A-Za-z]{18}" },
  { code: "MZ", label: "Account #", example: "001234567890123456789", pattern: "[0-9A-Za-z]{21}" },
  { code: "QA", label: "IBAN", example: "QA87CITI123456789012345678901", pattern: "[0-9A-Za-z]{29}" },
  { code: "MK", label: "IBAN", example: "MK49250120000058907", pattern: "[0-9A-Za-z]{19}" },
  { code: "GA", label: "Account #", example: "00001234567890123456789", pattern: "[0-9]{23}" },
  { code: "DZ", label: "Account #", example: "00001234567890123456", pattern: "[0-9]{20}" },
  { code: "ET", label: "Account #", example: "0000000012345", pattern: "[0-9A-Za-z]{13,16}" },
  { code: "BD", label: "Account #", example: "1234567890123", pattern: "[0-9A-Za-z]{13,17}" },
  { code: "AM", label: "Account #", example: "00001234567890", pattern: "[0-9]{11,16}" },
  { code: "AR", label: "Account number", example: "0110000600000000000000", pattern: "[0-9]{22}" },
  { code: "PE", label: "Account number", example: "12345678901234567890", pattern: "[0-9]{20}" },
  { code: "MX", label: "Account number", example: "032180000118359719", pattern: "[0-9]{18}" },
  { code: "KR", label: "Account #", example: "00012345678901", pattern: "[0-9]{11,16}" },
  { code: "NZ", label: "Account #", example: "1234567890123456", pattern: "[0-9]{15,16}" },
  { code: "JP", label: "Account #", example: "1234567", pattern: "[0-9]{4,8}" },
  { code: "GI", label: "Account #", example: "01234567", pattern: "[0-9]{8}" },
];

const confirmationLabelFor = (label: string) => {
  if (label === "IBAN") return "Confirm IBAN";
  return label === "Account number" ? "Confirm account number" : "Confirm account #";
};

describe("BankAccountSection account-number hints", () => {
  it.each(COUNTRY_EXAMPLES)(
    "shows $code an example its bank-account model accepts, not the generic one",
    ({ code, label, example }) => {
      renderForCountry(code);
      const field = accountNumberField(label);

      expect(field.placeholder).toBe(example);
      expect(field.placeholder).not.toBe("1234567890");
    },
  );

  it.each(COUNTRY_EXAMPLES)("gives $code the pattern its bank-account model expects", ({ code, label, pattern }) => {
    renderForCountry(code);

    expect(accountNumberField(label).pattern).toBe(pattern);
  });

  it.each(COUNTRY_EXAMPLES)("lets $code's own example satisfy the pattern it advertises", ({ code, label }) => {
    renderForCountry(code);
    const field = accountNumberField(label);

    // The browser anchors `pattern` implicitly, so mirror that when checking it here.
    const pattern = new RegExp(`^(?:${field.pattern})$`, "u");
    expect(pattern.test(field.placeholder)).toBe(true);
    expect(pattern.test("1234567890")).toBe(false);
  });

  it.each(COUNTRY_EXAMPLES)("applies $code's hint to the confirmation field too", ({ code, label, example }) => {
    renderForCountry(code);

    expect(accountNumberField(confirmationLabelFor(label)).placeholder).toBe(example);
  });

  // The account number is valid with the separators banks print it with — a New Zealand seller's
  // "12-3456-7890123-00" saves today because UpdatePayoutMethod strips them before validating — so
  // a length cap sized to the bare number would silently swallow the seller's last few characters.
  it.each(COUNTRY_EXAMPLES)("puts no length cap on $code that a formatted number would hit", ({ code, label }) => {
    renderForCountry(code);

    expect(accountNumberField(label).getAttribute("maxlength")).toBeNull();
    expect(accountNumberField(confirmationLabelFor(label)).getAttribute("maxlength")).toBeNull();
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

  // Oman is the one country in the table whose model does accept the generic "1234567890" (it takes
  // 6 to 16 digits), so it is not in COUNTRY_EXAMPLES above — its hint is there for enforcement,
  // not to replace a wrong example.
  it("gives Oman a pattern that rejects a non-numeric account number", () => {
    renderForCountry("OM");
    const field = accountNumberField("Account #");

    expect(field.placeholder).toBe("123456789012");
    expect(field.pattern).toBe("[0-9]{6,16}");
    const pattern = new RegExp(`^(?:${field.pattern})$`, "u");
    expect(pattern.test("123456789012")).toBe(true);
    expect(pattern.test("OM810180000001299123456")).toBe(false);
  });

  // Madagascar renders through the IBAN branch (its country supports IBAN), so it needs checking
  // separately from the table above. Same reasoning as the cap test there: a separator-formatted
  // number is valid, so a cap sized to the bare number truncates it.
  it.each([["MG", "IBAN", "Confirm IBAN", true]])(
    "puts no length cap on %s either",
    (code, label, confirmLabel, supportsIban) => {
      renderForCountry(code, supportsIban);

      expect(accountNumberField(label).getAttribute("maxlength")).toBeNull();
      expect(accountNumberField(confirmLabel).getAttribute("maxlength")).toBeNull();
    },
  );
});

describe("BankAccountSection Bolivia bank code", () => {
  // gp#1967: the placeholder used to read as a real value ("060"), and 0/128 submissions
  // ever linked a live Stripe account because sellers copied that literal placeholder
  // instead of their bank's actual ASFI code. The placeholder must not look like a value.
  it("advertises a real ASFI code is required without a copyable-looking placeholder", () => {
    renderForCountry("BO");

    const field = screen.getByLabelText<HTMLInputElement>("Bank code");
    expect(field.maxLength).toBe(3);
    // The old placeholder was a specific-looking value sellers copied literally.
    expect(/\d{3}/u.test(field.placeholder)).toBe(false);
    expect(field.placeholder.toLowerCase()).toContain("asfi");

    expect(screen.getByText(/3-digit ASFI code/u)).toBeTruthy();
  });
});

describe("BankAccountSection bank-code placeholders", () => {
  // A placeholder equal to a country's Stripe test routing number is refused outright in live
  // mode, and a seller cannot tell it apart from a real branch code.
  it.each([
    ["GH", "Bank code", "123456", "022112", false],
    ["BD", "Bank code", "123456789", "110000000", false],
    ["VN", "Bank code", "12345678", "01101100", false],
    ["ID", "Bank code", "123", "000", false],
    ["JM", "Bank code", "123", "111", false],
    ["JM", "Branch code", "12345", "00000", false],
    // Azerbaijan's Stripe test routing is the PAIR 123456-123456, so the two fields must not both
    // carry the sequence. Its bank fields render for IBAN countries only.
    ["AZ", "Branch code", "234567", "123456", true],
  ])("does not hint %s with a value Stripe reserves for tests", (code, label, expected, reserved, supportsIban) => {
    renderForCountry(code, supportsIban);
    const field = screen.getByLabelText<HTMLInputElement>(label);

    expect(field.placeholder).toBe(expected);
    expect(field.placeholder).not.toBe(reserved);
  });
});
describe("BankAccountSection account-number placeholders", () => {
  // The bank-code rule above, applied to the account-number field: Stripe publishes a test account
  // number per country and refuses it in live mode. Every published value for the country is listed,
  // both the one that succeeds and the ones that fail, so a rewrite cannot land on a neighbour.
  const RESERVED_ACCOUNT_NUMBERS: Record<string, string[]> = {
    BD: ["0000123456789", "0000000011116", "0000000011113", "0000000022227", "0000000033335", "0000000044440"],
    NZ: [
      "1100000000000010",
      "1100001111111016",
      "1100001111111013",
      "1100002222222027",
      "1100003333333035",
      "1100004444444040",
    ],
    OM: ["000123456789", "001111111116", "001111111113", "002222222227", "003333333335", "004444444440"],
    PE: [
      "99934500012345670024",
      "99934500012345670122",
      "99934500012345670220",
      "99934500012345670328",
      "99934500012345670426",
      "99934500012345670523",
    ],
  };

  it.each([
    ["BD", "Account #"],
    ["NZ", "Account #"],
    ["OM", "Account #"],
    ["PE", "Account number"],
  ])("does not hint %s with a value Stripe reserves for tests", (code, label) => {
    renderForCountry(code);
    const field = accountNumberField(label);

    expect(RESERVED_ACCOUNT_NUMBERS[code]).not.toContain(field.placeholder);
  });
});
describe("BankAccountSection Indonesian bank code", () => {
  // Stripe resolves the ID bank from its 3-digit Sandi Bank directory. The old field advertised
  // maxLength 4 and no shape at all, so `BBSB` and `0140` typed cleanly and were only refused once
  // the payout account failed to attach.
  it("caps the bank code at 3 digits and advertises the digits-only shape", () => {
    renderForCountry("ID");
    const field = screen.getByLabelText<HTMLInputElement>("Bank code");

    expect(field.maxLength).toBe(3);
    expect(field.pattern).toBe("[0-9]{3}");
    expect(field.inputMode).toBe("numeric");

    const pattern = new RegExp(`^(?:${field.pattern})$`, "u");
    expect(pattern.test("014")).toBe(true);
    expect(pattern.test(field.placeholder)).toBe(true);
    // maxLength alone cannot reject these — they are already 3 characters.
    expect(pattern.test("BCA")).toBe(false);
    expect(pattern.test("IDR")).toBe(false);
  });
});
describe("BankAccountSection Egyptian bank code", () => {
  // Egyptian banks publish an 8-char BIC and a separate branch number, and an 11-char "BIC + branch"
  // code resolves only when Stripe's directory lists that branch. So the field advertises the 8-char
  // form, which resolves for every bank.
  it("advertises the 8-character BIC rather than a branch-suffixed code", () => {
    renderForCountry("EG", true);
    const field = screen.getByLabelText<HTMLInputElement>("SWIFT / BIC Code");

    expect(field.placeholder).toBe("NBEGEGCX");
    expect(field.placeholder).not.toHaveLength(11);
  });
});
