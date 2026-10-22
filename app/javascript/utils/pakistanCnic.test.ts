import { describe, expect, it } from "vitest";

import {
  isValidPakistanCnic,
  PAKISTAN_CNIC_DIGITS,
  PAKISTAN_CNIC_ERROR_MESSAGE,
  PAKISTAN_CNIC_HELP_TEXT,
} from "$app/utils/pakistanCnic";

describe("isValidPakistanCnic", () => {
  it("accepts a 13-digit CNIC", () => {
    expect(isValidPakistanCnic("1234512345671")).toBe(true);
  });

  it("accepts a CNIC entered the way the card is printed, with dashes", () => {
    expect(isValidPakistanCnic("12345-1234567-1")).toBe(true);
  });

  it("accepts a CNIC pasted with spaces, including non-breaking spaces, a BOM and NEL", () => {
    for (const value of [
      "12345 1234567 1",
      " 12345-1234567-1",
      "12345-1234567-1\u00a0",
      "\u00a01234512345671 ",
      "\ufeff12345-1234567-1",
      "12345-1234567-1\u0085",
    ]) {
      expect(isValidPakistanCnic(value)).toBe(true);
    }
  });

  it("rejects letters or separators other than the printed dashes, even around 13 digits", () => {
    for (const value of [
      "P1234512345671",
      "AB12345-1234567-1",
      "12345_1234567_1",
      "12345.1234567.1",
      "1234-51234567-1",
      "12345--1234567-1",
      "1-2-3-4-5-1-2-3-4-5-6-7-1",
      "\ufeffP1234512345671",
      "12345\u200b-1234567-1",
    ]) {
      expect(isValidPakistanCnic(value)).toBe(false);
    }
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

  it("states the digit count and the dashed example in the error message", () => {
    expect(PAKISTAN_CNIC_ERROR_MESSAGE).toContain(`${PAKISTAN_CNIC_DIGITS} digits`);
    expect(PAKISTAN_CNIC_ERROR_MESSAGE).toContain("12345-1234567-1");
    expect(PAKISTAN_CNIC_ERROR_MESSAGE).toContain("dashes are optional");
  });

  it("keeps the persistent help text in step with the digit count and the placeholder shape", () => {
    expect(PAKISTAN_CNIC_HELP_TEXT).toBe(`${PAKISTAN_CNIC_DIGITS} digits, dashes optional`);
  });
});
