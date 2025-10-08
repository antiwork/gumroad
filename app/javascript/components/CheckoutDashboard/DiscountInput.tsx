import cx from "classnames";
import * as React from "react";

import { CurrencyCode } from "$app/utils/currency";

import { NumberInput } from "$app/components/NumberInput";
import { PriceInput } from "$app/components/PriceInput";
import { WithTooltip } from "$app/components/WithTooltip";

export type InputtedDiscount = { type: "percent" | "cents"; value: null | number; error?: boolean };

export const DiscountInput = ({
  discount,
  setDiscount,
  currencyCode,
  currencyCodeSelector,
  disableFixedAmount,
  ref,
}: {
  discount: InputtedDiscount;
  setDiscount: (newDiscount: InputtedDiscount) => void;
  currencyCode: CurrencyCode;
  currencyCodeSelector?: { options: CurrencyCode[]; onChange: (currencyCode: CurrencyCode) => void } | undefined;
  disableFixedAmount?: boolean;
  ref?: React.RefObject<HTMLInputElement>;
}) => {
  const fixedAmountFieldset = (
    <fieldset className={cx({ danger: discount.type === "cents" && discount.error })}>
      <div className="grid items-center gap-4 md:grid-cols-[auto_1fr]!">
        <label>
          <input
            ref={ref}
            type="radio"
            checked={discount.type === "cents"}
            onChange={(evt) => {
              if (evt.target.checked) setDiscount({ type: "cents", value: 0 });
            }}
            disabled={disableFixedAmount}
          />
          Fixed amount
        </label>
        <PriceInput
          currencyCode={currencyCode}
          currencyCodeSelector={currencyCodeSelector}
          cents={discount.type === "cents" ? discount.value : null}
          onChange={(value) => setDiscount({ type: "cents", value })}
          placeholder="0"
          disabled={disableFixedAmount || discount.type !== "cents"}
          hasError={discount.error ?? false}
          ariaLabel="Fixed amount"
        />
      </div>
    </fieldset>
  );
  return (
    <div
      style={{
        display: "grid",
        gap: "var(--spacer-6)",
        gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
      }}
    >
      <fieldset className={cx({ danger: discount.type === "percent" && discount.error })}>
        <div className="grid items-center gap-4 md:grid-cols-[auto_1fr]!">
          <label>
            <input
              type="radio"
              checked={discount.type === "percent"}
              onChange={(evt) => {
                if (evt.target.checked) setDiscount({ type: "percent", value: 0 });
              }}
            />
            Percentage
          </label>
          <div className={cx("input", { disabled: discount.type !== "percent" })}>
            <NumberInput
              value={discount.type === "percent" ? discount.value : null}
              onChange={(value) => {
                if (value === null || (value >= 0 && value <= 100)) setDiscount({ type: "percent", value });
              }}
            >
              {(props) => (
                <input
                  type="text"
                  placeholder="0"
                  disabled={discount.type !== "percent"}
                  aria-label="Percentage"
                  aria-invalid={discount.error}
                  {...props}
                />
              )}
            </NumberInput>
            <div className="pill">%</div>
          </div>
        </div>
      </fieldset>
      {disableFixedAmount ? (
        <WithTooltip tip="To select a fixed amount, make sure the selected products are priced in the same currency.">
          {fixedAmountFieldset}
        </WithTooltip>
      ) : (
        fixedAmountFieldset
      )}
    </div>
  );
};
