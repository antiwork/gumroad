import { describe, expect, it } from "vitest";

import {
  EU_WITHDRAWAL_RIGHT_COUNTRY_CODES,
  euWithdrawalConsentApplies,
} from "$app/components/Checkout/euWithdrawalConsent";

describe("euWithdrawalConsentApplies", () => {
  it("applies to a non-physical line for a buyer in an EU member state", () => {
    expect(euWithdrawalConsentApplies("DE", ["digital"])).toBe(true);
    expect(euWithdrawalConsentApplies("DE", ["commission"])).toBe(true);
  });

  it("does not apply to a physical line, whose withdrawal right cannot be waived", () => {
    expect(euWithdrawalConsentApplies("DE", ["physical"])).toBe(false);
  });

  it("applies when any line in a mixed cart is not physical", () => {
    expect(euWithdrawalConsentApplies("DE", ["physical", "digital"])).toBe(true);
  });

  it("does not apply outside the EU", () => {
    expect(euWithdrawalConsentApplies("US", ["digital"])).toBe(false);
    expect(euWithdrawalConsentApplies("GB", ["digital"])).toBe(false);
    expect(euWithdrawalConsentApplies("CH", ["digital"])).toBe(false);
    expect(euWithdrawalConsentApplies("", ["digital"])).toBe(false);
    expect(euWithdrawalConsentApplies(null, ["digital"])).toBe(false);
    expect(euWithdrawalConsentApplies(undefined, ["digital"])).toBe(false);
  });

  it("carries the 27 member states and excludes the UK", () => {
    expect(EU_WITHDRAWAL_RIGHT_COUNTRY_CODES.size).toBe(27);
    expect(EU_WITHDRAWAL_RIGHT_COUNTRY_CODES.has("GB")).toBe(false);
    expect(EU_WITHDRAWAL_RIGHT_COUNTRY_CODES.has("MT")).toBe(true);
  });
});
