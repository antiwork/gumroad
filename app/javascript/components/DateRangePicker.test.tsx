// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { differenceInCalendarDays, lightFormat } from "date-fns";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { DateRangePicker } from "$app/components/DateRangePicker";
import { UserAgentProvider } from "$app/components/UserAgent";

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

it.each([
  { timeZone: "Pacific/Honolulu", label: "Today", from: "2025-12-31", to: "2025-12-31" },
  { timeZone: "Pacific/Honolulu", label: "Last 7 days", from: "2025-12-25", to: "2025-12-31" },
  { timeZone: "Pacific/Honolulu", label: "Last month", from: "2025-11-01", to: "2025-11-30" },
  { timeZone: "Pacific/Kiritimati", label: "Today", from: "2026-01-01", to: "2026-01-01" },
  { timeZone: "Pacific/Kiritimati", label: "Last 7 days", from: "2025-12-26", to: "2026-01-01" },
  { timeZone: "Pacific/Kiritimati", label: "Last month", from: "2025-12-01", to: "2025-12-31" },
])("anchors $label to the seller's date in $timeZone", ({ label, from, to, timeZone }) => {
  vi.useFakeTimers({ toFake: ["Date"] });
  // The two seller zones are on opposite days at this instant, regardless of the runner's zone.
  vi.setSystemTime(new Date("2026-01-01T08:00:00Z"));
  const setFrom = vi.fn<(date: Date) => void>();
  const setTo = vi.fn<(date: Date) => void>();
  const selected = new Date(2025, 11, 31);
  render(
    <UserAgentProvider value={{ isMobile: false, locale: "en-US" }}>
      <DateRangePicker from={selected} to={selected} setFrom={setFrom} setTo={setTo} timeZone={timeZone} />
    </UserAgentProvider>,
  );

  fireEvent.click(screen.getByRole("button"));
  fireEvent.click(screen.getByRole("menuitem", { name: label }));

  expect(setFrom.mock.calls.map(([date]) => lightFormat(date, "yyyy-MM-dd"))).toEqual([from]);
  expect(setTo.mock.calls.map(([date]) => lightFormat(date, "yyyy-MM-dd"))).toEqual([to]);
});

describe.each([new Date(2026, 9, 9, 12), new Date(2026, 0, 1, 12), new Date(2024, 2, 1, 12)])(
  "DateRangePicker rolling presets on %s",
  (today) => {
    it.each([
      { label: "Today", days: 1 },
      { label: "Last 7 days", days: 7 },
      { label: "Last 30 days", days: 30 },
    ])("includes exactly $days calendar days for $label", ({ label, days }) => {
      vi.useFakeTimers({ toFake: ["Date"] });
      vi.setSystemTime(today);
      const setFrom = vi.fn<(date: Date) => void>();
      const setTo = vi.fn<(date: Date) => void>();
      render(
        <UserAgentProvider value={{ isMobile: false, locale: "en-US" }}>
          <DateRangePicker from={new Date(today)} to={new Date(today)} setFrom={setFrom} setTo={setTo} />
        </UserAgentProvider>,
      );

      fireEvent.click(screen.getByRole("button"));
      fireEvent.click(screen.getByRole("menuitem", { name: label }));

      const from = setFrom.mock.calls[0]?.[0];
      const to = setTo.mock.calls[0]?.[0];
      expect(from).toBeInstanceOf(Date);
      expect(to).toBeInstanceOf(Date);
      if (!from || !to) throw new Error("Expected both preset endpoints");
      expect(differenceInCalendarDays(to, from) + 1).toBe(days);
      expect(to).toEqual(new Date());
    });
  },
);
