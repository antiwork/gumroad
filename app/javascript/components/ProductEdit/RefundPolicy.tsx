import * as React from "react";

import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { assertDefined } from "$app/utils/assert";

import { Button } from "$app/components/Button";
import { Details } from "$app/components/Details";
import { Modal } from "$app/components/Modal";
import { Popover } from "$app/components/Popover";
import { Select } from "$app/components/Select";
import { Toggle } from "$app/components/Toggle";
import { useUserAgentInfo } from "$app/components/UserAgent";

export type RefundPolicy = {
  allowed_refund_periods_in_days: { key: number; value: string }[];
  max_refund_period_in_days: number;
  fine_print_enabled: boolean;
  fine_print: string | null;
  title: string;
};

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
          <a href="/help/article/335-custom-refund-policy" target="_blank" rel="noreferrer">
            Learn more
          </a>
        </Toggle>
      }
    >
      <div className="dropdown paragraphs">
        <fieldset>
          <legend>
            <label htmlFor={`${uid}-max-refund-period-in-days`}>Refund period</label>
            {refundPolicies.length > 0 ? (
              <Popover
                trigger={<div className="link">Copy from other products</div>}
                open={isPopoverOpen}
                onToggle={setIsPopoverOpen}
              >
                <div
                  className="paragraphs font-normal"
                  style={{
                    width: "20rem",
                    maxWidth: "100%",
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
                        setRefundPolicy({
                          ...refundPolicy,
                          title: otherRefundPolicy.title,
                          fine_print: otherRefundPolicy.fine_print,
                          max_refund_period_in_days: otherRefundPolicy.max_refund_period_in_days,
                        });
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
          <select
            id={`${uid}-max-refund-period-in-days`}
            value={refundPolicy.max_refund_period_in_days}
            onChange={(evt) => {
              const maxRefundPeriodInDays = Number(evt.target.value);
              const title = refundPolicy.allowed_refund_periods_in_days.find(
                ({ key }) => key === maxRefundPeriodInDays,
              )?.value;
              setRefundPolicy({
                ...refundPolicy,
                max_refund_period_in_days: maxRefundPeriodInDays,
                title: assertDefined(title),
              });
            }}
          >
            {refundPolicy.allowed_refund_periods_in_days.map(({ key, value }) => (
              <option key={key} value={key}>
                {value}
              </option>
            ))}
          </select>
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
  return (
    <Modal
      open={!!refundPolicy.fine_print && open}
      title={refundPolicy.title}
      modal={false}
      footer={`Last updated ${new Date().toLocaleString(userAgentInfo.locale, { dateStyle: "medium" })}`}
    >
      <div style={{ whiteSpace: "pre-wrap" }}>{refundPolicy.fine_print}</div>
    </Modal>
  );
};
