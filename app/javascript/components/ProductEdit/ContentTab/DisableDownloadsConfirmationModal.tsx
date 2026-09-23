import * as React from "react";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";

const formatBuyerCount = (count: number) => count.toLocaleString();

const buyerNoun = (count: number) => (count === 1 ? "existing buyer" : "existing buyers");

type Props = {
  buyerCount: number;
  open: boolean;
  onClose: () => void;
  onConfirm: () => void;
};

// Turning downloads off is retroactive: it removes the Download button for everyone who
// already bought the product, with no grandfathering (gumroad-private#2916), so the seller
// gets the number before the save goes through (gumroad-private#2918). Cancel leaves the
// switch off; nothing is written until confirm.
export const DisableDownloadsConfirmationModal = ({ buyerCount, open, onClose, onConfirm }: Props) => (
  <Modal
    open={open}
    onClose={onClose}
    title="Disable file downloads?"
    footer={
      <>
        <Button onClick={onClose}>Cancel</Button>
        <Button color="danger" onClick={onConfirm}>
          Disable downloads
        </Button>
      </>
    }
  >
    <h4>
      {formatBuyerCount(buyerCount)} {buyerNoun(buyerCount)} will lose download access to this file.
    </h4>
    <h4 className="mt-4">
      That includes the purchases they already made: while this is off, they can still open the file in the browser,
      but not download it. Turning downloads back on restores it for them.
    </h4>
  </Modal>
);

export default DisableDownloadsConfirmationModal;
