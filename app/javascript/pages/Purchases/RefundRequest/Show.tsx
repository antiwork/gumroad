import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { SUPPORT_EMAIL } from "$app/components/Support/ContactSupportModal";
import { Card, CardContent } from "$app/components/ui/Card";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Label } from "$app/components/ui/Label";
import { Radio } from "$app/components/ui/Radio";
import { Textarea } from "$app/components/ui/Textarea";

type RefundRequest = {
  status: "requested" | "escalated" | "refunded" | "disputed";
  email: string;
  reason_label: string;
};

type Ineligibility = "not_charged" | "refunded" | "partially_refunded" | "disputed" | "no_refunds" | "outside_window";

type Props = {
  purchase_route_id: string;
  product_name: string;
  seller_name: string;
  formatted_price: string;
  respond_by: string;
  max_message_length: number;
  reasons: { value: string; label: string }[];
  refund_request: RefundRequest | null;
  ineligibility: Ineligibility | null;
  refund_window_ended_on: string | null;
};

const SupportEmailLink = () => <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a>;

const STATUS_HEADINGS: Record<RefundRequest["status"], string> = {
  requested: "Refund requested",
  escalated: "Gumroad support is reviewing your request",
  refunded: "Refunded",
  disputed: "Refund request closed",
};

const RequestStatus = ({
  refundRequest,
  sellerName,
  respondBy,
}: {
  refundRequest: RefundRequest;
  sellerName: string;
  respondBy: string;
}) => {
  switch (refundRequest.status) {
    case "requested":
      return (
        <>
          <p>
            <strong>We sent your request to {sellerName}.</strong>
          </p>
          <p>
            {sellerName} decides whether to refund you. If you aren't refunded by {respondBy}, Gumroad support will
            review your request. We'll email updates to {refundRequest.email}.
          </p>
        </>
      );
    case "refunded":
      return <p>Refunds usually appear on your statement within 5–10 business days.</p>;
    case "escalated":
      return (
        <>
          <p>
            <strong>{sellerName} hasn't refunded this purchase yet.</strong>
          </p>
          <p>We'll email you at {refundRequest.email} when we have an answer.</p>
        </>
      );
    case "disputed":
      return (
        <p>
          <strong>This request was closed because you disputed the purchase with your bank.</strong>
        </p>
      );
  }
};

const IneligibleMessage = ({
  ineligibility,
  sellerName,
  refundWindowEndedOn,
}: {
  ineligibility: Ineligibility;
  sellerName: string;
  refundWindowEndedOn: string | null;
}) => {
  switch (ineligibility) {
    case "refunded":
      return <p>This purchase has already been refunded.</p>;
    case "partially_refunded":
      return (
        <p>
          This purchase has already been partly refunded. To ask about the rest, contact <SupportEmailLink /> and
          include your receipt.
        </p>
      );
    case "disputed":
      return <p>You disputed this purchase with your bank, so you can't also request a refund here.</p>;
    case "outside_window":
      return (
        <p>
          The refund window for this purchase ended on {refundWindowEndedOn}. To ask {sellerName} anyway, reply to your
          receipt email.
        </p>
      );
    case "no_refunds":
      return (
        <p>
          {sellerName} doesn't offer refunds for this product. If something is wrong with your purchase, contact{" "}
          <SupportEmailLink /> and include your receipt.
        </p>
      );
    case "not_charged":
      return <p>You haven't been charged for this purchase, so there is nothing to refund.</p>;
  }
};

export default function Show() {
  const props = usePage<Props>().props;
  const form = useForm({ reason: "", message: "" });
  const messageUID = React.useId();
  const messageCountUID = React.useId();

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    form.post(Routes.purchase_refund_request_path(props.purchase_route_id));
  };

  const heading = props.refund_request
    ? STATUS_HEADINGS[props.refund_request.status]
    : props.ineligibility
      ? "Refund not available"
      : "Request a refund";

  return (
    <Card className="mx-auto my-8 w-[calc(100%-2rem)] max-w-md">
      <CardContent asChild>
        <header className="flex-col items-start gap-1">
          <h2>{heading}</h2>
          <p className="text-muted">
            {props.product_name} — {props.formatted_price}
          </p>
        </header>
      </CardContent>
      {props.refund_request ? (
        <CardContent className="flex-col items-start">
          <RequestStatus
            refundRequest={props.refund_request}
            sellerName={props.seller_name}
            respondBy={props.respond_by}
          />
          <p className="text-muted">Reason: {props.refund_request.reason_label}</p>
        </CardContent>
      ) : props.ineligibility ? (
        <CardContent className="flex-col items-start">
          <IneligibleMessage
            ineligibility={props.ineligibility}
            sellerName={props.seller_name}
            refundWindowEndedOn={props.refund_window_ended_on}
          />
        </CardContent>
      ) : (
        <CardContent asChild>
          <form onSubmit={submit} className="flex-col items-stretch">
            <p>
              Sending this request doesn't refund you yet. {props.seller_name} decides first. If you aren't refunded by{" "}
              {props.respond_by}, Gumroad support will review your request.
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
                <Label htmlFor={messageUID}>Anything else {props.seller_name} should know? (optional)</Label>
              </FieldsetTitle>
              <Textarea
                id={messageUID}
                rows={4}
                aria-describedby={messageCountUID}
                maxLength={props.max_message_length}
                value={form.data.message}
                onChange={(event) => form.setData("message", event.target.value)}
              />
              <FieldsetDescription id={messageCountUID}>
                {form.data.message.length} of {props.max_message_length} characters used
              </FieldsetDescription>
            </Fieldset>
            <Button type="submit" color="primary" disabled={form.processing} aria-busy={form.processing}>
              {form.processing ? "Sending..." : "Send refund request"}
            </Button>
          </form>
        </CardContent>
      )}
    </Card>
  );
}

Show.publicLayout = true;
