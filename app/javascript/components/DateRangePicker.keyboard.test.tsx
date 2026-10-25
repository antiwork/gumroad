// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { CurrentSellerProvider } from "$app/components/CurrentSeller";
import { DateRangePicker } from "$app/components/DateRangePicker";
import { UserAgentProvider } from "$app/components/UserAgent";

afterEach(cleanup);

const setup = () => {
  const setFrom = vi.fn();
  const setTo = vi.fn();
  render(
    <UserAgentProvider value={{ isMobile: false, locale: "en-US" }}>
      <CurrentSellerProvider value={null}>
        <DateRangePicker from={new Date(2026, 9, 1)} to={new Date(2026, 9, 20)} setFrom={setFrom} setTo={setTo} />
      </CurrentSellerProvider>
    </UserAgentProvider>,
  );
  const trigger = screen.getByRole("button");
  fireEvent.click(trigger);
  return { trigger, setFrom, setTo };
};

describe("DateRangePicker keyboard menu", () => {
  it("renders native non-submitting menu actions with one tab stop", () => {
    setup();
    const items = screen.getAllByRole<HTMLButtonElement>("menuitem");
    expect(items).toHaveLength(12);
    for (const item of items) {
      expect(item.tagName).toBe("BUTTON");
      expect(item.type).toBe("button");
    }
    expect(items.map((item) => item.tabIndex)).toEqual([0, ...Array<number>(11).fill(-1)]);
  });

  it("moves focus with arrows, wraps, and honors Home and End without selecting", () => {
    const { setFrom, setTo } = setup();
    const first = screen.getByRole("menuitem", { name: "Today" });
    const last = screen.getByRole("menuitem", { name: "Custom range..." });
    first.focus();
    fireEvent.keyDown(first, { key: "ArrowUp" });
    expect(document.activeElement).toBe(last);
    fireEvent.keyDown(last, { key: "ArrowDown" });
    expect(document.activeElement).toBe(first);
    fireEvent.keyDown(first, { key: "End" });
    expect(document.activeElement).toBe(last);
    fireEvent.keyDown(last, { key: "Home" });
    expect(document.activeElement).toBe(first);
    fireEvent.keyDown(first, { key: "ArrowDown" });
    expect(document.activeElement).toBe(screen.getByRole("menuitem", { name: "Last 7 days" }));
    expect(setFrom).not.toHaveBeenCalled();
    expect(setTo).not.toHaveBeenCalled();
  });

  it("moves the tab stop with focus", () => {
    setup();
    const first = screen.getByRole("menuitem", { name: "Today" });
    const next = screen.getByRole("menuitem", { name: "Last 7 days" });
    fireEvent.focus(next);
    expect(next.tabIndex).toBe(0);
    expect(first.tabIndex).toBe(-1);
  });

  it("opens custom dates with the From field focused", () => {
    setup();
    fireEvent.click(screen.getByRole("menuitem", { name: "Custom range..." }));
    expect(document.activeElement).toBe(screen.getByLabelText("From (including)"));
  });

  it("keeps ordinary mouse preset selection working and resets the menu on reopen", () => {
    const { trigger, setFrom, setTo } = setup();
    fireEvent.click(screen.getByRole("menuitem", { name: "Last 7 days" }));
    expect(setFrom).toHaveBeenCalledTimes(1);
    expect(setTo).toHaveBeenCalledTimes(1);
    fireEvent.click(trigger);
    expect(screen.getByRole("menuitem", { name: "Today" }).tabIndex).toBe(0);
  });
});
