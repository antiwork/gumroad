import { describe, expect, it } from "vitest";

import {
  expectedSalesFractionOfDay,
  fractionOfDayElapsed,
  MINIMUM_ELAPSED_DAY_FRACTION,
  projectedEndOfDayTotal,
} from "./projectedEndOfDayTotal";

// A curve where all of a typical day's revenue arrives between noon and 6 PM,
// uniformly ($1/6 of the day's revenue per hour). curve[h] = cumulative fraction
// booked by the END of hour h.
const afternoonCurve = Array.from({ length: 24 }, (_, hour) => {
  if (hour < 12) return 0;
  if (hour >= 18) return 1;
  return (hour - 11) / 6;
});

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

  it("divides by the expected historical fraction when provided", () => {
    // $6,000 booked when the seller has historically booked 40% of a day's revenue
    // projects to $15,000 — even though only 25% of the clock day has elapsed.
    expect(projectedEndOfDayTotal(600000, 0.25, 0.4)).toBe(1500000);
  });

  it("falls back to the elapsed clock fraction when the expected fraction is null or near zero", () => {
    // Null curve fraction → uniform run rate.
    expect(projectedEndOfDayTotal(100000, 0.5, null)).toBe(200000);
    // A near-zero expected fraction would explode the estimate; fall back instead.
    expect(projectedEndOfDayTotal(100000, 0.5, 0.001)).toBe(200000);
  });

  it("projects today's actual total once the expected fraction reaches 1", () => {
    // Historically the day's sales are fully booked by now — nothing more expected.
    expect(projectedEndOfDayTotal(100000, 0.9, 1)).toBe(100000);
  });

  it("never projects below today's booked total", () => {
    expect(projectedEndOfDayTotal(100000, 0.5, 0.99)).toBeGreaterThanOrEqual(100000);
  });

  it("still suppresses projections in the first hour of the day regardless of the curve", () => {
    expect(projectedEndOfDayTotal(100000, MINIMUM_ELAPSED_DAY_FRACTION - 0.001, 0.5)).toBeNull();
  });
});

describe("expectedSalesFractionOfDay", () => {
  it("interpolates the cumulative fraction from the curve at the current local time", () => {
    // 14:30 in UTC: end of hour 13 is 2/6, end of hour 14 is 3/6 → halfway between.
    expect(expectedSalesFractionOfDay(afternoonCurve, "UTC", new Date("2026-07-16T14:30:00Z"))).toBeCloseTo(
      2 / 6 + (1 / 6) * 0.5,
    );
    // Same instant is 07:30 in Los Angeles — before this seller's sales start.
    expect(expectedSalesFractionOfDay(afternoonCurve, "America/Los_Angeles", new Date("2026-07-16T14:30:00Z"))).toBe(0);
  });

  it("reaches 1 by the end of the day", () => {
    expect(expectedSalesFractionOfDay(afternoonCurve, "UTC", new Date("2026-07-16T23:59:00Z"))).toBeCloseTo(1, 2);
  });

  it("returns null for missing or malformed curves", () => {
    expect(expectedSalesFractionOfDay(null, "UTC")).toBeNull();
    expect(expectedSalesFractionOfDay(undefined, "UTC")).toBeNull();
    expect(expectedSalesFractionOfDay([0.5, 1], "UTC")).toBeNull();
    // Not monotonically non-decreasing.
    expect(expectedSalesFractionOfDay([...afternoonCurve.slice(0, 23), 0.5], "UTC")).toBeNull();
    // Doesn't end at 1.
    expect(
      expectedSalesFractionOfDay(
        Array.from({ length: 24 }, (_, hour) => hour / 48),
        "UTC",
      ),
    ).toBeNull();
    // Out-of-range values.
    expect(
      expectedSalesFractionOfDay(
        Array.from({ length: 24 }, () => Number.NaN),
        "UTC",
      ),
    ).toBeNull();
  });

  it("returns null for an unknown time zone", () => {
    expect(expectedSalesFractionOfDay(afternoonCurve, "Not/AZone")).toBeNull();
  });

  it("indexes by wall-clock hour on DST transition days", () => {
    // US DST starts 2026-03-08 in Los Angeles; 19:00 UTC is local noon (PDT). The
    // curve is wall-clock indexed, so local noon reads the hour-12 bucket as usual.
    expect(expectedSalesFractionOfDay(afternoonCurve, "America/Los_Angeles", new Date("2026-03-08T19:00:00Z"))).toBe(0);
    expect(
      expectedSalesFractionOfDay(afternoonCurve, "America/Los_Angeles", new Date("2026-03-08T20:00:00Z")),
    ).toBeCloseTo(1 / 6);
  });
});
