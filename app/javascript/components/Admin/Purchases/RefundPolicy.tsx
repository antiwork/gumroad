import React from "react";

import { Icon } from "$app/components/Icons";
import { WithTooltip } from "$app/components/WithTooltip";

export type RefundPolicy = {
  title: string;
  current_refund_policy: string | null;
};

export const RefundPolicyTitle = ({ refundPolicy }: { refundPolicy: RefundPolicy }) => (
  <>
    Refund policy: {refundPolicy.title}{" "}
    {refundPolicy.current_refund_policy ? (
      <WithTooltip tip={`Current refund policy: ${refundPolicy.current_refund_policy}`}>
        <Icon name="solid-shield-exclamation" className="text-warning" />
      </WithTooltip>
    ) : null}
  </>
);
