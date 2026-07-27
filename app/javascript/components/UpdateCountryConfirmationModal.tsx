import * as React from "react";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { Input } from "$app/components/ui/Input";

type Props = {
  country: string;
  balance: string | null;
  open: boolean;
  onClose: () => void;
  onConfirm: () => void;
};

export const UpdateCountryConfirmationModal = ({ country, balance, open, onClose, onConfirm }: Props) => {
  const [confirmText, setConfirmText] = React.useState("");
  const isConfirmEnabled = !balance || confirmText.trim().toLowerCase() === "i understand";

  return (
    <div>
      <Modal
        open={open}
        onClose={onClose}
        title="Confirm country change"
        footer={
          <>
            <Button onClick={onClose}>Cancel</Button>
            <Button onClick={onConfirm} color={balance ? "danger" : "primary"} disabled={!isConfirmEnabled}>
              Confirm
            </Button>
          </>
        }
      >
        {/* Changing the country starts a fresh payout account on our payments provider, so the
            saved bank account and identity details cannot carry over. Saying this up front
            matters because the page is a single form: a seller can fill in their bank details
            and change their country in one go, and only the country change is applied. */}
        <h4 className="mb-4">
          Your payout and identity details are tied to your country, so changing it clears your bank account, name, date
          of birth and address. You will need to enter them again after the change, in a separate save.
        </h4>
        <h4>
          {balance ? (
            <>
              Due to limitations with our payments provider, switching your country to <b>{country}</b> means that you
              will have to forfeit your remaining balance of <b>{balance}</b>.<br />
              <br />
              Please confirm that you're okay forfeiting your balance by typing <b>"I understand"</b> below and clicking{" "}
              <b>Confirm</b>.
              <div className="mt-4">
                <label htmlFor="confirmation-input" className="sr-only">
                  Type "I understand" to confirm
                </label>
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
            'You are about to change your country. Please click "Confirm" to continue.'
          )}
        </h4>
      </Modal>
    </div>
  );
};

export default UpdateCountryConfirmationModal;
