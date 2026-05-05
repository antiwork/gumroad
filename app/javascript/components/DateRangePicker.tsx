import { ChevronDown } from "@boxicons/react";
import {
  differenceInDays,
  endOfMonth,
  endOfQuarter,
  endOfYear,
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

export const DateRangePicker = ({
  from,
  to,
  setFrom,
  setTo,
  maxRangeDays,
}: {
  from: Date;
  to: Date;
  setFrom: (from: Date) => void;
  setTo: (to: Date) => void;
  maxRangeDays?: number;
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
  const presets = [
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
    { label: "All time", from: new Date("2012-10-13"), to: today },
  ];
  const visiblePresets =
    maxRangeDays != null ? presets.filter((p) => differenceInDays(p.to, p.from) <= maxRangeDays) : presets;
  const customRangeExceedsMax = maxRangeDays != null && differenceInDays(to, from) > maxRangeDays;
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
            <Fieldset state={to < from || customRangeExceedsMax ? "danger" : undefined}>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-to`}>To (including)</Label>
              </FieldsetTitle>
              <DateInput
                id={`${uid}-to`}
                value={to}
                onChange={(date) => {
                  if (date) setTo(date);
                }}
                aria-invalid={to < from || customRangeExceedsMax}
              />
              {to < from ? (
                <FieldsetDescription>Must be after from date</FieldsetDescription>
              ) : customRangeExceedsMax ? (
                <FieldsetDescription>Range can be at most {maxRangeDays} days</FieldsetDescription>
              ) : null}
            </Fieldset>
          </div>
        ) : (
          <Menu>
            {visiblePresets.map((preset) => (
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
