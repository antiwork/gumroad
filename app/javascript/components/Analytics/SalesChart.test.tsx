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

  it("renders the dotted projection tick with finite coordinates for a daily range ending today", () => {
    // Fix "now" to mid-afternoon so the projection guardrails (first hour of the day,
    // completed day) don't suppress the overlay.
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-16T20:00:00Z")); // 4pm in America/New_York

    const { container } = renderChart();

    const projectedTick = container.querySelector("[data-testid='chart-projected-tick']");
    expect(projectedTick).not.toBeNull();
    expect(projectedTick?.getAttribute("stroke-dasharray")).toBe("2 2");

    for (const attribute of ["x1", "x2", "y1", "y2"]) {
      expect(Number.isFinite(Number(projectedTick?.getAttribute(attribute)))).toBe(true);
    }
    // The tick is horizontal (constant y) and has real width along x.
    expect(Number(projectedTick?.getAttribute("y1"))).toBe(Number(projectedTick?.getAttribute("y2")));
    expect(Number(projectedTick?.getAttribute("x2"))).toBeGreaterThan(Number(projectedTick?.getAttribute("x1")));
    // The old vertical connector line and circle cap are gone.
    expect(container.querySelector("[data-testid='chart-projection-line']")).toBeNull();
    expect(container.querySelector("[data-testid='chart-projected-dot']")).toBeNull();

    expectNoNaNAttributes(container);
  });

  it("anchors the tick at today's data point and renders exactly one tick", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-16T20:00:00Z"));

    const { container } = renderChart();

    // The invisible projectedTotals line calls the dot renderer for every data point,
    // but only today's point carries a value — so exactly one tick may render.
    const ticks = container.querySelectorAll("[data-testid='chart-projected-tick']");
    expect(ticks.length).toBe(1);
    const projectedTick = ticks[0];

    // The tick must be horizontally centered on the totals line's last (today's) dot —
    // this is the regression from #6048, where a stale coordinate snapshot let the tick
    // drift left toward the first x-axis label on mobile.
    const dots = container.querySelectorAll("[data-testid='chart-dot']");
    const lastDot = dots[dots.length - 1];
    expect(lastDot).toBeDefined();
    const tickCenter = (Number(projectedTick?.getAttribute("x1")) + Number(projectedTick?.getAttribute("x2"))) / 2;
    expect(tickCenter).toBeCloseTo(Number(lastDot?.getAttribute("cx")), 5);

    // And it must sit above today's actual total (a projection is always higher).
    expect(Number(projectedTick?.getAttribute("y1"))).toBeLessThan(Number(lastDot?.getAttribute("cy")));
  });

  it("renders one faint projection bar behind today's actual bar, same x span, topping out at the tick", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-16T20:00:00Z"));

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

    // Its top must sit at the projected total — the same y as the dotted tick — so the
    // bar visually rises exactly to the projection marker.
    const projectedTick = container.querySelector("[data-testid='chart-projected-tick']");
    const pathYValues = [...(projectedBar?.getAttribute("d") ?? "").matchAll(/,([\d.]+)/gu)].map((match) =>
      Number(match[1]),
    );
    expect(Math.min(...pathYValues)).toBeCloseTo(Number(projectedTick?.getAttribute("y1")), 5);
  });

  it("does not render the projection overlay on the monthly view", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-16T20:00:00Z"));

    const { container } = renderChart({ aggregateBy: "monthly" });

    expect(container.querySelector("[data-testid='chart-projected-tick']")).toBeNull();
    expect(container.querySelector("[data-testid='chart-projected-bar']")).toBeNull();
    expectNoNaNAttributes(container);
  });

  it("does not render the projection overlay when the range does not end today", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-16T20:00:00Z"));

    const { container } = renderChart({ endDate: "Jul 10" });

    expect(container.querySelector("[data-testid='chart-projected-tick']")).toBeNull();
    expect(container.querySelector("[data-testid='chart-projected-bar']")).toBeNull();
    expectNoNaNAttributes(container);
  });
});
