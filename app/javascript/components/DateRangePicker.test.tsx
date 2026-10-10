// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { differenceInCalendarDays } from "date-fns";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { DateRangePicker } from "$app/components/DateRangePicker";
import { UserAgentProvider } from "$app/components/UserAgent";

afterEach(() => {
  cleanup();
  vi.useRealTimers();
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
