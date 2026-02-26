import * as React from "react";

import { Icon } from "$app/components/Icons";
import { NumberInput } from "$app/components/NumberInput";
import { CallLimitationInfo } from "$app/components/ProductEdit/state";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
import { Pill } from "$app/components/ui/Pill";
import { useOnChange } from "$app/components/useOnChange";
import { useOnOutsideClick } from "$app/components/useOnOutsideClick";

const UNITS = ["minutes", "hours", "days"] as const;
type Unit = (typeof UNITS)[number];
type MinimumNotice = { unit: Unit; value: number | null };

const MINUTES_PER_DAY = 1440;
const MINUTES_PER_HOUR = 60;

const getMinimumNotice = (minimumNoticeInMinutes: number | null): MinimumNotice => {
  if (minimumNoticeInMinutes === null) return { unit: "minutes", value: null };
  else if (minimumNoticeInMinutes % MINUTES_PER_DAY === 0)
    return { unit: "days", value: minimumNoticeInMinutes / MINUTES_PER_DAY };
  else if (minimumNoticeInMinutes % MINUTES_PER_HOUR === 0)
    return { unit: "hours", value: minimumNoticeInMinutes / MINUTES_PER_HOUR };
  return { unit: "minutes", value: minimumNoticeInMinutes };
};

const getNoticeInMinutes = ({ unit, value }: MinimumNotice) => {
  if (value === null) return null;
  switch (unit) {
    case "days":
      return value * MINUTES_PER_DAY;
    case "hours":
      return value * MINUTES_PER_HOUR;
    case "minutes":
      return value;
  }
};

export const CallLimitationsEditor = ({
  callLimitations,
  onChange,
}: {
  callLimitations: CallLimitationInfo;
  onChange: (callLimitations: CallLimitationInfo) => void;
}) => {
  const uid = React.useId();
  const updateCallLimitations = (update: Partial<CallLimitationInfo>) => onChange({ ...callLimitations, ...update });

  const { minimum_notice_in_minutes, maximum_calls_per_day } = callLimitations;

  const [minimumNotice, setMinimumNotice] = React.useState(getMinimumNotice(minimum_notice_in_minutes));
  useOnChange(() => setMinimumNotice(getMinimumNotice(minimum_notice_in_minutes)), [minimum_notice_in_minutes]);
  const inputRef = React.useRef<HTMLDivElement>(null);
  useOnOutsideClick([inputRef], () =>
    updateCallLimitations({ minimum_notice_in_minutes: getNoticeInMinutes(minimumNotice) }),
  );

  return (
    <>
      <Fieldset>
        <Label htmlFor={`${uid}-notice-period`}>Notice period</Label>
        <NumberInput value={minimumNotice.value} onChange={(value) => setMinimumNotice({ ...minimumNotice, value })}>
          {(props) => (
            <InputGroup ref={inputRef}>
              <Input id={`${uid}-notice-period`} placeholder="15" {...props} />
              <Pill asChild className="relative -mr-2 shrink-0 cursor-pointer">
                <Label>
                  <span>{minimumNotice.unit}</span>
                  <TypeSafeOptionSelect
                    aria-label="Units"
                    onChange={(unit) => setMinimumNotice({ ...minimumNotice, unit })}
                    value={minimumNotice.unit}
                    options={UNITS.map((unit) => ({ id: unit, label: unit }))}
                    className="absolute inset-0 z-1 m-0! cursor-pointer opacity-0"
                  />
                  <Icon name="outline-cheveron-down" className="ml-auto" />
                </Label>
              </Pill>
            </InputGroup>
          )}
        </NumberInput>
        <FieldsetDescription>Minimum notice time required when booking a call</FieldsetDescription>
      </Fieldset>
      <Fieldset>
        <Label htmlFor={`${uid}-daily-limit`}>Daily limit</Label>
        <NumberInput
          onChange={(maximum_calls_per_day) => updateCallLimitations({ maximum_calls_per_day })}
          value={maximum_calls_per_day}
        >
          {(props) => <Input id={`${uid}-daily-limit`} placeholder="2" {...props} />}
        </NumberInput>
        <FieldsetDescription>Maximum calls allowed per day</FieldsetDescription>
      </Fieldset>
    </>
  );
};
