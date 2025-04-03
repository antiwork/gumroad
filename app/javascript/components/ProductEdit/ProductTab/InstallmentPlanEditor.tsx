import * as React from "react";

import { NumberInput } from "$app/components/NumberInput";
import { ToggleSettingRow } from "$app/components/SettingRow";

const DEFAULT_NUMBER_OF_INSTALLMENTS = 2;

export const InstallmentPlanEditor = ({
  totalAmountCents,
  isPWYW,
  allowInstallmentPayments,
  numberOfInstallments,
  onAllowInstallmentPaymentsChange,
  onNumberOfInstallmentsChange,
}: {
  totalAmountCents: number;
  isPWYW: boolean;
  allowInstallmentPayments: boolean;
  numberOfInstallments: number | null;
  onAllowInstallmentPaymentsChange: (value: boolean) => void;
  onNumberOfInstallmentsChange: (value: number) => void;
}) => {
  React.useEffect(() => {
    if ((totalAmountCents <= 0 || isPWYW) && allowInstallmentPayments) {
      onAllowInstallmentPaymentsChange(false);
    }
  }, [totalAmountCents, isPWYW]);

  React.useEffect(() => {
    if (allowInstallmentPayments && numberOfInstallments === null) {
      onNumberOfInstallmentsChange(DEFAULT_NUMBER_OF_INSTALLMENTS);
    }
  }, [allowInstallmentPayments]);

  return (
    <ToggleSettingRow
      disabled={totalAmountCents <= 0 || isPWYW}
      value={allowInstallmentPayments}
      onChange={onAllowInstallmentPaymentsChange}
      label="Allow customers to pay in installments"
      dropdown={
        <fieldset>
          <NumberInput value={numberOfInstallments} onChange={(value) => onNumberOfInstallmentsChange(value || 0)}>
            {(props) => (
              <div className="input">
                <input {...props} type="number" min={2} aria-label="Number of installments" />
                <label>
                  <span>equal monthly payments</span>
                </label>
              </div>
            )}
          </NumberInput>
        </fieldset>
      }
    />
  );
};
