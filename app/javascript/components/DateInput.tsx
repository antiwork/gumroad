import { format, parseISO } from "date-fns";
import { formatInTimeZone, fromZonedTime } from "date-fns-tz";
import * as React from "react";

import { useCurrentSeller } from "$app/components/CurrentSeller";

type Props = {
  value: Date | null;
  onChange?: (date: Date | null) => void;
  min?: Date | undefined;
  max?: Date | undefined;
  withTime?: true;
};

export const DateInput = ({
  value,
  onChange,
  withTime,
  min,
  max,
  ...rest
}: Props & Omit<React.HTMLProps<HTMLInputElement>, keyof Props>) => {
  const seller = useCurrentSeller();
  const formatDate = (date: Date | null) => {
    if (!date) return withTime ? "mm/dd/yyyy hh:mm" : "mm/dd/yyyy";
    const dateFormat = withTime ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd";
    return seller && withTime ? formatInTimeZone(date, seller.timeZone.name, dateFormat) : format(date, dateFormat);
  };
  // when using `value` below React breaks the date picker, so implementing this manually here
  const ref = React.useRef<HTMLInputElement>(null);
  React.useEffect(() => {
    if (!ref.current) return;
    ref.current.value = formatDate(value);
  }, [value]);
  const input = (
    <input
      ref={ref}
      className="appearance-none"
      type={withTime ? "datetime-local" : "date"}
      {...rest}
      defaultValue={formatDate(value)}
      min={min ? formatDate(min) : undefined}
      max={max ? formatDate(max) : undefined}
      onBlur={(e) => {
        let parsed = parseISO(e.target.value);
        if (seller && withTime) parsed = fromZonedTime(parsed, seller.timeZone.name);
        if (!isNaN(parsed.getTime()) && parsed.getFullYear() >= 1000) onChange?.(parsed);
        else onChange?.(null);
      }}
    />
  );
  return withTime && seller ? (
    <div className="input">
      {input}
      <div className="pill">{formatInTimeZone(value ?? new Date(), seller.timeZone.name, "z")}</div>
    </div>
  ) : (
    <div className="input">{input}</div>
  );
};
