import * as React from "react";

import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";

import { Button } from "$app/components/Button";
import { Details } from "$app/components/Details";
import { Popover } from "$app/components/Popover";
import { Select } from "$app/components/Select";
import { Toggle } from "$app/components/Toggle";
import { useUserAgentInfo } from "$app/components/UserAgent";

export type RefundPolicy = { title: string | null; fine_print: string | null };

export const RefundPolicySelector = ({
  refundPolicy,
  setRefundPolicy,
  refundPolicies,
  isEnabled,
  setIsEnabled,
  setShowPreview,
}: {
  refundPolicy: RefundPolicy;
  setRefundPolicy: (refundPolicy: RefundPolicy) => void;
  refundPolicies: OtherRefundPolicy[];
  isEnabled: boolean;
  setIsEnabled: (isEnabled: boolean) => void;
  setShowPreview: (showingPreview: boolean) => void;
}) => {
  const [isPopoverOpen, setIsPopoverOpen] = React.useState(false);
  const [selectedRefundPolicyId, setSelectedRefundPolicyId] = React.useState<string | null>(null);

  const uid = React.useId();

  return (
    <Details
      className="toggle"
      open={isEnabled}
      summary={
        <Toggle value={isEnabled} onChange={setIsEnabled}>
          Specify a refund policy for this product{" "}
          <a data-helper-prompt="How do I specify a custom refund policy for my product?">Learn more</a>
        </Toggle>
      }
    >
      <div className="dropdown paragraphs">
        <fieldset>
          <legend>
            <label htmlFor={`${uid}-refund-policy-title`}>Refund policy</label>
            {refundPolicies.length > 0 ? (
              <Popover
                trigger={<div className="link">Copy from other products</div>}
                open={isPopoverOpen}
                onToggle={setIsPopoverOpen}
              >
                <div
                  className="paragraphs"
                  style={{
                    width: "20rem",
                    maxWidth: "100%",
                    fontWeight: "initial",
                  }}
                >
                  <Select
                    options={refundPolicies.map(({ id, product_name: label }) => ({ id, label }))}
                    isMulti={false}
                    placeholder="Select a product"
                    onChange={(option) => setSelectedRefundPolicyId(option?.id ?? null)}
                  />
                  <Button
                    color="primary"
                    disabled={selectedRefundPolicyId === null}
                    onClick={() => {
                      const otherRefundPolicy = refundPolicies.find(({ id }) => id === selectedRefundPolicyId);
                      if (otherRefundPolicy) {
                        setRefundPolicy(otherRefundPolicy);
                        setIsPopoverOpen(false);
                      }
                    }}
                  >
                    Copy
                  </Button>
                </div>
              </Popover>
            ) : null}
          </legend>
          <input
            id={`${uid}-refund-policy-title`}
            maxLength={50}
            type="text"
            placeholder="30-day money back guarantee"
            value={refundPolicy.title || ""}
            onChange={(evt) => setRefundPolicy({ ...refundPolicy, title: evt.target.value })}
          />
        </fieldset>
        <fieldset>
          <legend>
            <label htmlFor={`${uid}-refund-policy-fine-print`}>Fine print (optional)</label>
          </legend>
          <textarea
            id={`${uid}-refund-policy-fine-print`}
            maxLength={3000}
            rows={10}
            value={refundPolicy.fine_print || ""}
            onChange={(evt) => setRefundPolicy({ ...refundPolicy, fine_print: evt.target.value })}
            onMouseEnter={() => setShowPreview(true)}
            onMouseLeave={() => setShowPreview(false)}
          />
        </fieldset>
      </div>
    </Details>
  );
};

export const RefundPolicyModalPreview = ({ refundPolicy, open }: { refundPolicy: RefundPolicy; open: boolean }) => {
  const userAgentInfo = useUserAgentInfo();
  const uid = React.useId();
  return (
    <dialog open={!!refundPolicy.fine_print && open} aria-labelledby={uid}>
      <header>
        <h2 id={uid}>{refundPolicy.title}</h2>
        <button className="close" aria-label="Close" />
      </header>
      <div style={{ whiteSpace: "pre-wrap" }}>{refundPolicy.fine_print}</div>
      <footer>Last updated {new Date().toLocaleString(userAgentInfo.locale, { dateStyle: "medium" })}</footer>
    </dialog>
  );
};
