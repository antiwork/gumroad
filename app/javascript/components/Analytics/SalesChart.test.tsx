// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { type AnalyticsDailyTotal } from "$app/components/Analytics";
import { SalesChart } from "$app/components/Analytics/SalesChart";
import { UserAgentProvider } from "$app/components/UserAgent";

// ResponsiveContainer measures its DOM node, which has no size in a headless test
// environment, so the chart would render nothing. Replace it with a passthrough that
// hands the chart a fixed size, keeping everything else in recharts real.
vi.mock("recharts", async (importOriginal) => {
  const recharts = await importOriginal<typeof import("recharts")>();
  const ResponsiveContainer = React.forwardRef(({ children }: { children: React.ReactElement }, _ref) => (
    <div style={{ width: 800, height: 400 }}>{React.cloneElement(children, { width: 800, height: 400 })}</div>
  ));
  ResponsiveContainer.displayName = "ResponsiveContainer";
  return { ...recharts, ResponsiveContainer };
});

const dailyTotal = (date: string, totals: number): AnalyticsDailyTotal => ({
  date,
  month: "July 2026",
  monthIndex: 0,
  sales: 2,
  views: 10,
  totals,
});

const data = [
  dailyTotal("Sunday, July 12th", 1_000),
  dailyTotal("Monday, July 13th", 2_000),
  dailyTotal("Tuesday, July 14th", 1_500),
  dailyTotal("Wednesday, July 15th", 3_000),
  dailyTotal("Thursday, July 16th", 7_200),
];

const renderChart = (props: Partial<React.ComponentProps<typeof SalesChart>> = {}) =>
  render(
    // SalesChart (via the hourly-view work that landed on main) reads the user-agent context, so
    // the test must provide it the same way the real page layout does.
    <UserAgentProvider value={{ isMobile: false, locale: "en-US" }}>
      <SalesChart
        data={data}
        startDate="Jul 12"
        endDate="Today"
        aggregateBy="daily"
        sellerTimeZone="America/New_York"
        {...props}
      />
    </UserAgentProvider>,
  );

const expectNoNaNAttributes = (container: HTMLElement) => {
  for (const element of container.querySelectorAll("*")) {
    for (const attribute of element.attributes) {
      expect(attribute.value, `${element.tagName} ${attribute.name} should not be NaN`).not.toMatch(/NaN/u);
    }
  }
};

describe("SalesChart projection overlay", () => {
  afterEach(() => {
    cleanup();
    vi.useRealTimers();
  });

  it("renders the dashed projection line and dot with finite coordinates for a daily range ending today", () => {
    // Fix "now" to mid-afternoon so the projection guardrails (first hour of the day,
    // completed day) don't suppress the overlay.
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-16T20:00:00Z")); // 4pm in America/New_York

    const { container } = renderChart();

    const projectionLine = container.querySelector("[data-testid='chart-projection-line']");
    const projectedDot = container.querySelector("[data-testid='chart-projected-dot']");
    expect(projectionLine).not.toBeNull();
    expect(projectedDot).not.toBeNull();
    expect(projectionLine?.getAttribute("stroke-dasharray")).toBe("4 4");

    for (const attribute of ["x1", "x2", "y1", "y2"]) {
      expect(Number.isFinite(Number(projectionLine?.getAttribute(attribute)))).toBe(true);
    }
    for (const attribute of ["cx", "cy"]) {
      expect(Number.isFinite(Number(projectedDot?.getAttribute(attribute)))).toBe(true);
    }
    // The dashed extension starts at today's actual total and goes UP to the projection.
    expect(Number(projectionLine?.getAttribute("y2"))).toBeLessThan(Number(projectionLine?.getAttribute("y1")));

    expectNoNaNAttributes(container);
  });

  it("does not render the projection overlay on the monthly view", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-16T20:00:00Z"));

    const { container } = renderChart({ aggregateBy: "monthly" });

    expect(container.querySelector("[data-testid='chart-projection-line']")).toBeNull();
    expect(container.querySelector("[data-testid='chart-projected-dot']")).toBeNull();
    expectNoNaNAttributes(container);
  });

  it("does not render the projection overlay when the range does not end today", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-16T20:00:00Z"));

    const { container } = renderChart({ endDate: "Jul 10" });

    expect(container.querySelector("[data-testid='chart-projection-line']")).toBeNull();
    expect(container.querySelector("[data-testid='chart-projected-dot']")).toBeNull();
    expectNoNaNAttributes(container);
  });
});
