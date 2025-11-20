import * as React from "react";

import { InputtedDiscount, DiscountInput } from "$app/components/CheckoutDashboard/DiscountInput";
import { NumberInput } from "$app/components/NumberInput";
import { useProductEditContext } from "$app/components/ProductEdit/state";
import { ToggleSettingRow } from "$app/components/SettingRow";

export const CancellationDiscountSelector = () => {
  const { product, updateProduct, currencyType } = useProductEditContext();
  const cancellationDiscount = product.cancellation_discount;

  const [isEnabled, setIsEnabled] = React.useState(!!cancellationDiscount);

  const [discount, setDiscount] = React.useState<InputtedDiscount>(
    cancellationDiscount
      ? cancellationDiscount.discount.type === "fixed"
        ? { type: "cents", value: cancellationDiscount.discount.cents }
        : { type: "percent", value: cancellationDiscount.discount.percents }
      : { type: "cents", value: null },
  );
  const [durationInBillingCycles, setDurationInBillingCycles] = React.useState<number | null>(
    cancellationDiscount?.duration_in_billing_cycles ?? null,
  );

  React.useEffect(() => {
    if (!isEnabled) {
      updateProduct({ cancellation_discount: null });
      return;
    }

    if (discount.error || discount.value === null) {
      return;
    }

    updateProduct({
      cancellation_discount: {
        discount:
          discount.type === "cents"
            ? { type: "fixed", cents: discount.value }
            : { type: "percent", percents: discount.value },
        duration_in_billing_cycles: durationInBillingCycles,
      },
    });
  }, [isEnabled, discount, durationInBillingCycles, updateProduct]);

  return (
    <ToggleSettingRow
      value={isEnabled}
      onChange={setIsEnabled}
      label="Offer a cancellation discount"
      dropdown={
        <section className="flex flex-col gap-4">
          <DiscountInput discount={discount} setDiscount={setDiscount} currencyCode={currencyType} />
          <fieldset>
            <label htmlFor="billing-cycles">Duration in billing cycles</label>
            <NumberInput value={durationInBillingCycles} onChange={setDurationInBillingCycles}>
              {(props) => <input id="billing-cycles" type="text" autoComplete="off" placeholder="∞" {...props} />}
            </NumberInput>
          </fieldset>
        </section>
      }
    />
  );
};
