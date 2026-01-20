import * as React from "react";

import { CurrencyCode, formatPriceCentsWithoutCurrencySymbol } from "$app/utils/currency";

import { Details } from "$app/components/Details";
import { PriceInput } from "$app/components/PriceInput";
import { InstallmentPlanEditor } from "$app/components/ProductEdit/ProductTab/InstallmentPlanEditor";
import { Toggle } from "$app/components/Toggle";
import { Alert } from "$app/components/ui/Alert";

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
  currencyCodeSelector,
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
  currencyCodeSelector?: { options: CurrencyCode[]; onChange: (currencyCode: CurrencyCode) => void };
}) => {
  const uid = React.useId();
  const isFreeProduct = priceCents === 0;

  return (
    <fieldset>
      <label htmlFor={`${uid}-price-cents`}>Amount</label>
      <PriceInput
        id={`${uid}-price-cents`}
        currencyCode={currencyType}
        cents={priceCents}
        onChange={(newAmount) => setPriceCents(newAmount ?? 0)}
        currencyCodeSelector={currencyCodeSelector}
      />
      {isFreeProduct ? <Alert variant="info">Free products require a pay what they want price.</Alert> : null}
      <Details
        className="toggle"
        open={isPWYW}
        summary={
          <Toggle value={isPWYW} onChange={setIsPWYW} disabled={isFreeProduct}>
            <a href="/help/article/133-pay-what-you-want-pricing" target="_blank" rel="noreferrer">
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
