// @vitest-environment happy-dom
import { act, cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { SlowConnectionNotice } from "$app/components/Authentication/SlowConnectionNotice";

const SLOW_NOTICE = /taking longer than usual/i;

const advance = (ms: number) =>
  act(() => {
    vi.advanceTimersByTime(ms);
  });

beforeEach(() => vi.useFakeTimers());

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

describe("SlowConnectionNotice", () => {
  it("stays hidden while the visit is within a normal page load", () => {
    render(<SlowConnectionNotice processing />);

    advance(14_000);

    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("warns with a reload path when the visit is still in flight after the timeout", () => {
    render(<SlowConnectionNotice processing />);

    advance(15_000);

    // A stalled visit means the next page never arrives; the reload is the only way off the form,
    // because Inertia keeps the current page (and the disabled submit) until the visit finishes.
    const notice = screen.getByRole("alert");
    expect(notice.textContent).toMatch(SLOW_NOTICE);
    expect(screen.getByRole("link", { name: "Reload the page" }).getAttribute("href")).toBe(window.location.href);
  });

  it("stays hidden when no visit is in flight", () => {
    render(<SlowConnectionNotice processing={false} />);

    advance(60_000);

    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("clears the warning once the visit finishes", () => {
    const { rerender } = render(<SlowConnectionNotice processing />);
    advance(15_000);
    expect(screen.getByRole("alert").textContent).toMatch(SLOW_NOTICE);

    rerender(<SlowConnectionNotice processing={false} />);
    advance(60_000);

    expect(screen.queryByRole("alert")).toBeNull();
  });
});
