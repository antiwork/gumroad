import { endOfMonth, endOfYear, startOfMonth, startOfYear, subDays, subMonths, subYears } from "date-fns";
import * as React from "react";

import { DateInput } from "$app/components/DateInput";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
import { useUserAgentInfo } from "$app/components/UserAgent";

export const DateRangePicker = ({
  from,
  to,
  setFrom,
  setTo,
}: {
  from: Date;
  to: Date;
  setFrom: (from: Date) => void;
  setTo: (to: Date) => void;
}) => {
  const today = new Date();
  const uid = React.useId();
  const [isCustom, setIsCustom] = React.useState(false);
  const [open, setOpen] = React.useState(false);
  const { locale } = useUserAgentInfo();
  const quickSet = (from: Date, to: Date) => {
    setFrom(from);
    setTo(to);
    setOpen(false);
  };
  return (
    <Popover
      open={open}
      onToggle={(open) => {
        setIsCustom(false);
        setOpen(open);
      }}
      trigger={
        <div className="input" aria-label="Date range selector">
          <span suppressHydrationWarning>{Intl.DateTimeFormat(locale).formatRange(from, to)}</span>
          <Icon name="outline-cheveron-down" style={{ marginLeft: "auto" }} />
        </div>
      }
    >
      {isCustom ? (
        <div className="paragraphs">
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-from`}>From (including)</label>
            </legend>
            <DateInput
              id={`${uid}-from`}
              value={from}
              onChange={(date) => {
                if (date) setFrom(date);
              }}
            />
          </fieldset>
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-to`}>To (including)</label>
            </legend>
            <DateInput
              id={`${uid}-to`}
              value={to}
              onChange={(date) => {
                if (date) setTo(date);
              }}
            />
          </fieldset>
        </div>
      ) : (
        <div role="menu">
          <div role="menuitem" onClick={() => quickSet(subDays(today, 30), today)}>
            Last 30 days
          </div>
          <div role="menuitem" onClick={() => quickSet(startOfMonth(today), today)}>
            This month
          </div>
          <div
            role="menuitem"
            onClick={() => {
              const lastMonth = subMonths(today, 1);
              quickSet(startOfMonth(lastMonth), endOfMonth(lastMonth));
            }}
          >
            Last month
          </div>
          <div
            role="menuitem"
            onClick={() => quickSet(startOfMonth(subMonths(today, 3)), endOfMonth(subMonths(today, 1)))}
          >
            Last 3 months
          </div>
          <div role="menuitem" onClick={() => quickSet(startOfYear(today), today)}>
            This year
          </div>
          <div
            role="menuitem"
            onClick={() => {
              const lastYear = subYears(today, 1);
              quickSet(startOfYear(lastYear), endOfYear(lastYear));
            }}
          >
            Last year
          </div>
          <div role="menuitem" onClick={() => quickSet(new Date("2012-10-13"), today)}>
            All time
          </div>
          <div role="menuitem" onClick={() => setIsCustom(true)}>
            Custom range...
          </div>
        </div>
      )}
    </Popover>
  );
};
