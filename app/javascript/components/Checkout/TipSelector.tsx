import cx from "classnames";
import * as React from "react";

import { formatPriceCentsWithoutCurrencySymbol } from "$app/utils/currency";

import { Button } from "$app/components/Button";
import { PriceInput } from "$app/components/PriceInput";

import { getErrors, getTotalPriceFromProducts, isProcessing, useState } from "./payment";

export const TipSelector = () => {
  const [state, dispatch] = useState();
  const errors = getErrors(state);
  const showPercentageOptions = getTotalPriceFromProducts(state) > 0;

  React.useEffect(() => {
    if (!showPercentageOptions && state.tip.type === "percentage")
      dispatch({ type: "set-value", tip: { type: "fixed", amount: null } });
  }, [showPercentageOptions]);

  const defaultOther = state.surcharges.type === "loaded" ? state.surcharges.result.subtotal * 0.3 : 5;

  return (
    <div className="bg-filled rounded border border-border p-4 text-foreground">
      <div className="paragraphs">
        <h4>Support with a tip</h4>
        {showPercentageOptions ? (
          <div
            role="radiogroup"
            className="radio-buttons"
            style={{ gridTemplateColumns: "repeat(auto-fit, minmax(min(5rem, 100%), 1fr))" }}
          >
            {state.tipOptions.map((tip) => (
              <Button
                key={tip}
                role="radio"
                aria-checked={state.tip.type === "percentage" && tip === state.tip.percentage}
                onClick={() => {
                  dispatch({
                    type: "set-value",
                    tip: {
                      type: "percentage",
                      percentage: tip,
                    },
                  });
                }}
                disabled={isProcessing(state)}
                style={{ justifyContent: "center" }}
              >
                {tip}%
              </Button>
            ))}
            <Button
              role="radio"
              aria-checked={state.tip.type === "fixed"}
              onClick={() => {
                dispatch({
                  type: "set-value",
                  tip: {
                    type: "fixed",
                    amount: state.tip.type === "fixed" ? state.tip.amount : defaultOther,
                  },
                });
              }}
              disabled={isProcessing(state)}
              style={{ justifyContent: "center" }}
            >
              Other
            </Button>
          </div>
        ) : null}
        {state.tip.type === "fixed" ? (
          <fieldset className={cx({ danger: errors.has("tip") })}>
            <PriceInput
              hasError={errors.has("tip")}
              ariaLabel="Tip"
              currencyCode="usd"
              cents={state.tip.amount}
              onChange={(newAmount) => {
                dispatch({ type: "set-value", tip: { type: "fixed", amount: newAmount } });
              }}
              placeholder={formatPriceCentsWithoutCurrencySymbol("usd", defaultOther)}
              disabled={isProcessing(state)}
            />
          </fieldset>
        ) : null}
      </div>
    </div>
  );
};
