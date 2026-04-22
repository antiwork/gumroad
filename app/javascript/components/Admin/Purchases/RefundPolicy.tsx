import { AlertShield } from "@boxicons/react";
import React from "react";

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
        <AlertShield pack="filled" className="size-5 text-warning" />
      </WithTooltip>
    ) : null}
  </>
);
