import cx from "classnames";
import * as React from "react";

import {
  CurrencyCode,
  formatPriceCentsWithoutCurrencySymbolAndComma,
  getLongCurrencySymbol,
  parseCurrencyUnitStringToCents,
} from "$app/utils/currency";

import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";

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
      <div className={cx("input", { disabled })}>
        {currencyCodeSelector ? (
          <div className="pill pill-outline select">
            {getLongCurrencySymbol(currencyCode)}
            <TypeSafeOptionSelect
              name="Currency"
              value={currencyCode}
              onChange={currencyCodeSelector.onChange}
              options={currencyCodeSelector.options.map((currencyCode) => ({
                id: currencyCode,
                label: getLongCurrencySymbol(currencyCode),
              }))}
            />
          </div>
        ) : (
          <div className="pill">{getLongCurrencySymbol(currencyCode)}</div>
        )}
        <input
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
      </div>
    );
  },
);
PriceInput.displayName = "PriceInput";
