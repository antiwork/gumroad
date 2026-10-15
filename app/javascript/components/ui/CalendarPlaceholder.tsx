import { eachDayOfInterval, endOfMonth, format, interval, isSameMonth, startOfMonth, startOfWeek } from "date-fns";
import * as React from "react";

const DAYS_PER_WEEK = 7;

// `Calendar`'s markup for one month while its dates load (every day disabled, `endMonth` = `month`),
// so swapping in the lazy calendar moves nothing. Days are real buttons: their default font sets the
// row height. CalendarPlaceholder.test.tsx fails when the two drift apart.
export const CalendarPlaceholder = ({ month }: { month: Date }) => {
  // Like react-day-picker, render no cells after `endMonth`.
  const days = eachDayOfInterval(interval(startOfWeek(startOfMonth(month)), endOfMonth(month)));
  const weeks = Array.from({ length: Math.ceil(days.length / DAYS_PER_WEEK) }, (_, week) =>
    days.slice(week * DAYS_PER_WEEK, (week + 1) * DAYS_PER_WEEK),
  );

  return (
    <div className="rounded border p-3" aria-hidden="true">
      <div className="relative">
        <div>
          <div className="text-center">
            <span className="!border-0 !p-0 font-bold">{format(month, "LLLL yyyy")}</span>
          </div>
          <table className="grid">
            <thead>
              <tr className="grid grid-cols-[repeat(7,1fr)]">
                {weeks[0]?.map((day) => (
                  <th key={day.getDay()} className="py-2">
                    {day.toLocaleString("en-US", { weekday: "narrow" })}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="rounded border border-current">
              {weeks.map((week, index) => (
                <tr key={index} className="grid grid-cols-[repeat(7,1fr)] not-last:border-b">
                  {week.map((day) => (
                    <td key={day.getDay()} className="opacity-30 not-[&:nth-child(7)]:border-r">
                      {isSameMonth(day, month) ? (
                        <button
                          type="button"
                          disabled
                          className="w-full appearance-none bg-transparent py-2 text-center text-inherit disabled:cursor-not-allowed"
                        >
                          {format(day, "d")}
                        </button>
                      ) : null}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
};
