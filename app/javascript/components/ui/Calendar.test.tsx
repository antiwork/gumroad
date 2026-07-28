// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { Calendar } from "$app/components/ui/Calendar";

afterEach(cleanup);

// The calendar renders on the public product page, which sits outside
// `.scoped-tailwind-preflight` and therefore never gets Tailwind's preflight reset. Without our
// own reset, each day <button> falls back to the browser's native button styling and paints an
// opaque background over its cell, which hides the selected day's accent highlight entirely and
// tints unavailable days with the system colour instead of fading them.
//
// jsdom/happy-dom don't apply UA stylesheets, so we can't observe the painted colour here. What we
// can assert is that the component still ships the class tokens that hold the reset in place, which
// is what actually goes missing if someone trims this class string again.
const augustDay = (day: number) => new Date(2026, 7, day);

// react-day-picker's props are a discriminated union on `mode`, so the overrides have to be typed
// as the single-select variant rather than a Partial of the whole union.
type SingleCalendarProps = Extract<React.ComponentProps<typeof Calendar>, { mode?: "single" }>;

const renderCalendar = (props: Partial<SingleCalendarProps> = {}) =>
  render(
    <Calendar
      mode="single"
      selected={augustDay(12)}
      startMonth={augustDay(1)}
      endMonth={augustDay(31)}
      disabled={(date: Date) => date.getDate() === 27}
      {...props}
    />,
  );

const dayCell = (day: number) => {
  const cell = document.querySelector(`[data-day="2026-08-${String(day).padStart(2, "0")}"]`);
  if (!cell) throw new Error(`expected a cell for August ${day}`);
  return cell;
};

const dayButton = (day: number) => {
  const button = dayCell(day).querySelector("button");
  if (!button) throw new Error(`expected a day button for August ${day}`);
  return button;
};

describe("Calendar", () => {
  it("resets the browser's native button styling on every day, so nothing paints over the cell", () => {
    renderCalendar();

    const classes = dayButton(12).className.split(/\s+/u);
    expect(classes).toContain("appearance-none");
    expect(classes).toContain("bg-transparent");
    expect(classes).toContain("text-inherit");
  });

  it("puts the selected accent on the cell, which the transparent button lets through", () => {
    renderCalendar();

    const selected = dayCell(12);
    expect(selected.getAttribute("data-selected")).toBe("true");
    expect(selected.className).toContain("bg-accent");
    expect(selected.className).toContain("text-accent-foreground");
    // The button must not carry a background of its own, or it would cover the accent above.
    expect(dayButton(12).className).toContain("bg-transparent");
  });

  it("fades unavailable days instead of leaving them at full strength", () => {
    renderCalendar();

    const unavailable = dayCell(27);
    expect(unavailable.getAttribute("data-disabled")).toBe("true");
    expect(unavailable.className).toContain("opacity-30");
    expect(dayButton(27).disabled).toBe(true);
    // An available day must NOT be faded, otherwise the whole grid reads as unavailable.
    expect(dayCell(12).className).not.toContain("opacity-30");
  });

  it("still selects a day when one is clicked", () => {
    const selectedDates: (Date | undefined)[] = [];
    renderCalendar({ onSelect: (date) => selectedDates.push(date) });

    fireEvent.click(dayButton(19));

    expect(selectedDates.at(-1)?.getDate()).toBe(19);
  });

  it("does not select an unavailable day", () => {
    const selectedDates: (Date | undefined)[] = [];
    renderCalendar({ onSelect: (date) => selectedDates.push(date) });

    fireEvent.click(dayButton(27));

    expect(selectedDates).toHaveLength(0);
    expect(screen.getByText("27")).toBeTruthy();
  });
});
