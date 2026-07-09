import { describe, expect, it } from "vitest";

import { provinceForCanadianPostalCode } from "$app/utils/canadianPostalCodes";

describe("provinceForCanadianPostalCode", () => {
  it("maps postal codes to their province or territory", () => {
    expect(provinceForCanadianPostalCode("A1A 1A1")).toBe("NL");
    expect(provinceForCanadianPostalCode("B3H 1X1")).toBe("NS");
    expect(provinceForCanadianPostalCode("C1A 1A1")).toBe("PE");
    expect(provinceForCanadianPostalCode("E1A 1A1")).toBe("NB");
    expect(provinceForCanadianPostalCode("G1A 1A1")).toBe("QC");
    expect(provinceForCanadianPostalCode("H2X 1Y4")).toBe("QC");
    expect(provinceForCanadianPostalCode("J4B 5E4")).toBe("QC");
    expect(provinceForCanadianPostalCode("K1A 0B1")).toBe("ON");
    expect(provinceForCanadianPostalCode("L4W 1S9")).toBe("ON");
    expect(provinceForCanadianPostalCode("M5V 3L9")).toBe("ON");
    expect(provinceForCanadianPostalCode("N2L 3G1")).toBe("ON");
    expect(provinceForCanadianPostalCode("P3E 5J1")).toBe("ON");
    expect(provinceForCanadianPostalCode("R3C 4A5")).toBe("MB");
    expect(provinceForCanadianPostalCode("S4P 3Y2")).toBe("SK");
    expect(provinceForCanadianPostalCode("T5J 2R7")).toBe("AB");
    expect(provinceForCanadianPostalCode("V6B 4Y8")).toBe("BC");
    expect(provinceForCanadianPostalCode("Y1A 2C6")).toBe("YT");
  });

  it("splits the shared X prefix between Nunavut and the Northwest Territories", () => {
    expect(provinceForCanadianPostalCode("X0A 0H0")).toBe("NU"); // Iqaluit
    expect(provinceForCanadianPostalCode("X0B 0C0")).toBe("NU");
    expect(provinceForCanadianPostalCode("X0C 0G0")).toBe("NU");
    expect(provinceForCanadianPostalCode("X1A 2P3")).toBe("NT"); // Yellowknife
    expect(provinceForCanadianPostalCode("X0E 0T0")).toBe("NT");
  });

  it("normalizes spacing and casing", () => {
    expect(provinceForCanadianPostalCode("k1a0b1")).toBe("ON");
    expect(provinceForCanadianPostalCode(" v6b 4y8 ")).toBe("BC");
    expect(provinceForCanadianPostalCode("M5V")).toBe("ON");
  });

  it("returns null for non-Canadian or missing postal codes", () => {
    expect(provinceForCanadianPostalCode("90210")).toBeNull(); // US ZIP
    expect(provinceForCanadianPostalCode("SW1A 1AA")).toBeNull(); // UK
    expect(provinceForCanadianPostalCode("D0B 1A1")).toBeNull(); // "D" is not a valid Canadian FSA letter
    expect(provinceForCanadianPostalCode("")).toBeNull();
    expect(provinceForCanadianPostalCode(null)).toBeNull();
    expect(provinceForCanadianPostalCode(undefined)).toBeNull();
  });
});
