import { ChevronDown } from "@boxicons/react";
import {
  endOfMonth,
  endOfQuarter,
  endOfYear,
  parseISO,
  startOfDay,
  startOfMonth,
  startOfQuarter,
  startOfYear,
  subDays,
  subMonths,
  subQuarters,
  subYears,
} from "date-fns";
import * as React from "react";

import { DateInput } from "$app/components/DateInput";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
import { Menu, MenuItem } from "$app/components/ui/Menu";
import { useUserAgentInfo } from "$app/components/UserAgent";

// Product event tracking started here, so nothing before this date has analytics anywhere.
// Must match PRODUCT_EVENT_TRACKING_STARTED_DATE on the backend.
const PRODUCT_EVENT_TRACKING_STARTED_DATE = new Date("2012-10-13");

export const DateRangePicker = ({
  from,
  to,
  setFrom,
  setTo,
  minDate,
  timeZone,
}: {
  from: Date;
  to: Date;
  setFrom: (from: Date) => void;
  setTo: (to: Date) => void;
  // Earliest date the caller's backend holds data for — where "All time" starts. Callers that
  // leave it out fall back to the date tracking itself began.
  minDate?: Date;
  // The backend's own time zone, as an IANA identifier. "All time" ends on today there, since the
  // browser's date can be a day off when the two zones disagree.
  timeZone?: string;
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
  // Both ends follow the backend when the caller supplies them, so "All time" spans exactly what
  // it will return. Derived here next to `today` rather than passed in, so it stays right on a
  // dashboard left open past midnight. en-CA formats as YYYY-MM-DD. An account cannot be created
  // after its own today, so this cannot invert.
  const allTimeStart = minDate ?? PRODUCT_EVENT_TRACKING_STARTED_DATE;
  const allTimeEnd = timeZone
    ? startOfDay(parseISO(new Intl.DateTimeFormat("en-CA", { timeZone }).format(today)))
    : today;
  const presets = [
    { label: "Today", from: today, to: today },
    { label: "Last 7 days", from: subDays(today, 7), to: today },
    { label: "Last 30 days", from: subDays(today, 30), to: today },
    { label: "This month", from: startOfMonth(today), to: today },
    {
      label: "Last month",
      from: startOfMonth(subMonths(today, 1)),
      to: endOfMonth(subMonths(today, 1)),
    },
    {
      label: "Last 3 months",
      from: startOfMonth(subMonths(today, 3)),
      to: endOfMonth(subMonths(today, 1)),
    },
    { label: "This quarter", from: startOfQuarter(today), to: today },
    {
      label: "Last quarter",
      from: startOfQuarter(subQuarters(today, 1)),
      to: endOfQuarter(subQuarters(today, 1)),
    },
    { label: "This year", from: startOfYear(today), to: today },
    {
      label: "Last year",
      from: startOfYear(subYears(today, 1)),
      to: endOfYear(subYears(today, 1)),
    },
    { label: "All time", from: allTimeStart, to: allTimeEnd },
  ];
  return (
    <Popover
      open={open}
      onOpenChange={(open) => {
        if (!open && document.activeElement instanceof HTMLElement) {
          document.activeElement.blur();
        }
        setIsCustom(false);
        setOpen(open);
      }}
    >
      <PopoverAnchor>
        <PopoverTrigger>
          <InputGroup aria-label="Date range selector" className="whitespace-nowrap">
            <span suppressHydrationWarning>{Intl.DateTimeFormat(locale).formatRange(from, to)}</span>
            <ChevronDown className="ml-auto size-5" />
          </InputGroup>
        </PopoverTrigger>
      </PopoverAnchor>
      <PopoverContent matchTriggerWidth className={isCustom ? "" : "border-0 p-0 shadow-none"}>
        {isCustom ? (
          <div className="flex flex-col gap-4">
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-from`}>From (including)</Label>
              </FieldsetTitle>
              <DateInput
                id={`${uid}-from`}
                value={from}
                onChange={(date) => {
                  if (date) setFrom(date);
                }}
              />
            </Fieldset>
            <Fieldset state={to < from ? "danger" : undefined}>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-to`}>To (including)</Label>
              </FieldsetTitle>
              <DateInput
                id={`${uid}-to`}
                value={to}
                onChange={(date) => {
                  if (date) setTo(date);
                }}
                aria-invalid={to < from}
              />
              {to < from ? <FieldsetDescription>Must be after from date</FieldsetDescription> : null}
            </Fieldset>
          </div>
        ) : (
          <Menu>
            {presets.map((preset) => (
              <MenuItem key={preset.label} onClick={() => quickSet(preset.from, preset.to)}>
                {preset.label}
              </MenuItem>
            ))}
            <MenuItem onClick={() => setIsCustom(true)}>Custom range...</MenuItem>
          </Menu>
        )}
      </PopoverContent>
    </Popover>
  );
};
