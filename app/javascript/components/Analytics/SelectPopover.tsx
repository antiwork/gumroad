import * as React from "react";

import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";

interface SelectOption<T extends string> {
  value: T;
  label: string;
}

interface SelectPopoverProps<T extends string> {
  options: SelectOption<T>[];
  value: T;
  onChange: (value: T) => void;
  ariaLabel?: string;
}

export function SelectPopover<T extends string>({ options, value, onChange, ariaLabel}: SelectPopoverProps<T>) {
  const selectedOption = options.find((opt) => opt.value === value);
  const radioGroupName = React.useId();

  const handleInputChange = (close: () => void) => (event: React.ChangeEvent<HTMLInputElement>) => {
    const target = event.target as HTMLInputElement;
    const optionValue = target.value as T;
    onChange(optionValue);
    close();
  };


  return (
    <Popover
      trigger={
        <span className={`input flex items-center justify-between whitespace-nowrap min-w-[12ch]`} aria-label={ariaLabel}>
          <span>{selectedOption?.label || "Select..."}</span>
          <Icon name="outline-cheveron-down" />
        </span>
      }
    >
      {(close) => (
        <fieldset>
          {options.map((option) => (
            <label key={option.value}>
              <input
                type="radio"
                name={radioGroupName}
                value={option.value}
                checked={value === option.value}
                onChange={handleInputChange(close)}
              />
              {option.label}
            </label>
          ))}
        </fieldset>
      )}
    </Popover>
  );
}
