import * as React from "react";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";

interface RestartSubscriptionModalProps {
  isOpen: boolean;
  onClose: () => void;
  onResumeSubscription: () => void;
  onStartNewSubscription: () => void;
  subscription: {
    price: unknown;
    recurrence: string;
  };
}

export const RestartSubscriptionModal = ({
  isOpen,
  onClose,
  onResumeSubscription,
  onStartNewSubscription,
}: RestartSubscriptionModalProps) => (
  <Modal open={isOpen} onClose={onClose} title="Resume your previous subscription?">
    <div className="space-y-4">
      <p className="text-base text-muted">
        You've previously subscribed to this product. Would you like to <strong>pick up where you left off</strong> or{" "}
        <strong>start fresh with a new subscription</strong>?
      </p>
    </div>

    <div className="mt-6 flex gap-3">
      <Button outline onClick={onStartNewSubscription} className="flex-1">
        No, start a new subscription
      </Button>

      <Button color="black" onClick={onResumeSubscription} className="flex-1">
        Yes, resume subscription
      </Button>
    </div>
  </Modal>
);
