import { endOfMonth, startOfMonth, subDays, subMonths, differenceInDays } from "date-fns";
import * as React from "react";

import { useClientAlert } from "$app/components/ClientAlertProvider";
import { DateInput } from "$app/components/DateInput";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
import { useUserAgentInfo } from "$app/components/UserAgent";

export const ChurnDateRangePicker = ({
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
  const { showAlert } = useClientAlert();
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

  const validateDateRange = (fromDate: Date, toDate: Date) => {
    const daysDiff = differenceInDays(toDate, fromDate) + 1; // +1 to include both start and end dates
    if (daysDiff > 31) {
      showAlert(`Date range cannot exceed 31 days. Selected range is ${daysDiff} days.`, "error");
      return false;
    }
    return true;
  };

  const handleFromChange = (date: Date | null) => {
    if (date) {
      if (validateDateRange(date, to)) {
        setFrom(date);
      }
    }
  };

  const handleToChange = (date: Date | null) => {
    if (date) {
      if (validateDateRange(from, date)) {
        setTo(date);
      }
    }
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
          <Icon name="outline-cheveron-down" className="ml-auto" />
        </div>
      }
    >
      {isCustom ? (
        <div className="paragraphs">
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-from`}>From (including)</label>
            </legend>
            <DateInput id={`${uid}-from`} value={from} onChange={handleFromChange} />
          </fieldset>
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-to`}>To (including)</label>
            </legend>
            <DateInput id={`${uid}-to`} value={to} onChange={handleToChange} />
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
          <div role="menuitem" onClick={() => setIsCustom(true)}>
            Custom range...
          </div>
        </div>
      )}
    </Popover>
  );
};
