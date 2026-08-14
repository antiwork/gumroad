import { ChevronDown } from "@boxicons/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";
import {
  CurrencyCode,
  formatPriceCentsWithoutCurrencySymbolAndComma,
  getLongCurrencySymbol,
  parseCurrencyUnitStringToCents,
} from "$app/utils/currency";

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
                label: getLongCurrencySymbol(currencyCode),
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
          // The product editor's autosave holds off while a price field has
          // focus: an empty or half-typed price parses to a real amount, and
          // persisting it would change what buyers pay mid-edit.
          data-price-input=""
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
