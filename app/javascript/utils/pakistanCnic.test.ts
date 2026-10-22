import { describe, expect, it } from "vitest";

import {
  isValidPakistanCnic,
  PAKISTAN_CNIC_DIGITS,
  PAKISTAN_CNIC_ERROR_MESSAGE,
  PAKISTAN_CNIC_MAX_INPUT_LENGTH,
} from "$app/utils/pakistanCnic";

describe("isValidPakistanCnic", () => {
  it("accepts a 13-digit CNIC", () => {
    expect(isValidPakistanCnic("1234512345671")).toBe(true);
  });

  it("accepts a CNIC entered the way the card is printed, with dashes", () => {
    expect(isValidPakistanCnic("12345-1234567-1")).toBe(true);
  });

  it("accepts a CNIC pasted with spaces or other separators", () => {
    expect(isValidPakistanCnic("12345 1234567 1")).toBe(true);
  });

  it("rejects the 13-character value a dashed CNIC was truncated to", () => {
    // "12345-1234567" is 13 characters, so the old 13-character cap let it through while it holds
    // only 12 digits. The digit count is the bound, not the character count.
    expect(isValidPakistanCnic("12345-1234567")).toBe(false);
    expect("12345-1234567").toHaveLength(PAKISTAN_CNIC_DIGITS);
  });

  it("rejects a CNIC that is too short or too long", () => {
    expect(isValidPakistanCnic("123451234567")).toBe(false);
    expect(isValidPakistanCnic("12345123456712")).toBe(false);
  });

  it("rejects an empty value rather than treating it as valid", () => {
    expect(isValidPakistanCnic("")).toBe(false);
    expect(isValidPakistanCnic("---")).toBe(false);
  });

  it("leaves room in the input for the dashes the card is printed with", () => {
    expect(PAKISTAN_CNIC_MAX_INPUT_LENGTH).toBe(PAKISTAN_CNIC_DIGITS + 2);
    expect("12345-1234567-1").toHaveLength(PAKISTAN_CNIC_MAX_INPUT_LENGTH);
  });

  it("states the digit count and the dashed example in the error message", () => {
    expect(PAKISTAN_CNIC_ERROR_MESSAGE).toContain(`${PAKISTAN_CNIC_DIGITS} digits`);
    expect(PAKISTAN_CNIC_ERROR_MESSAGE).toContain("12345-1234567-1");
    expect(PAKISTAN_CNIC_ERROR_MESSAGE).toContain("dashes are optional");
  });
});
