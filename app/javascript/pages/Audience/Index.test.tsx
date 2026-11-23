// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import Audience from "./Index";

const mocks = vi.hoisted(
  (): {
    useAnalyticsDateRange: ReturnType<typeof vi.fn<(timeZone?: string) => void>>;
    pickerTimeZone: string | null;
  } => ({
    useAnalyticsDateRange: vi.fn<(timeZone?: string) => void>(),
    pickerTimeZone: null,
  }),
);

vi.mock("@inertiajs/react", () => ({
  Deferred: ({ children }: React.PropsWithChildren) => <div>{children}</div>,
  router: { reload: vi.fn(), replace: vi.fn() },
  usePage: () => ({
    props: { total_follower_count: 1, audience_data: null, seller_time_zone: "Pacific/Honolulu" },
  }),
}));
vi.mock("$app/components/Analytics/AnalyticsLayout", () => ({
  AnalyticsLayout: ({ children, actions }: React.PropsWithChildren<{ actions?: React.ReactNode }>) => (
    <>
      {actions}
      {children}
    </>
  ),
}));
vi.mock("$app/components/Audience/AudienceChart", () => ({ AudienceChart: () => <div /> }));
vi.mock("$app/components/Audience/AudienceQuickStats", () => ({ AudienceQuickStats: () => <div /> }));
vi.mock("$app/components/Followers/ExportSubscribersPopover", () => ({
  ExportSubscribersPopover: () => <div />,
}));
vi.mock("$app/components/Analytics/useAnalyticsDateRange", () => ({
  useAnalyticsDateRange: (timeZone?: string) => {
    mocks.useAnalyticsDateRange(timeZone);
    return {
      from: new Date("2026-01-01T00:00:00Z"),
      to: new Date("2026-01-01T00:00:00Z"),
      setFrom: vi.fn(),
      setTo: vi.fn(),
    };
  },
}));
vi.mock("$app/components/DateRangePicker", () => ({
  DateRangePicker: ({ timeZone }: { timeZone?: string }) => {
    mocks.pickerTimeZone = timeZone ?? null;
    return <div data-testid="date-range-picker" />;
  },
}));

describe("Audience/Index", () => {
  afterEach(() => {
    cleanup();
    mocks.useAnalyticsDateRange.mockClear();
    mocks.pickerTimeZone = null;
  });

  it("anchors the default range and the presets on the seller's time zone", () => {
    render(<Audience />);

    expect(mocks.useAnalyticsDateRange).toHaveBeenCalledWith("Pacific/Honolulu");
    expect(mocks.pickerTimeZone).toBe("Pacific/Honolulu");
    expect(screen.getByTestId("date-range-picker")).toBeTruthy();
  });
});
