import * as React from "react";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";

type Props = {
  balance: string | null;
  bankAccountNumber: string | null;
  // The seller's country cannot re-create a bank rail once the switch deletes it (India).
  losesBankRail?: boolean;
  open: boolean;
  onClose: () => void;
  onConfirm: () => void;
};

export const ConfirmBalanceForfeitOnPayoutMethodChangeModal = ({
  balance,
  bankAccountNumber,
  losesBankRail = false,
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
          {bankAccountNumber ? (
            <>
              Your bank account <b>{bankAccountNumber}</b> will be removed.
              <br />
              <br />
            </>
          ) : null}
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
              {losesBankRail ? (
                <>
                  Bank account payouts are no longer available for new setups in your country. If you switch to PayPal,{" "}
                  <b>you will not be able to switch back</b>.
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
