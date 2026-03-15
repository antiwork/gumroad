import * as React from "react";

import { CurrencyCode, formatPriceCentsWithoutCurrencySymbol } from "$app/utils/currency";

import { Dropdown } from "$app/components/Dropdown";
import { PriceInput } from "$app/components/PriceInput";
import { DefaultDiscountCodeSelector } from "$app/components/ProductEdit/ProductTab/DefaultDiscountCodeSelector";
import { InstallmentPlanEditor } from "$app/components/ProductEdit/ProductTab/InstallmentPlanEditor";
import { ProductEditContext } from "$app/components/ProductEdit/state";
import { Alert } from "$app/components/ui/Alert";
import { Details, DetailsToggle } from "$app/components/ui/Details";
import { Fieldset } from "$app/components/ui/Fieldset";
import { Label } from "$app/components/ui/Label";
import { Switch } from "$app/components/ui/Switch";

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
  const productEditContext = React.useContext(ProductEditContext);

  return (
    <Fieldset>
      <Label htmlFor={`${uid}-price-cents`}>Amount</Label>
      <PriceInput
        id={`${uid}-price-cents`}
        currencyCode={currencyType}
        cents={priceCents}
        onChange={(newAmount) => setPriceCents(newAmount ?? 0)}
        currencyCodeSelector={currencyCodeSelector}
      />
      {isFreeProduct ? <Alert variant="info">Free products require a pay what they want price.</Alert> : null}
      <Details open={isPWYW}>
        <DetailsToggle chevronPosition="none" className="mb-0">
          <Switch
            checked={isPWYW}
            onChange={(e) => setIsPWYW(e.target.checked)}
            disabled={isFreeProduct}
            label={
              <a href="/help/article/133-pay-what-you-want-pricing" target="_blank" rel="noreferrer">
                Allow customers to pay what they want
              </a>
            }
          />
        </DetailsToggle>
        <Dropdown className="gap-4 lg:grid-cols-2">
          <Fieldset>
            <Label htmlFor={`${uid}-minimum-amount`}>Minimum amount</Label>
            <PriceInput id={`${uid}-minimum-amount`} currencyCode={currencyType} cents={priceCents} disabled />
          </Fieldset>
          <Fieldset>
            <Label htmlFor={`${uid}-suggested-price-cents`}>Suggested amount</Label>
            <PriceInput
              id={`${uid}-suggested-price-cents`}
              placeholder={formatPriceCentsWithoutCurrencySymbol(currencyType, priceCents)}
              currencyCode={currencyType}
              cents={suggestedPriceCents}
              onChange={setSuggestedPriceCents}
            />
          </Fieldset>
        </Dropdown>
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
      {productEditContext ? <DefaultDiscountCodeSelector /> : null}
    </Fieldset>
  );
};
