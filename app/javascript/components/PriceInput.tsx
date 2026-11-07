import { ChevronDown } from "@boxicons/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";
import {
  CurrencyCode,
  findCurrencyByCode,
  formatPriceCentsWithoutCurrencySymbolAndComma,
  getLongCurrencySymbol,
  parseCurrencyUnitStringToCents,
} from "$app/utils/currency";

import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Pill } from "$app/components/ui/Pill";

// A comma with exactly three digits after it groups thousands ("7,900"), which is how
// `parseCurrencyUnitStringToCents` reads it; collapsing every separator to "." first turned that into
// "7.90" and failed the minimum-price check. The fraction of the decimal point stays capped at two.
const normalizeAmountInput = (value: string): string => {
  const decimalIndex = value.indexOf(".");
  if (decimalIndex !== -1) {
    const fraction = value.slice(decimalIndex + 1).replace(/[.,]/gu, "");
    return value.slice(0, decimalIndex + 1) + fraction.slice(0, 2);
  }

  const commaIndex = value.lastIndexOf(",");
  if (commaIndex === -1) return value;

  const fraction = value.slice(commaIndex + 1);
  return fraction.length === 3 ? value : value.slice(0, commaIndex + 1) + fraction.slice(0, 2);
};

export const PriceInput = React.forwardRef<
  HTMLInputElement,
  {
    currencyCode: CurrencyCode;
    currencyCodeSelector?: { options: CurrencyCode[]; onChange: (currencyCode: CurrencyCode) => void } | undefined;
    cents: number | null;
    onChange?: (cents: number | null) => void;
    id?: string;
    name?: string;
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
      name,
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
      newValue = normalizeAmountInput(newValue);
      let cents = parseCurrencyUnitStringToCents(currencyCode, newValue);
      // A value ending in a separator, or in a group that can still grow a digit ("7,90" is about to
      // become "7,900"), is not settled: rewriting it there turns the grouping into a fraction.
      if (cents != null && !/[.,]\d{0,2}$/u.test(newValue)) {
        if (isNaN(cents) || cents < 0) cents = 0;
        newValue = formatPriceCentsWithoutCurrencySymbolAndComma(currencyCode, cents);
      }
      setValue(newValue);
      onChange?.(cents);
    };

    return (
      <InputGroup disabled={disabled}>
        {currencyCodeSelector ? (
          <Pill className={classNames("relative -ml-2 shrink-0", disabled ? "cursor-not-allowed" : "cursor-pointer")}>
            {getLongCurrencySymbol(currencyCode)}
            <TypeSafeOptionSelect
              name="Currency"
              // The select is invisible, so without an accessible name the accessibility tree
              // exposed this combobox with an empty name. `name` alone is a form-submission
              // attribute, not an accessible name.
              aria-label="Currency"
              value={currencyCode}
              onChange={currencyCodeSelector.onChange}
              options={currencyCodeSelector.options.map((currencyCode) => ({
                id: currencyCode,
                // The bare symbol is ambiguous in the menu — SEK, NOK and DKK all render as "kr".
                // Every other currency menu in the app labels with `displayFormat`; match it.
                label: findCurrencyByCode(currencyCode).displayFormat,
              }))}
              // The select is invisible and stretched over the pill so the whole pill acts as the
              // hit area. CSS opacity does not block pointer events, so it needs the real
              // `disabled` attribute to stop the currency being changed on a disabled field.
              disabled={disabled ?? false}
              className={classNames(
                "absolute inset-0 z-1 m-0! opacity-0",
                disabled ? "cursor-not-allowed" : "cursor-pointer",
              )}
            />
            <ChevronDown className="ml-auto size-5" />
          </Pill>
        ) : (
          <Pill className="-ml-2 shrink-0">{getLongCurrencySymbol(currencyCode)}</Pill>
        )}
        <Input
          type="text"
          inputMode="decimal"
          id={id}
          name={name}
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
