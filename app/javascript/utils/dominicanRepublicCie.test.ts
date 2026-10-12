import { describe, expect, it } from "vitest";

import { DOMINICAN_REPUBLIC_CIE_ERROR_MESSAGE, isValidDominicanRepublicCie } from "$app/utils/dominicanRepublicCie";

describe("isValidDominicanRepublicCie", () => {
  it.each(["001-1234567-8", "402-0000000-0"])("accepts %j", (value) => {
    expect(isValidDominicanRepublicCie(value)).toBe(true);
  });

  it.each([
    "",
    "00112345678",
    "001-12345678",
    "001-123456-78",
    "01-1234567-8",
    "001-1234567-88",
    "001-1234567-A",
    "AB1234567",
    "P1234567",
    " 001-1234567-8",
    "001-1234567-8 ",
    " 001-1234567-8 ",
    "001 -1234567-8",
    "001-1234567- 8",
    "001-1234567-8\n",
    "001-1234567-8\u00a0",
    "001\u3000-1234567-8",
  ])("rejects %j", (value) => {
    expect(isValidDominicanRepublicCie(value)).toBe(false);
  });

  it("names the dashed shape and the passport exclusion in the error message", () => {
    expect(DOMINICAN_REPUBLIC_CIE_ERROR_MESSAGE).toContain("13 characters including the dashes");
    expect(DOMINICAN_REPUBLIC_CIE_ERROR_MESSAGE).toContain("123-1234567-1");
    expect(DOMINICAN_REPUBLIC_CIE_ERROR_MESSAGE).toContain("A passport number is not accepted");
  });
});
