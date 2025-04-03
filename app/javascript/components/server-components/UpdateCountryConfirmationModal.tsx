import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";

type Props = {
  country: string;
  balance: string | null;
  open: boolean;
  onClose: () => void;
  onConfirm: () => void;
};

export const UpdateCountryConfirmationModal = ({ country, balance, open, onClose, onConfirm }: Props) => (
  <div>
    <Modal
      open={open}
      onClose={onClose}
      title="Confirm country change"
      footer={
        <>
          <Button onClick={onClose}>Cancel</Button>
          <Button onClick={onConfirm} color="primary">
            Confirm
          </Button>
        </>
      }
    >
      <h4>
        {balance ? (
          <>
            Due to limitations with our payments provider, switching your country to <b>{country}</b> means that you
            will have to forfeit your remaining balance of <b>{balance}</b>.<br />
            <br />
            Please confirm that you are okay forfeiting your balance.
          </>
        ) : (
          'You are about to change your country. Please click "Confirm" to continue.'
        )}
      </h4>
    </Modal>
  </div>
);

export default register({ component: UpdateCountryConfirmationModal, propParser: createCast() });
