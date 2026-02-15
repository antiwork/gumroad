import {
  endOfMonth,
  endOfYear,
  startOfMonth,
  startOfYear,
  subDays,
  subMonths,
  subYears,
  endOfQuarter,
  startOfQuarter,
  subQuarters,
} from "date-fns";
import * as React from "react";

import { DateInput } from "$app/components/DateInput";
import { Icon } from "$app/components/Icons";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
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
            <Icon name="outline-cheveron-down" className="ml-auto" />
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
            <div role="menuitem" onClick={() => quickSet(startOfQuarter(today), today)}>
              This quarter
            </div>
            <div
              role="menuitem"
              onClick={() => {
                const lastQuarter = subQuarters(today, 1);
                quickSet(startOfQuarter(lastQuarter), endOfQuarter(lastQuarter));
              }}
            >
              Last quarter
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
      </PopoverContent>
    </Popover>
  );
};
