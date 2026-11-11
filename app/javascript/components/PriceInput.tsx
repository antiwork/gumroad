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

const GROUP_DIGITS = 3;
const FRACTION_DIGITS = 2;

// Unsettled while another key can still change what the trailing separator means ("7,90" may
// become the group "7,900"); only settled values are written back in canonical form.
const UNSETTLED_VALUE = new RegExp(`\\.\\d?$|,\\d{0,${FRACTION_DIGITS}}$`, "u");

// A comma followed by exactly GROUP_DIGITS digits groups thousands ("7,900"); any other trailing
// separator is the decimal point. Count digits only, since the parser drops the rest ("7,900 ").
const normalizeAmountInput = (value: string): string => {
  const decimalIndex = value.indexOf(".");
  if (decimalIndex !== -1) {
    const fraction = value.slice(decimalIndex + 1).replace(/[.,]/gu, "");
    return value.slice(0, decimalIndex + 1) + fraction.slice(0, FRACTION_DIGITS);
  }

  const commaIndex = value.lastIndexOf(",");
  if (commaIndex === -1) return value;

  const fraction = value.slice(commaIndex + 1);
  return fraction.replace(/\D/gu, "").length === GROUP_DIGITS
    ? value
    : value.slice(0, commaIndex + 1) + fraction.slice(0, FRACTION_DIGITS);
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
    ariaDescribedBy?: string | undefined;
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
      ariaDescribedBy,
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
    // Rewriting the value mid-composition ends the IME session without a compositionend, and the
    // commit then lands after the rewritten text ("79007,900"). Settle once composition ends.
    const composingRef = React.useRef(false);
    const handleChange = (newValue: string) => {
      newValue = normalizeAmountInput(newValue);
      let cents = parseCurrencyUnitStringToCents(currencyCode, newValue);
      const clamped = cents != null && (isNaN(cents) || cents < 0);
      if (clamped) cents = 0;
      // A clamped value is written back even while unsettled: when the parent already holds 0,
      // the resync from `cents` never fires to replace it.
      if (cents != null && (clamped || !UNSETTLED_VALUE.test(newValue))) {
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
          onChange={(evt) => (composingRef.current ? setValue(evt.target.value) : handleChange(evt.target.value))}
          onCompositionStart={() => {
            composingRef.current = true;
          }}
          onCompositionEnd={(evt) => {
            composingRef.current = false;
            handleChange(evt.currentTarget.value);
          }}
          maxLength={10}
          placeholder={placeholder}
          autoComplete="off"
          aria-invalid={hasError}
          aria-label={ariaLabel}
          aria-describedby={ariaDescribedBy}
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
