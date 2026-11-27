import { describe, expect, it } from "vitest";

import { largeEmailLimitWarning } from "$app/components/EmailsPage/largeEmailLimit";

const limit = {
  threshold: 10000,
  reason: "used" as const,
  date: "2026-11-27",
  next_send_window: { starts_at: "2026-11-28T03:00:00Z", ends_at: "2026-11-28T07:00:00Z" },
};
const base = {
  limit,
  recipients: 369000,
  sendAt: new Date("2026-11-27T08:00:00Z"),
  locale: "en-US",
  timeZone: "America/New_York",
};

describe("largeEmailLimitWarning", () => {
  it("names the overnight window in the seller's time zone", () => {
    expect(largeEmailLimitWarning(base)).toBe(
      "You've already used your daily limit for large emails today. This email will wait and send between Nov 27, 2026, 10:00 PM and 2:00 AM (America/New_York), not right away. You can still go ahead.",
    );
  });

  it("says an earlier large email goes first", () => {
    expect(largeEmailLimitWarning({ ...base, limit: { ...limit, reason: "waiting" } })).toContain(
      "An earlier large email is still waiting for your daily limit for large emails and goes first.",
    );
  });

  it("stays quiet when nothing will delay the email", () => {
    expect(largeEmailLimitWarning({ ...base, limit: null })).toBeNull();
    expect(largeEmailLimitWarning({ ...base, limit: { ...limit, reason: null } })).toBeNull();
    expect(largeEmailLimitWarning({ ...base, limit: { ...limit, next_send_window: null } })).toBeNull();
    expect(largeEmailLimitWarning({ ...base, recipients: 9999 })).toBeNull();
    expect(largeEmailLimitWarning({ ...base, recipients: null })).toBeNull();
  });

  it("does not warn for an email scheduled on another UTC day, which meets a different slot", () => {
    expect(largeEmailLimitWarning({ ...base, sendAt: new Date("2026-11-29T08:00:00Z") })).toBeNull();
  });
});
