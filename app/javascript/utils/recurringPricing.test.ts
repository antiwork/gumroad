import { describe, it, expect } from "vitest";

import { formatRecurrenceWithDuration, isSingleChargeDuration } from "$app/utils/recurringPricing";

describe("isSingleChargeDuration", () => {
  it("returns true when the membership duration equals a single recurrence period", () => {
    expect(isSingleChargeDuration("yearly", 12)).toBe(true);
    expect(isSingleChargeDuration("monthly", 1)).toBe(true);
    expect(isSingleChargeDuration("every_two_years", 24)).toBe(true);
  });

  it("returns false when the membership charges more than once", () => {
    expect(isSingleChargeDuration("yearly", 24)).toBe(false);
    expect(isSingleChargeDuration("monthly", 12)).toBe(false);
  });

  it("returns false when the membership has no fixed duration", () => {
    expect(isSingleChargeDuration("yearly", null)).toBe(false);
  });
});

describe("formatRecurrenceWithDuration", () => {
  it("returns the plain recurrence label when there is no fixed duration", () => {
    expect(formatRecurrenceWithDuration("yearly", null)).toBe("a year");
  });

  it("appends the number of charges for a fixed duration spanning several periods", () => {
    expect(formatRecurrenceWithDuration("yearly", 24)).toBe("a year x 2");
    expect(formatRecurrenceWithDuration("monthly", 3)).toBe("a month x 3");
  });

  it("renders one-time wording when the fixed duration is a single period", () => {
    expect(formatRecurrenceWithDuration("yearly", 12)).toBe("once");
    expect(formatRecurrenceWithDuration("monthly", 1)).toBe("once");
  });
});
