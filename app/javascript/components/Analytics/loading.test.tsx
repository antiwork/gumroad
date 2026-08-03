// @vitest-environment happy-dom
//
// The Analytics loading state is markup that only exists between navigation and data arrival, so
// nothing that asserts the finished page can see it. These cover the two properties a reviewer
// would otherwise have to take on trust: the skeletons announce themselves to a screen reader, and
// the route no longer falls back to the old spinner text (gumroad-private#1735).
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { AnalyticsTableSkeleton, SalesChartSkeleton } from "$app/components/Analytics/LoadingSkeleton";

afterEach(cleanup);

describe("Analytics loading skeletons", () => {
  it("marks the chart placeholder as busy and names what is loading", () => {
    render(<SalesChartSkeleton />);

    const section = screen.getByText("Loading sales chart…").closest("section");
    expect(section?.getAttribute("aria-busy")).toBe("true");
    expect(section?.querySelectorAll('[data-slot="skeleton"]').length).toBeGreaterThan(0);
  });

  it("renders one skeleton cell per column, for the header plus five rows", () => {
    render(<AnalyticsTableSkeleton label="referrers" columns={5} />);

    const section = screen.getByText("Loading referrers…").closest("section");
    expect(section?.getAttribute("aria-busy")).toBe("true");
    expect(section?.querySelectorAll(String.raw`[data-slot="skeleton"]`).length).toBe(5 * 6);
  });

  it("leaves no spinner text on the Analytics route", async () => {
    const source = (await import("$app/components/Analytics/index.tsx?raw")).default;

    expect(source).not.toContain("Loading charts...");
    expect(source).not.toContain("Loading referrers...");
    expect(source).not.toContain("Loading locations...");
    expect(source).toContain("SalesChartSkeleton");
    expect(source).toContain("AnalyticsTableSkeleton");
  });
});
