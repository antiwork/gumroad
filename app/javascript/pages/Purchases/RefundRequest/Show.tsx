import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Card, CardContent } from "$app/components/ui/Card";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Label } from "$app/components/ui/Label";
import { Radio } from "$app/components/ui/Radio";
import { Textarea } from "$app/components/ui/Textarea";

type RefundRequest = {
  state: "requested" | "seen" | "refunded" | "declined" | "expired" | "escalated";
  email: string;
  reason_label: string;
};

type Props = {
  purchase_route_id: string;
  product_name: string;
  formatted_price: string;
  escalation_business_days: number;
  max_message_length: number;
  reasons: { value: string; label: string }[];
  refund_request: RefundRequest | null;
  ineligibility: "refunded" | "partially_refunded" | "chargedback" | "other" | null;
};

const SupportEmailLink = () => <a href="mailto:support@gumroad.com">support@gumroad.com</a>;

const RequestStatus = ({
  refundRequest,
  businessDays,
  ineligibility,
}: {
  refundRequest: RefundRequest;
  businessDays: number;
  ineligibility: Props["ineligibility"];
}) => {
  switch (refundRequest.state) {
    case "requested":
    case "seen":
      return (
        <>
          <p>
            <strong>Your refund request has been sent to the creator.</strong>
          </p>
          <p>
            The creator has {businessDays} business days to respond. If they don't, Gumroad support will step in. You'll
            hear from us at {refundRequest.email}.
          </p>
        </>
      );
    case "refunded":
      return (
        <>
          <p>
            <strong>This purchase has been refunded.</strong>
          </p>
          <p>Refunds usually appear on your statement within 5–10 business days.</p>
        </>
      );
    case "declined":
      return (
        <>
          <p>
            <strong>The creator declined this refund request.</strong>
          </p>
          <p>
            If you believe this is a mistake, reply to your receipt email or contact <SupportEmailLink />.
          </p>
        </>
      );
    case "escalated":
      return (
        <>
          <p>
            <strong>Gumroad support is reviewing your refund request.</strong>
          </p>
          <p>You'll hear from us at {refundRequest.email}.</p>
        </>
      );
    case "expired":
      return ineligibility === "chargedback" ? (
        <p>
          <strong>This refund request was closed because the purchase was disputed with your bank.</strong>
        </p>
      ) : (
        <>
          <p>
            <strong>This refund request is closed.</strong>
          </p>
          <p>
            If you still need help, contact <SupportEmailLink /> and include your receipt.
          </p>
        </>
      );
  }
};

const IneligibleMessage = ({ ineligibility }: { ineligibility: NonNullable<Props["ineligibility"]> }) => (
  <>
    <p>
      <strong>This purchase isn't eligible for a refund request.</strong>
    </p>
    {ineligibility === "refunded" ? (
      <p>It has already been refunded.</p>
    ) : ineligibility === "partially_refunded" ? (
      <p>
        It has already been partly refunded. To ask about the rest, contact <SupportEmailLink /> and include your
        receipt.
      </p>
    ) : ineligibility === "chargedback" ? (
      <p>It has already been disputed with your bank.</p>
    ) : (
      <p>
        It may be outside the creator's refund window, or a previous request was already resolved. If you still need
        help, contact <SupportEmailLink /> and include your receipt.
      </p>
    )}
  </>
);

export default function Show() {
  const props = usePage<Props>().props;
  const form = useForm({ reason: "", message: "" });
  const messageUID = React.useId();

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    form.post(Routes.purchase_refund_request_path(props.purchase_route_id));
  };

  return (
    <Card className="mx-auto my-8 w-[calc(100%-2rem)] max-w-md">
      <CardContent asChild>
        <header className="flex-col items-start gap-1">
          <h2>Request a refund</h2>
          <p className="text-muted">
            {props.product_name} — {props.formatted_price}
          </p>
        </header>
      </CardContent>
      {props.refund_request ? (
        <CardContent className="flex-col items-start">
          <RequestStatus
            refundRequest={props.refund_request}
            businessDays={props.escalation_business_days}
            ineligibility={props.ineligibility}
          />
          <p className="text-muted">Reason: {props.refund_request.reason_label}</p>
        </CardContent>
      ) : props.ineligibility ? (
        <CardContent className="flex-col items-start">
          <IneligibleMessage ineligibility={props.ineligibility} />
        </CardContent>
      ) : (
        <CardContent asChild>
          <form onSubmit={submit} className="flex-col items-stretch">
            <p>
              Tell the creator why you'd like a refund. They have {props.escalation_business_days} business days to
              respond; if they don't, Gumroad support will step in. No money moves until the creator (or Gumroad)
              approves the refund.
            </p>
            <Fieldset>
              <FieldsetTitle>Reason</FieldsetTitle>
              {props.reasons.map(({ value, label }) => (
                <Label key={value}>
                  <Radio
                    name="reason"
                    value={value}
                    required
                    checked={form.data.reason === value}
                    onChange={() => form.setData("reason", value)}
                  />
                  {label}
                </Label>
              ))}
            </Fieldset>
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor={messageUID}>Anything else the creator should know? (optional)</Label>
              </FieldsetTitle>
              <Textarea
                id={messageUID}
                rows={4}
                maxLength={props.max_message_length}
                value={form.data.message}
                onChange={(event) => form.setData("message", event.target.value)}
              />
            </Fieldset>
            <Button type="submit" color="primary" disabled={form.processing}>
              Send refund request
            </Button>
          </form>
        </CardContent>
      )}
    </Card>
  );
}

Show.publicLayout = true;
