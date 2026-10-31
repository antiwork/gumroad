import { describe, expect, it } from "vitest";

import {
  isValidUaeEmiratesId,
  UAE_EMIRATES_ID_DIGITS,
  UAE_EMIRATES_ID_ERROR_MESSAGE,
  UAE_EMIRATES_ID_HELP_TEXT,
} from "$app/utils/uaeEmiratesId";

describe("isValidUaeEmiratesId", () => {
  it("accepts a 15-digit Emirates ID", () => {
    expect(isValidUaeEmiratesId("784199012345671")).toBe(true);
  });

  it("accepts an Emirates ID entered the way the card is printed, with dashes", () => {
    expect(isValidUaeEmiratesId("784-1990-1234567-1")).toBe(true);
  });

  it("accepts an Emirates ID pasted with spaces, including non-breaking spaces, a BOM and NEL", () => {
    for (const value of [
      "784 1990 1234567 1",
      " 784-1990-1234567-1",
      "784-1990-1234567-1\u00a0",
      "\u00a0784199012345671 ",
      "\uFEFF784-1990-1234567-1",
      "784-1990-1234567-1\u0085",
    ]) {
      expect(isValidUaeEmiratesId(value)).toBe(true);
    }
  });

  it("rejects letters or separators other than the printed dashes, even around 15 digits", () => {
    for (const value of [
      "A784199012345671",
      "784199012345671A",
      "784-1990-1234567-A",
      "784_1990_1234567_1",
      "784.1990.1234567.1",
      "7841-990-1234567-1",
      "784--1990-1234567-1",
      "784-1990-12345671",
      "\uFEFFA784199012345671",
      "784\u200b-1990-1234567-1",
      "７８４１９９０１２３４５６７１",
    ]) {
      expect(isValidUaeEmiratesId(value)).toBe(false);
    }
  });

  it("rejects the 15-character value a dashed Emirates ID was truncated to", () => {
    // "784-1990-123456" is 15 characters, so the old 15-character cap let it through while it holds
    // only 13 digits. The digit count is the bound, not the character count.
    expect(isValidUaeEmiratesId("784-1990-123456")).toBe(false);
    expect("784-1990-123456").toHaveLength(UAE_EMIRATES_ID_DIGITS);
  });

  it("rejects an Emirates ID that is too short or too long", () => {
    expect(isValidUaeEmiratesId("78419901234567")).toBe(false);
    expect(isValidUaeEmiratesId("7841990123456712")).toBe(false);
    expect(isValidUaeEmiratesId("784-1990-123456-1")).toBe(false);
    expect(isValidUaeEmiratesId("784-1990-12345678-1")).toBe(false);
  });

  it("rejects an empty value rather than treating it as valid", () => {
    expect(isValidUaeEmiratesId("")).toBe(false);
    expect(isValidUaeEmiratesId("---")).toBe(false);
  });

  it("states the digit count and the dashed example in the error message", () => {
    expect(UAE_EMIRATES_ID_ERROR_MESSAGE).toContain(`${UAE_EMIRATES_ID_DIGITS} digits`);
    expect(UAE_EMIRATES_ID_ERROR_MESSAGE).toContain("784-1234-1234567-1");
    expect(UAE_EMIRATES_ID_ERROR_MESSAGE).toContain("dashes are optional");
  });

  it("keeps the persistent help text in step with the digit count", () => {
    expect(UAE_EMIRATES_ID_HELP_TEXT).toBe(`${UAE_EMIRATES_ID_DIGITS} digits, dashes optional`);
  });
});
