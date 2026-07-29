import { describe, expect, it } from "vitest";

import {
  COUNTRY_ACCOUNT_NUMBER_HINTS,
  accountNumberFormatError,
  normalizeAccountNumber,
} from "$app/utils/payoutAccountNumbers";

describe("normalizeAccountNumber", () => {
  it("strips the separators banks print account numbers with", () => {
    expect(normalizeAccountNumber("12-3456-7890123-00")).toBe("123456789012300");
    expect(normalizeAccountNumber("QA87 CITI 1234 5678 9012 3456 78901")).toBe("QA87CITI123456789012345678901");
    // Copied text often carries invisible formatting characters along with it (here a zero-width
    // space and a left-to-right mark), which the server strips too.
    expect(normalizeAccountNumber("0321\u200B8000\u200E0118359719")).toBe("032180000118359719");
    // U+0085 is whitespace to Ruby's [[:space:]] but not to JavaScript's \s, so the server strips
    // it and this has to as well, or we reject a number the server would have saved.
    expect(normalizeAccountNumber("0321\u00858000\u20090118359719")).toBe("032180000118359719");
  });

  it("leaves a bare account number alone", () => {
    expect(normalizeAccountNumber("032180000118359719")).toBe("032180000118359719");
  });
});

describe("accountNumberFormatError", () => {
  it("accepts each country's own example", () => {
    for (const [countryCode, hint] of Object.entries(COUNTRY_ACCOUNT_NUMBER_HINTS)) {
      expect(accountNumberFormatError(countryCode, hint.placeholder)).toBeNull();
    }
  });

  // Oman's model takes 6 to 16 digits, so the generic example is genuinely valid there — its entry
  // exists to reject a non-numeric value, not to replace a wrong example.
  const COUNTRIES_THE_GENERIC_EXAMPLE_IS_WRONG_FOR = Object.entries(COUNTRY_ACCOUNT_NUMBER_HINTS).filter(
    ([countryCode]) => countryCode !== "OM",
  );

  it("rejects the generic example for every country whose model would reject it", () => {
    for (const [countryCode, hint] of COUNTRIES_THE_GENERIC_EXAMPLE_IS_WRONG_FOR) {
      expect(accountNumberFormatError(countryCode, "1234567890")).toBe(hint.title);
    }
  });

  it("accepts the generic example for Oman, whose model does allow it", () => {
    expect(accountNumberFormatError("OM", "1234567890")).toBeNull();
    expect(accountNumberFormatError("OM", "OM810180000001299123456")).toBe(COUNTRY_ACCOUNT_NUMBER_HINTS.OM?.title);
  });

  // These numbers are valid today: UpdatePayoutMethod strips the separators before it validates,
  // so a seller pasting the form their bank prints saves successfully. This check has to agree.
  it.each([
    ["NZ", "11-0000-0000000-10"],
    ["QA", "QA87 CITI 1234 5678 9012 3456 78901"],
    ["MX", "0321 8000 0118 3597 19"],
    ["AR", "0110 0006 0000 0000 0000 00"],
    ["MZ", "0012 3456 7890 1234 5678 9"],
  ])("accepts %s's number written with the separators its bank prints", (countryCode, accountNumber) => {
    expect(accountNumberFormatError(countryCode, accountNumber)).toBeNull();
  });

  it("rejects a number that is the right shape only because a character is missing", () => {
    // One digit short of Mozambique's 21-character NIB.
    expect(accountNumberFormatError("MZ", "00123456789012345678")).toBe(COUNTRY_ACCOUNT_NUMBER_HINTS.MZ?.title);
    // Qatar's IBAN with its last character dropped, the shape a truncating length cap would produce.
    expect(accountNumberFormatError("QA", "QA87CITI12345678901234567890")).toBe(COUNTRY_ACCOUNT_NUMBER_HINTS.QA?.title);
  });

  it("defers to the server for countries with no format on record", () => {
    expect(accountNumberFormatError("NG", "1234567890")).toBeNull();
    expect(accountNumberFormatError("US", "1234567890")).toBeNull();
    expect(accountNumberFormatError(null, "1234567890")).toBeNull();
  });
});
