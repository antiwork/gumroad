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
        month_grid: "custom-table grid",
        weekdays: classNames("grid grid-cols-[repeat(7,1fr)]", defaultClassNames.weekdays),
        weekday: classNames("py-2", defaultClassNames.weekday),
        weeks: classNames("rounded border border-current", defaultClassNames.weeks),
        week: classNames("grid grid-cols-[repeat(7,1fr)] not-last:border-b", defaultClassNames.week),
        // react-day-picker doesn't render cells at all if they fall outside `endMonth`, so can't use not-last here
        day: classNames("not-[&:nth-child(7)]:border-r", defaultClassNames.day),
        day_button: classNames("py-2 w-full text-center", defaultClassNames.day_button),
        selected: classNames("bg-accent text-accent-foreground", defaultClassNames.selected),
      }}
      components={{
        Chevron: ({ className, orientation, disabled }) => (
          <div className={classNames({ "text-muted cursor-not-allowed": disabled }, className)}>
            {/* Force the chevrons to be rendered as text rather than emoji images */}
            {`${orientation === "left" ? "◀" : "▶"}\u{FE0E}`}
          </div>
        ),
      }}
      {...props}
    />
  );
}
