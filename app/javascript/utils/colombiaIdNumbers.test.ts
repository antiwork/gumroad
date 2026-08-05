import { describe, expect, it } from "vitest";

import {
  COLOMBIA_ID_MAX_DIGITS,
  COLOMBIA_ID_MIN_DIGITS,
  COLOMBIA_ID_NUMBER_ERROR_MESSAGE,
  isValidColombiaIdNumber,
} from "$app/utils/colombiaIdNumbers";

describe("isValidColombiaIdNumber", () => {
  it("accepts the digit lengths Stripe accepts for CO", () => {
    expect(isValidColombiaIdNumber("482913")).toBe(true);
    expect(isValidColombiaIdNumber("1234567")).toBe(true);
    expect(isValidColombiaIdNumber("12345678")).toBe(true);
    expect(isValidColombiaIdNumber("1234567890")).toBe(true);
  });

  it("rejects a five-digit number, which Stripe refuses", () => {
    expect(isValidColombiaIdNumber("48291")).toBe(false);
  });

  it("rejects numbers longer than Stripe's upper bound", () => {
    expect(isValidColombiaIdNumber("12345678901")).toBe(false);
  });

  it("ignores thousands separators and spaces", () => {
    expect(isValidColombiaIdNumber("1.123.456")).toBe(true);
    expect(isValidColombiaIdNumber("1 123 456")).toBe(true);
    // 9 characters but only 5 digits — the character count must not stand in for the digit count.
    expect(isValidColombiaIdNumber("4.8.2.9.1")).toBe(false);
  });

  it("rejects an empty value rather than treating it as valid", () => {
    expect(isValidColombiaIdNumber("")).toBe(false);
    expect(isValidColombiaIdNumber("...")).toBe(false);
  });

  it("names both documents and the bounds in the error message", () => {
    expect(COLOMBIA_ID_NUMBER_ERROR_MESSAGE).toContain("Cédula de Ciudadanía");
    expect(COLOMBIA_ID_NUMBER_ERROR_MESSAGE).toContain("Cédula de Extranjería");
    expect(COLOMBIA_ID_NUMBER_ERROR_MESSAGE).toContain(`${COLOMBIA_ID_MIN_DIGITS}-${COLOMBIA_ID_MAX_DIGITS} digits`);
    expect(COLOMBIA_ID_NUMBER_ERROR_MESSAGE).toContain("leading zeros");
  });
});
