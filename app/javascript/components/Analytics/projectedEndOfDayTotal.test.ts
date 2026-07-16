import { describe, expect, it } from "vitest";

import { fractionOfDayElapsed, MINIMUM_ELAPSED_DAY_FRACTION, projectedEndOfDayTotal } from "./projectedEndOfDayTotal";

describe("fractionOfDayElapsed", () => {
  it("returns the elapsed fraction of the day in the given time zone", () => {
    // 18:00 UTC = 75% of the day elapsed in UTC
    expect(fractionOfDayElapsed("UTC", new Date("2026-07-16T18:00:00Z"))).toBeCloseTo(0.75);
    // Same instant is 11:00 in Los Angeles (UTC-7 in July)
    expect(fractionOfDayElapsed("America/Los_Angeles", new Date("2026-07-16T18:00:00Z"))).toBeCloseTo(11 / 24);
  });

  it("handles midnight as zero elapsed", () => {
    expect(fractionOfDayElapsed("UTC", new Date("2026-07-16T00:00:00Z"))).toBe(0);
  });

  it("uses the real day length on a spring-forward DST day (23 hours)", () => {
    // US DST starts 2026-03-08 in Los Angeles: local midnight is 08:00 UTC (PST),
    // the next local midnight is 07:00 UTC on Mar 9 (PDT) — a 23-hour day.
    // Local noon (19:00 UTC) is therefore 11 elapsed hours of 23, not 12 of 24.
    expect(fractionOfDayElapsed("America/Los_Angeles", new Date("2026-03-08T19:00:00Z"))).toBeCloseTo(11 / 23);
  });

  it("uses the real day length on a fall-back DST day (25 hours)", () => {
    // US DST ends 2026-11-01 in Los Angeles: local midnight is 07:00 UTC (PDT),
    // the next local midnight is 08:00 UTC on Nov 2 (PST) — a 25-hour day.
    // Local noon (20:00 UTC) is therefore 13 elapsed hours of 25.
    expect(fractionOfDayElapsed("America/Los_Angeles", new Date("2026-11-01T20:00:00Z"))).toBeCloseTo(13 / 25);
  });

  it("returns null for an unknown time zone", () => {
    expect(fractionOfDayElapsed("Not/AZone", new Date())).toBeNull();
  });
});

describe("projectedEndOfDayTotal", () => {
  it("extrapolates the current total using the run rate so far", () => {
    // $7,200 by 6pm (75% of the day) projects to $9,600
    expect(projectedEndOfDayTotal(720000, 0.75)).toBe(960000);
    expect(projectedEndOfDayTotal(100000, 0.5)).toBe(200000);
  });

  it("returns null when too little of the day has elapsed", () => {
    expect(projectedEndOfDayTotal(720000, MINIMUM_ELAPSED_DAY_FRACTION - 0.001)).toBeNull();
    expect(projectedEndOfDayTotal(720000, MINIMUM_ELAPSED_DAY_FRACTION)).not.toBeNull();
  });

  it("returns null when the day is over or the fraction is unknown", () => {
    expect(projectedEndOfDayTotal(720000, 1)).toBeNull();
    expect(projectedEndOfDayTotal(720000, null)).toBeNull();
  });

  it("returns null when there are no sales yet", () => {
    expect(projectedEndOfDayTotal(0, 0.5)).toBeNull();
  });
});
