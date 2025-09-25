import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";

type Props = {
  balance: string | null;
  open: boolean;
  onClose: () => void;
  onConfirm: () => void;
};

export const ConfirmBalanceForfeitOnPayoutMethodChangeModal = ({ balance, open, onClose, onConfirm }: Props) => {
  const [confirmText, setConfirmText] = React.useState("");
  const isConfirmEnabled = !balance || confirmText.trim().toLowerCase() === "i understand";

  return (
    <div>
      <Modal
        open={open}
        onClose={onClose}
        title="Confirm payout method change"
        footer={
          <>
            <Button onClick={onClose}>Cancel</Button>
            <Button onClick={onConfirm} color={balance ? "danger" : "primary"} disabled={!isConfirmEnabled}>
              Confirm
            </Button>
          </>
        }
      >
        <h4>
          {balance ? (
            <>
              Due to limitations with our payments provider, changing payout method from bank account to PayPal means
              that you will have to forfeit your existing balance of <b>{balance}</b>.<br />
              <br />
              Please confirm that you're okay forfeiting your balance by typing <b>"I understand"</b> below and clicking{" "}
              <b>Confirm</b>.
              <div className="mt-4">
                <label htmlFor="confirmation-input" className="sr-only">
                  Type "I understand" to confirm
                </label>
                <input
                  id="confirmation-input"
                  type="text"
                  value={confirmText}
                  onChange={(e) => setConfirmText(e.target.value)}
                  placeholder="I understand"
                  className="border-gray-300 w-full rounded border p-2"
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

export default register({ component: ConfirmBalanceForfeitOnPayoutMethodChangeModal, propParser: createCast() });
