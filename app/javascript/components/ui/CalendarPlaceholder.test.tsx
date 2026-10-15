// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { Calendar } from "$app/components/ui/Calendar";
import { CalendarPlaceholder } from "$app/components/ui/CalendarPlaceholder";

afterEach(cleanup);

type Shape = { tag: string; classes: string[]; text: string | null; children: Shape[] };

// What sets the size: element types, Tailwind classes, and text. react-day-picker's own rdp-*
// classes have no styles behind them.
const shape = (element: Element): Shape => ({
  tag: element.tagName,
  classes: [...element.classList].filter((name) => !name.startsWith("rdp-")).sort(),
  text: element.childElementCount ? null : element.textContent,
  children: [...element.children].map(shape),
});

const find = (container: Element, selector: string) => {
  const element = container.querySelector(selector);
  if (!element) throw new Error(`expected ${selector}`);
  return element;
};

describe("CalendarPlaceholder", () => {
  // Four, five, and six weeks.
  it.each([new Date(2026, 1, 1), new Date(2026, 9, 1), new Date(2026, 7, 1)])(
    "matches the calendar's markup with every day disabled for %s",
    (month) => {
      const calendar = render(
        <Calendar locale={{ code: "en-US" }} mode="single" startMonth={month} endMonth={month} disabled={() => true} />,
      ).container;
      const placeholder = render(<CalendarPlaceholder month={month} />).container;

      // The nav is absolutely positioned, so it takes no space and the placeholder leaves it out.
      const calendarRoot = find(calendar, ".rdp-root");
      find(calendarRoot, ".rdp-nav").remove();
      expect(shape(find(placeholder, ":scope > div"))).toEqual(shape(calendarRoot));
    },
  );
});
