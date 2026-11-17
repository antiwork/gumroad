import * as React from "react";

import { NumberInput } from "$app/components/NumberInput";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";

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

  const noteId = React.useId();

  return (
    <>
      <ToggleSettingRow
        disabled={totalAmountCents <= 0 || isPWYW}
        describedById={isPWYW ? noteId : undefined}
        value={allowInstallmentPayments}
        onChange={onAllowInstallmentPaymentsChange}
        label="Allow customers to pay in installments"
        dropdown={
          <Fieldset>
            <NumberInput value={numberOfInstallments} onChange={(value) => onNumberOfInstallmentsChange(value || 0)}>
              {(props) => (
                <InputGroup>
                  <Input {...props} type="number" min={2} aria-label="Number of installments" />
                  <Label>equal monthly payments</Label>
                </InputGroup>
              )}
            </NumberInput>
          </Fieldset>
        }
      />
      <FieldsetDescription>
        This sets up Gumroad installment plans. It is separate from Klarna and other buy-now-pay-later options buyers
        may see at checkout, which are not affected by this setting.
      </FieldsetDescription>
      {isPWYW ? (
        <FieldsetDescription id={noteId}>
          Installments aren&apos;t available with pay what you want.
        </FieldsetDescription>
      ) : null}
    </>
  );
};
