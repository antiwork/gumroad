// @vitest-environment happy-dom
import { render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { PLACEHOLDER_CARD_PRODUCT } from "$app/utils/cart";

import { RecentlyViewed, RecentlyViewedProps } from "$app/components/Discover/RecentlyViewed";
import { LoggedInUserProvider } from "$app/components/LoggedInUser";

const productAt = (id: string, name: string, viewed_at: string) => ({
  ...PLACEHOLDER_CARD_PRODUCT,
  id,
  name,
  viewed_at,
});

const renderRow = (data: RecentlyViewedProps | null) =>
  render(
    <LoggedInUserProvider value={null}>
      <RecentlyViewed data={data} />
    </LoggedInUserProvider>,
  );

afterEach(() => {
  localStorage.clear();
});

beforeEach(() => {
  localStorage.clear();
});

describe("RecentlyViewed", () => {
  it("renders nothing without data", () => {
    renderRow(null);
    expect(screen.queryByText("Recently viewed")).toBeNull();
  });

  it("clear hides only products viewed before the cutoff, not ones viewed after it", () => {
    const older = productAt("older", "Older Product", "2026-01-01T00:00:00.000Z");
    const data: RecentlyViewedProps = { products: [older] };
    const { rerender } = renderRow(data);
    expect(screen.queryByText("Older Product")).not.toBeNull();

    screen.getByText("Clear").click();
    rerender(
      <LoggedInUserProvider value={null}>
        <RecentlyViewed data={data} />
      </LoggedInUserProvider>,
    );
    expect(screen.queryByText("Older Product")).toBeNull();

    // A view recorded after the clear (server refresh bumps the row) must survive it — the bug
    // T-Rex/greptile flagged was comparing only the newest view, which resurrected every
    // product including ones still legitimately cleared.
    const newer = productAt("newer", "Newer Product", new Date(Date.now() + 60_000).toISOString());
    rerender(
      <LoggedInUserProvider value={null}>
        <RecentlyViewed data={{ products: [older, newer] }} />
      </LoggedInUserProvider>,
    );
    expect(screen.queryByText("Older Product")).toBeNull();
    expect(screen.queryByText("Newer Product")).not.toBeNull();
  });
});
