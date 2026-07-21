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

  it("renders one faint projection bar behind today's actual bar, same x span, topping out above today's total", () => {
    // Fix "now" to mid-afternoon so the projection guardrails (first hour of the day,
    // completed day) don't suppress the overlay.
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-16T20:00:00Z")); // 4pm in America/New_York

    const { container } = renderChart();

    // The projection bar only carries a value on today's point, so exactly one renders.
    const bars = container.querySelectorAll("[data-testid='chart-projected-bar']");
    expect(bars.length).toBe(1);
    const projectedBar = bars[0];

    // Its horizontal span must match today's actual sales bar (same x position and
    // width) — Sahil's spec: the faint bar sits directly behind the real one so the
    // day's numbers visibly climb toward the projection.
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
    const pathXValues = [...(projectedBar?.getAttribute("d") ?? "").matchAll(/[ML] ([\d.]+),/gu)].map((match) =>
      Number(match[1]),
    );
    expect(pathXValues.length).toBeGreaterThan(0);
    expect(Math.min(...pathXValues)).toBeCloseTo(Number(todaysBar?.getAttribute("x")), 5);
    expect(Math.max(...pathXValues)).toBeCloseTo(
      Number(todaysBar?.getAttribute("x")) + Number(todaysBar?.getAttribute("width")),
      5,
    );

    // Its top must sit above today's actual total on the money axis (a projection is
    // always higher than the booked total), so the bar visibly rises past the line.
    const dots = container.querySelectorAll("[data-testid='chart-dot']");
    const lastDot = dots[dots.length - 1];
    expect(lastDot).toBeDefined();
    const pathYValues = [...(projectedBar?.getAttribute("d") ?? "").matchAll(/,([\d.]+)/gu)].map((match) =>
      Number(match[1]),
    );
    expect(pathYValues.length).toBeGreaterThan(0);
    expect(Math.min(...pathYValues)).toBeLessThan(Number(lastDot?.getAttribute("cy")));

    // The earlier marker treatments are gone: no dotted tick, no vertical connector
    // line, no circle cap (see #6048 — the tick rendered mispositioned on mobile).
    expect(container.querySelector("[data-testid='chart-projected-tick']")).toBeNull();
    expect(container.querySelector("[data-testid='chart-projection-line']")).toBeNull();
    expect(container.querySelector("[data-testid='chart-projected-dot']")).toBeNull();

    expectNoNaNAttributes(container);
  });

  it("does not render the projection overlay on the monthly view", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-16T20:00:00Z"));

    const { container } = renderChart({ aggregateBy: "monthly" });

    expect(container.querySelector("[data-testid='chart-projected-bar']")).toBeNull();
    expectNoNaNAttributes(container);
  });

  it("does not render the projection overlay when the range does not end today", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-16T20:00:00Z"));

    const { container } = renderChart({ endDate: "Jul 10" });

    expect(container.querySelector("[data-testid='chart-projected-bar']")).toBeNull();
    expectNoNaNAttributes(container);
  });
});
