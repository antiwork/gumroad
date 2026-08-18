import * as React from "react";
import { DayPicker, getDefaultClassNames } from "react-day-picker";

import { classNames } from "$app/utils/classNames";

export function Calendar({ defaultMonth, ...props }: React.ComponentProps<typeof DayPicker>) {
  const defaultClassNames = getDefaultClassNames();
  const [month, setMonth] = React.useState(defaultMonth ?? props.startMonth ?? new Date());
  // Workaround for react-day-picker not updating the current month when `startMonth` changes (https://github.com/gpbl/react-day-picker/blob/main/src/useCalendar.ts#L111)
  React.useEffect(() => {
    setMonth(defaultMonth ?? props.startMonth ?? new Date());
  }, [defaultMonth, props.startMonth]);
  return (
    <DayPicker
      captionLayout="label"
      formatters={{
        formatWeekdayName: (date) => date.toLocaleString("en-US", { weekday: "narrow" }),
      }}
      month={month}
      onMonthChange={setMonth}
      classNames={{
        ...defaultClassNames,
        root: classNames("border rounded p-3", defaultClassNames.root),
        months: classNames("relative", defaultClassNames.months),
        nav: classNames("flex absolute top-0 inset-x-0 justify-between", defaultClassNames.nav),
        month_caption: classNames("text-center", defaultClassNames.month_caption),
        caption_label: classNames("!p-0 !border-0 font-bold", defaultClassNames.caption_label),
        month_grid: "grid",
        weekdays: classNames("grid grid-cols-[repeat(7,1fr)]", defaultClassNames.weekdays),
        weekday: classNames("py-2", defaultClassNames.weekday),
        weeks: classNames("rounded border border-current", defaultClassNames.weeks),
        week: classNames("grid grid-cols-[repeat(7,1fr)] not-last:border-b", defaultClassNames.week),
        // react-day-picker doesn't render cells at all if they fall outside `endMonth`, so can't use not-last here
        day: classNames("not-[&:nth-child(7)]:border-r", defaultClassNames.day),
        // Each day is a real <button>, and this calendar renders on the public product page, which is
        // outside `.scoped-tailwind-preflight` and so never gets Tailwind's preflight reset. Without a
        // reset, the browser paints its own default button styling: on Chrome that is the `ButtonFace`
        // system colour, which is a light grey in light mode and a mid grey (#6B6B6B) in dark mode.
        // That opaque background sits on top of the cell, so a seller on a dark storefront sees every
        // day filled grey, the selected day's accent highlight hidden underneath it, and disabled days
        // tinted by the system colour rather than simply faded. Forcing a transparent background and
        // inheriting the surrounding text colour puts the day back under our own theme's control.
        day_button: classNames(
          "py-2 w-full text-center appearance-none bg-transparent text-inherit disabled:cursor-not-allowed",
          defaultClassNames.day_button,
        ),
        // The selected background belongs on the cell rather than the button: react-day-picker puts the
        // `selected` class on the <td>, and the button stretches over it, so anything opaque on the
        // button would cover this.
        selected: classNames("bg-accent-with-text text-accent-foreground", defaultClassNames.selected),
        // Disabled days should read as "unavailable" by fading out, matching how every other disabled
        // control in the app is styled (see Button/Input/Checkbox, all opacity-30).
        disabled: classNames("opacity-30", defaultClassNames.disabled),
      }}
      components={{
        // Visible text, not icon-only: the aria-label alone doesn't help sighted keyboard users.
        Chevron: ({ className, orientation, disabled }) => (
          <div className={classNames({ "cursor-not-allowed text-muted": disabled }, className)}>
            {orientation === "left" ? "Previous" : "Next"}
          </div>
        ),
      }}
      {...props}
    />
  );
}
