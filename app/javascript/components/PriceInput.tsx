import * as React from "react";

import {
  CurrencyCode,
  formatPriceCentsWithoutCurrencySymbolAndComma,
  getLongCurrencySymbol,
  parseCurrencyUnitStringToCents,
} from "$app/utils/currency";

import { Icon } from "$app/components/Icons";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Pill } from "$app/components/ui/Pill";

export const PriceInput = React.forwardRef<
  HTMLInputElement,
  {
    currencyCode: CurrencyCode;
    currencyCodeSelector?: { options: CurrencyCode[]; onChange: (currencyCode: CurrencyCode) => void } | undefined;
    cents: number | null;
    onChange?: (cents: number | null) => void;
    id?: string;
    placeholder?: string;
    hasError?: boolean;
    ariaLabel?: string;
    onBlur?: () => void;
    disabled?: boolean;
    suffix?: React.ReactNode;
  }
>(
  (
    {
      currencyCode,
      currencyCodeSelector,
      cents,
      onChange,
      id,
      placeholder,
      hasError,
      ariaLabel,
      onBlur,
      disabled,
      suffix,
    },
    ref,
  ) => {
    const parsedValue = cents == null ? "" : formatPriceCentsWithoutCurrencySymbolAndComma(currencyCode, cents);
    const [value, setValue] = React.useState(parsedValue);
    React.useEffect(() => {
      if (parseCurrencyUnitStringToCents(currencyCode, value) !== cents) setValue(parsedValue);
    }, [parsedValue]);
    const handleChange = (newValue: string) => {
      newValue = newValue.replace(/[.,]+/gu, ".").replace(/(\.\d{1,2}).*/u, "$1");
      let cents = parseCurrencyUnitStringToCents(currencyCode, newValue);
      if (cents != null && !/[.,]\d?$/u.test(newValue)) {
        if (isNaN(cents) || cents < 0) cents = 0;
        newValue = formatPriceCentsWithoutCurrencySymbolAndComma(currencyCode, cents);
      }
      setValue(newValue);
      onChange?.(cents);
    };

    return (
      <InputGroup disabled={disabled}>
        {currencyCodeSelector ? (
          <Pill className="relative -ml-2 shrink-0 cursor-pointer">
            {getLongCurrencySymbol(currencyCode)}
            <TypeSafeOptionSelect
              name="Currency"
              value={currencyCode}
              onChange={currencyCodeSelector.onChange}
              options={currencyCodeSelector.options.map((currencyCode) => ({
                id: currencyCode,
                label: getLongCurrencySymbol(currencyCode),
              }))}
              className="absolute inset-0 z-1 m-0! cursor-pointer opacity-0"
            />
            <Icon name="outline-cheveron-down" className="ml-auto" />
          </Pill>
        ) : (
          <Pill className="-ml-2 shrink-0">{getLongCurrencySymbol(currencyCode)}</Pill>
        )}
        <Input
          type="text"
          inputMode="decimal"
          id={id}
          value={value}
          onChange={(evt) => handleChange(evt.target.value)}
          maxLength={10}
          placeholder={placeholder}
          autoComplete="off"
          aria-invalid={hasError}
          aria-label={ariaLabel}
          onBlur={onBlur}
          disabled={disabled}
          ref={ref}
        />
        {suffix}
      </InputGroup>
    );
  },
);
PriceInput.displayName = "PriceInput";
