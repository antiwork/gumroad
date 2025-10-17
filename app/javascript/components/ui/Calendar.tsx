import * as React from "react";
import { DayPicker, getDefaultClassNames } from "react-day-picker";

import { classNames } from "$app/utils/classNames";

const forceUnicodeRenderAsText = (unicode: string) => `${unicode}\u{FE0E}`;

export function Calendar({ className, defaultMonth, ...props }: React.ComponentProps<typeof DayPicker>) {
  const defaultClassNames = getDefaultClassNames();
  const [month, setMonth] = React.useState(defaultMonth ?? props.startMonth ?? new Date());
  React.useEffect(() => {
    setMonth(defaultMonth ?? props.startMonth ?? new Date());
  }, [defaultMonth, props.startMonth]);
  return (
    <DayPicker
      className={classNames("p-3 **:[thead]:block!", className)}
      captionLayout="label"
      formatters={{
        formatWeekdayName: (date) => date.toLocaleString("en-US", { weekday: "narrow" }),
      }}
      month={month}
      onMonthChange={setMonth}
      classNames={{
        ...defaultClassNames,
        root: classNames("border rounded", defaultClassNames.root),
        months: classNames("flex gap-4 flex-col relative", defaultClassNames.months),
        month: classNames("flex flex-col w-full", defaultClassNames.month),
        nav: classNames(
          "flex items-center gap-1 w-full absolute top-0 inset-x-0 justify-between",
          defaultClassNames.nav,
        ),
        month_caption: classNames("flex items-center justify-center w-full", defaultClassNames.month_caption),
        caption_label: classNames("!p-0 !border-0 font-bold", defaultClassNames.caption_label),
        month_grid: "w-full !border-0 !grid !gap-0",
        weeks: classNames("rounded !border !border-current !grid grid-cols-[repeat(7,1fr)]", defaultClassNames.weeks),
        weekdays: classNames("!grid grid-cols-[repeat(7,1fr)]", defaultClassNames.weekdays),
        weekday: classNames("font-bold border-none !py-2 !px-0 text-center", defaultClassNames.weekday),
        week: classNames(
          "!grid col-[1/-1] !border-0 not-last:border-b! !rounded-none grid-cols-subgrid w-full !bg-transparent",
          defaultClassNames.week,
        ),
        day: classNames(
          "not-[&:nth-child(7)]:border-r! !border-t-0 !rounded-none relative w-full h-full p-0 text-center",
          defaultClassNames.day,
        ),
        day_button: classNames("py-2 w-full", defaultClassNames.day_button),
        selected: classNames("bg-accent text-contrast-accent", defaultClassNames.selected),
      }}
      components={{
        Chevron: ({ className, orientation, disabled }) => (
          <div className={classNames({ "text-muted cursor-not-allowed": disabled }, className)}>
            {forceUnicodeRenderAsText(orientation === "left" ? "◀" : "▶")}
          </div>
        ),
      }}
      {...props}
    />
  );
}
