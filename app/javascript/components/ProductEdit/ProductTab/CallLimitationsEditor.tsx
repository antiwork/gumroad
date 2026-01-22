import * as React from "react";

import { Icon } from "$app/components/Icons";
import { NumberInput } from "$app/components/NumberInput";
import { CallLimitationInfo } from "$app/components/ProductEdit/state";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { Pill } from "$app/components/ui/Pill";
import { useOnChange } from "$app/components/useOnChange";
import { useOnOutsideClick } from "$app/components/useOnOutsideClick";

const UNITS = ["phút", "giờ", "ngày"] as const;
type Unit = (typeof UNITS)[number];
type MinimumNotice = { unit: Unit; value: number | null };

const MINUTES_PER_DAY = 1440;
const MINUTES_PER_HOUR = 60;

const getMinimumNotice = (minimumNoticeInMinutes: number | null): MinimumNotice => {
  if (minimumNoticeInMinutes === null) return { unit: "phút", value: null };
  else if (minimumNoticeInMinutes % MINUTES_PER_DAY === 0)
    return { unit: "ngày", value: minimumNoticeInMinutes / MINUTES_PER_DAY };
  else if (minimumNoticeInMinutes % MINUTES_PER_HOUR === 0)
    return { unit: "giờ", value: minimumNoticeInMinutes / MINUTES_PER_HOUR };
  return { unit: "phút", value: minimumNoticeInMinutes };
};

const getNoticeInMinutes = ({ unit, value }: MinimumNotice) => {
  if (value === null) return null;
  switch (unit) {
    case "ngày":
      return value * MINUTES_PER_DAY;
    case "giờ":
      return value * MINUTES_PER_HOUR;
    case "phút":
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
      <fieldset>
        <label htmlFor={`${uid}-notice-period`}>Thời gian báo trước</label>
        <NumberInput value={minimumNotice.value} onChange={(value) => setMinimumNotice({ ...minimumNotice, value })}>
          {(props) => (
            <div className="input" ref={inputRef}>
              <input id={`${uid}-notice-period`} placeholder="15" {...props} />
              <Pill asChild className="relative -mr-2 shrink-0 cursor-pointer">
                <label>
                  <span>{minimumNotice.unit}</span>
                  <TypeSafeOptionSelect
                    aria-label="Đơn vị"
                    onChange={(unit) => setMinimumNotice({ ...minimumNotice, unit })}
                    value={minimumNotice.unit}
                    options={UNITS.map((unit) => ({ id: unit, label: unit }))}
                    className="absolute inset-0 z-1 m-0! cursor-pointer opacity-0"
                  />
                  <Icon name="outline-cheveron-down" className="ml-auto" />
                </label>
              </Pill>
            </div>
          )}
        </NumberInput>
        <small>Thời gian báo trước tối thiểu khi đặt lịch cuộc gọi</small>
      </fieldset>
      <fieldset>
        <label htmlFor={`${uid}-daily-limit`}>Giới hạn hàng ngày</label>
        <NumberInput
          onChange={(maximum_calls_per_day) => updateCallLimitations({ maximum_calls_per_day })}
          value={maximum_calls_per_day}
        >
          {(props) => <input id={`${uid}-daily-limit`} placeholder="2" {...props} />}
        </NumberInput>
        <small>Số cuộc gọi tối đa mỗi ngày</small>
      </fieldset>
    </>
  );
};
