import * as React from "react";

import { CurrencyCode, formatPriceCentsWithoutCurrencySymbol } from "$app/utils/currency";

import { Details } from "$app/components/Details";
import { PriceInput } from "$app/components/PriceInput";
import { InstallmentPlanEditor } from "$app/components/ProductEdit/ProductTab/InstallmentPlanEditor";
import { Toggle } from "$app/components/Toggle";

export const PriceEditor = ({
  priceCents,
  suggestedPriceCents,
  isPWYW,
  setPriceCents,
  setSuggestedPriceCents,
  setIsPWYW,
  currencyType,
  eligibleForInstallmentPlans,
  allowInstallmentPlan,
  numberOfInstallments,
  onAllowInstallmentPlanChange,
  onNumberOfInstallmentsChange,
}: {
  priceCents: number;
  suggestedPriceCents: number | null;
  isPWYW: boolean;
  setPriceCents: (priceCents: number) => void;
  setSuggestedPriceCents: (suggestedPriceCents: number | null) => void;
  setIsPWYW: (isPWYW: boolean) => void;
  currencyType: CurrencyCode;
  eligibleForInstallmentPlans: boolean;
  allowInstallmentPlan: boolean;
  numberOfInstallments: number | null;
  onAllowInstallmentPlanChange: (allowed: boolean) => void;
  onNumberOfInstallmentsChange: (numberOfInstallments: number) => void;
}) => {
  const uid = React.useId();

  return (
    <fieldset>
      <label htmlFor={`${uid}-price-cents`}>Amount</label>
      <PriceInput
        id={`${uid}-price-cents`}
        currencyCode={currencyType}
        cents={priceCents}
        onChange={(newAmount) => setPriceCents(newAmount ?? 0)}
      />
      <Details
        className="toggle"
        open={isPWYW}
        summary={
          <Toggle value={isPWYW} onChange={setIsPWYW}>
            <a data-helper-prompt="What is the pay-what-you-want feature and how does it work?">
              Allow customers to pay what they want
            </a>
          </Toggle>
        }
      >
        <div
          className="dropdown"
          style={{
            display: "grid",
            gap: "var(--spacer-4)",
            gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
          }}
        >
          <fieldset>
            <label htmlFor={`${uid}-minimum-amount`}>Minimum amount</label>
            <PriceInput id={`${uid}-minimum-amount`} currencyCode={currencyType} cents={priceCents} disabled />
          </fieldset>
          <fieldset>
            <label htmlFor={`${uid}-suggested-price-cents`}>Suggested amount</label>
            <PriceInput
              id={`${uid}-suggested-price-cents`}
              placeholder={formatPriceCentsWithoutCurrencySymbol(currencyType, priceCents)}
              currencyCode={currencyType}
              cents={suggestedPriceCents}
              onChange={setSuggestedPriceCents}
            />
          </fieldset>
        </div>
      </Details>
      {eligibleForInstallmentPlans ? (
        <InstallmentPlanEditor
          totalAmountCents={priceCents}
          isPWYW={isPWYW}
          allowInstallmentPayments={allowInstallmentPlan}
          numberOfInstallments={numberOfInstallments}
          onAllowInstallmentPaymentsChange={onAllowInstallmentPlanChange}
          onNumberOfInstallmentsChange={onNumberOfInstallmentsChange}
        />
      ) : null}
    </fieldset>
  );
};
