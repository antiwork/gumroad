import * as React from "react";

import { CurrencyCode } from "$app/utils/currency";

import { NumberInput } from "$app/components/NumberInput";
import { PriceInput } from "$app/components/PriceInput";
import { Fieldset } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
import { Pill } from "$app/components/ui/Pill";
import { Radio } from "$app/components/ui/Radio";
import { WithTooltip } from "$app/components/WithTooltip";

export type InputtedDiscount = { type: "percent" | "cents"; value: null | number; error?: boolean };

export const DiscountInput = React.forwardRef<
  HTMLInputElement,
  {
    discount: InputtedDiscount;
    setDiscount: (newDiscount: InputtedDiscount) => void;
    currencyCode: CurrencyCode;
    currencyCodeSelector?: { options: CurrencyCode[]; onChange: (currencyCode: CurrencyCode) => void } | undefined;
    disableFixedAmount?: boolean;
    ariaDescribedBy?: string | undefined;
  }
>(({ discount, setDiscount, currencyCode, currencyCodeSelector, disableFixedAmount, ariaDescribedBy }, ref) => {
  const fixedAmountFieldset = (
    <Fieldset state={discount.type === "cents" && discount.error ? "danger" : undefined}>
      <div className="grid items-center gap-4 md:grid-cols-[auto_1fr]!">
        <Label>
          <Radio
            checked={discount.type === "cents"}
            onChange={(evt) => {
              if (evt.target.checked) setDiscount({ type: "cents", value: 0 });
            }}
            disabled={disableFixedAmount}
          />
          Fixed amount
        </Label>
        <PriceInput
          ref={discount.type === "cents" ? ref : undefined}
          currencyCode={currencyCode}
          currencyCodeSelector={currencyCodeSelector}
          cents={discount.type === "cents" ? discount.value : null}
          onChange={(value) => setDiscount({ type: "cents", value })}
          placeholder="0"
          disabled={disableFixedAmount || discount.type !== "cents"}
          hasError={discount.error ?? false}
          ariaLabel="Fixed amount"
          ariaDescribedBy={discount.type === "cents" ? ariaDescribedBy : undefined}
        />
      </div>
    </Fieldset>
  );
  return (
    <div
      style={{
        display: "grid",
        gap: "var(--spacer-6)",
        gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
      }}
    >
      <Fieldset state={discount.type === "percent" && discount.error ? "danger" : undefined}>
        <div className="grid items-center gap-4 md:grid-cols-[auto_1fr]!">
          <Label>
            <Radio
              checked={discount.type === "percent"}
              onChange={(evt) => {
                if (evt.target.checked) setDiscount({ type: "percent", value: 0 });
              }}
            />
            Percentage
          </Label>
          <InputGroup disabled={discount.type !== "percent"}>
            <NumberInput
              value={discount.type === "percent" ? discount.value : null}
              onChange={(value) => {
                if (value === null || (value >= 0 && value <= 100)) setDiscount({ type: "percent", value });
              }}
            >
              {(props) => (
                <Input
                  // The ref points at whichever amount input is live, so a caller can focus the field
                  // that is invalid.
                  ref={discount.type === "percent" ? ref : undefined}
                  type="text"
                  placeholder="0"
                  disabled={discount.type !== "percent"}
                  aria-label="Percentage"
                  aria-invalid={discount.error}
                  aria-describedby={discount.type === "percent" ? ariaDescribedBy : undefined}
                  {...props}
                />
              )}
            </NumberInput>
            <Pill className="-mr-2 shrink-0">%</Pill>
          </InputGroup>
        </div>
      </Fieldset>
      {disableFixedAmount ? (
        <WithTooltip tip="To select a fixed amount, make sure the selected products are priced in the same currency.">
          {fixedAmountFieldset}
        </WithTooltip>
      ) : (
        fixedAmountFieldset
      )}
    </div>
  );
});
DiscountInput.displayName = "DiscountInput";
