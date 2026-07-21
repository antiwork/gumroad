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

  it("renders one faint projected-total circle centered above today's bar, above today's booked total", () => {
    // Fix "now" to mid-afternoon so the projection guardrails (first hour of the day,
    // completed day) don't suppress the overlay.
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-16T20:00:00Z")); // 4pm in America/New_York

    const { container } = renderChart();

    // The projection series only carries a value on today's point, so exactly one
    // circle renders.
    const projectedDots = container.querySelectorAll("[data-testid='chart-projected-dot']");
    expect(projectedDots.length).toBe(1);
    const projectedDot = projectedDots[0];

    // The circle must be horizontally centered on today's actual sales bar, so it sits
    // directly above today's data point at any viewport width (the anchoring guarantee
    // from #6048 — the old Customized overlay drifted left on mobile).
    const actualBars = container.querySelectorAll("path[data-testid='chart-bar']");
    expect(actualBars.length).toBeGreaterThan(0);
    let todaysBar: Element | null = null;
    let maxX = -Infinity;
    for (const bar of actualBars) {
      const barX = Number(bar.getAttribute("x"));
      if (barX > maxX) {
        maxX = barX;
        todaysBar = bar;
      }
    }
    expect(todaysBar).not.toBeNull();
    const expectedCenterX = Number(todaysBar?.getAttribute("x")) + Number(todaysBar?.getAttribute("width")) / 2;
    expect(Number(projectedDot?.getAttribute("cx"))).toBeCloseTo(expectedCenterX, 5);

    // The projected circle must sit above today's actual total on the money axis (a
    // projection is always higher than the booked total) — so there are two dots for
    // the partial day: the line's solid dot and this faint one above it.
    const dots = container.querySelectorAll("[data-testid='chart-dot']");
    const lastDot = dots[dots.length - 1];
    expect(lastDot).toBeDefined();
    expect(Number(projectedDot?.getAttribute("cy"))).toBeLessThan(Number(lastDot?.getAttribute("cy")));

    // The earlier marker treatments are gone: no dotted tick, no vertical connector
    // line, no shaded background bar (bars in this chart mean counts, not money).
    expect(container.querySelector("[data-testid='chart-projected-tick']")).toBeNull();
    expect(container.querySelector("[data-testid='chart-projection-line']")).toBeNull();
    expect(container.querySelector("[data-testid='chart-projected-bar']")).toBeNull();

    expectNoNaNAttributes(container);
  });

  it("does not render the projection overlay on the monthly view", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-16T20:00:00Z"));

    const { container } = renderChart({ aggregateBy: "monthly" });

    expect(container.querySelector("[data-testid='chart-projected-dot']")).toBeNull();
    expectNoNaNAttributes(container);
  });

  it("does not render the projection overlay when the range does not end today", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-16T20:00:00Z"));

    const { container } = renderChart({ endDate: "Jul 10" });

    expect(container.querySelector("[data-testid='chart-projected-dot']")).toBeNull();
    expectNoNaNAttributes(container);
  });
});
