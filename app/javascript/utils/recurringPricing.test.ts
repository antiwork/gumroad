import { describe, it, expect } from "vitest";

import {
  formatRecurrenceWithDuration,
  isSingleChargeDuration,
  renewalReminderNotice,
} from "$app/utils/recurringPricing";

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

describe("renewalReminderNotice", () => {
  const recurrences = {
    enabled: [
      { recurrence: "monthly" as const, renewal_reminder_days: [1] },
      { recurrence: "yearly" as const, renewal_reminder_days: [30, 7] },
    ],
  };

  it("lists each reminder lead time for the selected recurrence", () => {
    expect(renewalReminderNotice(recurrences, "monthly")).toBe("We'll email you a reminder 1 day before each renewal.");
    expect(renewalReminderNotice(recurrences, "yearly")).toBe(
      "We'll email you a reminder 30 days and 7 days before each renewal.",
    );
  });

  it("names the trial-ending email separately from the later renewal reminders", () => {
    const withTrial = { ...recurrences, free_trial_reminder_days: 2 };

    expect(renewalReminderNotice(withTrial, "yearly", { freeTrial: true })).toBe(
      "We'll email you a reminder 2 days before your free trial ends, and 30 days and 7 days before each renewal after that.",
    );
    expect(renewalReminderNotice(withTrial, "yearly", { freeTrial: false })).toBe(
      "We'll email you a reminder 30 days and 7 days before each renewal.",
    );
    expect(renewalReminderNotice(recurrences, "yearly", { freeTrial: true })).toBeNull();
  });

  it("returns null without a recurrence or lead times", () => {
    expect(renewalReminderNotice(null, "yearly")).toBeNull();
    expect(renewalReminderNotice(recurrences, null)).toBeNull();
    expect(renewalReminderNotice({ enabled: [{ recurrence: "yearly" }] }, "yearly")).toBeNull();
    expect(
      renewalReminderNotice({ enabled: [{ recurrence: "yearly", renewal_reminder_days: [] }] }, "yearly"),
    ).toBeNull();
  });
});
