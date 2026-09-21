import * as React from "react";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";

type Props = {
  balance: string | null;
  // The seller's country cannot re-create a bank rail once the switch deletes it (India).
  losesBankRail?: boolean;
  // The server's own masked string (BankAccount#account_number_visual); never a raw account number.
  bankAccountNumberVisual?: string | null;
  open: boolean;
  onClose: () => void;
  onConfirm: () => void;
};

export const ConfirmBalanceForfeitOnPayoutMethodChangeModal = ({
  balance,
  losesBankRail = false,
  bankAccountNumberVisual = null,
  open,
  onClose,
  onConfirm,
}: Props) => {
  const [confirmText, setConfirmText] = React.useState("");
  const requiresTypedConfirmation = Boolean(balance) || losesBankRail;
  const isConfirmEnabled = !requiresTypedConfirmation || confirmText.trim().toLowerCase() === "i understand";

  return (
    <div>
      <Modal
        open={open}
        onClose={onClose}
        title="Confirm payout method change"
        footer={
          <>
            <Button onClick={onClose}>Cancel</Button>
            <Button
              onClick={onConfirm}
              color={requiresTypedConfirmation ? "danger" : "primary"}
              disabled={!isConfirmEnabled}
            >
              Confirm
            </Button>
          </>
        }
      >
        <h4>
          {requiresTypedConfirmation ? (
            <>
              {balance ? (
                <>
                  Due to limitations with our payments provider, changing payout method from bank account to PayPal
                  means that you will have to forfeit your existing balance of <b>{balance}</b>.
                  <br />
                  <br />
                </>
              ) : null}
              {/* Every PayPal save deletes the active bank account (UpdatePayoutMethod#process_payment_address_params);
                  the rail-loss copy below already names it, so name it here only when that branch is silent. */}
              {!losesBankRail && bankAccountNumberVisual ? (
                <>
                  Your bank account <b>{bankAccountNumberVisual}</b> will also be removed from your payout settings.
                  <br />
                  <br />
                </>
              ) : null}
              {losesBankRail ? (
                <>
                  Bank account payouts are no longer available for new setups in your country. If you switch to PayPal,
                  your bank account{" "}
                  {bankAccountNumberVisual ? (
                    <>
                      <b>{bankAccountNumberVisual}</b>{" "}
                    </>
                  ) : null}
                  will be removed from your payout settings and <b>you will not be able to switch back yourself</b>.{" "}
                  <a href={Routes.help_center_root_path()} className="underline">
                    Contact support
                  </a>{" "}
                  if you need help.
                  <br />
                  <br />
                </>
              ) : null}
              Please confirm that you understand by typing <b>"I understand"</b> below and clicking <b>Confirm</b>.
              <div className="mt-4">
                <Label htmlFor="confirmation-input" className="sr-only">
                  Type "I understand" to confirm
                </Label>
                <Input
                  id="confirmation-input"
                  type="text"
                  value={confirmText}
                  onChange={(e) => setConfirmText(e.target.value)}
                  placeholder="I understand"
                  className="w-full rounded-sm border border-gray-300 p-2"
                />
              </div>
            </>
          ) : (
            'You are about to change your payout method from bank to PayPal. Please click "Confirm" to continue.'
          )}
        </h4>
      </Modal>
    </div>
  );
};

export default ConfirmBalanceForfeitOnPayoutMethodChangeModal;
