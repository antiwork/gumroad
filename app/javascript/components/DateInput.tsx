import { format, parseISO } from "date-fns";
import { formatInTimeZone, fromZonedTime } from "date-fns-tz";
import * as React from "react";

import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Pill } from "$app/components/ui/Pill";

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
    if (!seller || !withTime) return format(date, dateFormat);

    // Intl parts avoid a browser-local Date that can normalize the seller's clock.
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone: seller.timeZone.name,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    }).formatToParts(date);
    const fields = Object.fromEntries(parts.map(({ type, value }) => [type, value]));
    return `${fields.year?.padStart(4, "0")}-${fields.month}-${fields.day}T${fields.hour}:${fields.minute}`;
  };
  // when using `value` below React breaks the date picker, so implementing this manually here
  const ref = React.useRef<HTMLInputElement>(null);
  React.useEffect(() => {
    if (!ref.current) return;
    ref.current.value = formatDate(value);
  }, [value]);
  const input = (
    <Input
      ref={ref}
      className="appearance-none"
      type={withTime ? "datetime-local" : "date"}
      {...rest}
      defaultValue={formatDate(value)}
      min={min ? formatDate(min) : undefined}
      max={max ? formatDate(max) : undefined}
      onBlur={(e) => {
        // Parse the seller's wall clock before a browser DST gap can normalize it.
        const parsed =
          seller && withTime ? fromZonedTime(e.target.value, seller.timeZone.name) : parseISO(e.target.value);
        if (!isNaN(parsed.getTime()) && parsed.getFullYear() >= 1000) onChange?.(parsed);
        else onChange?.(null);
      }}
    />
  );
  return withTime && seller ? (
    <InputGroup>
      {input}
      <Pill className="-mr-2 shrink-0">{formatInTimeZone(value ?? new Date(), seller.timeZone.name, "z")}</Pill>
    </InputGroup>
  ) : (
    <InputGroup>{input}</InputGroup>
  );
};
