import * as React from "react";

import { cast } from "$app/utils/cast";
import { formatDate } from "$app/utils/date";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { showAlert } from "$app/components/server-components/Alert";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { FormSection } from "$app/components/ui/FormSection";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
import { Pill } from "$app/components/ui/Pill";
import { Row, RowActions, RowContent, Rows } from "$app/components/ui/Rows";
import { WithTooltip } from "$app/components/WithTooltip";

export type PingDelivery = {
  id: number;
  resource_name: string;
  sale_id: string | null;
  subscription_id: number | null;
  post_url: string;
  attempt: number;
  outcome: string;
  succeeded: boolean;
  created_at: string;
};

const RESOURCE_LABELS: Record<string, string> = {
  sale: "Sale",
  refund: "Refund",
  dispute: "Dispute",
  dispute_won: "Dispute won",
  cancellation: "Cancellation",
  subscription_ended: "Subscription ended",
  subscription_restarted: "Subscription restarted",
  subscription_updated: "Subscription updated",
};

const describeEvent = (delivery: PingDelivery) => {
  const label = RESOURCE_LABELS[delivery.resource_name] ?? delivery.resource_name;
  if (!delivery.sale_id) return label;
  const reference = `Sale #${delivery.sale_id}`;
  // Prefixing a sale row with its own label would read "Sale · Sale #123".
  return label === "Sale" ? reference : `${label} · ${reference}`;
};

const describeDelivery = (delivery: PingDelivery) =>
  `${delivery.succeeded ? "Delivered" : "Not delivered"} — ${delivery.outcome}${
    delivery.attempt > 1 ? ` (attempt ${delivery.attempt})` : ""
  }`;

const RecentDeliveries = ({ deliveries }: { deliveries: PingDelivery[] }) => {
  if (deliveries.length === 0) {
    return (
      <FieldsetDescription>
        No pings sent yet. Sales, refunds, disputes and subscription updates we POST to your endpoint will appear here.
      </FieldsetDescription>
    );
  }

  return (
    <Rows role="list">
      {deliveries.map((delivery) => (
        <Row key={delivery.id} role="listitem">
          <RowContent>
            <div className="flex flex-col">
              <h4>{describeEvent(delivery)}</h4>
              <span className="break-all text-muted">{delivery.post_url}</span>
              <span className={delivery.succeeded ? "text-muted" : "text-red"}>{describeDelivery(delivery)}</span>
            </div>
          </RowContent>
          <RowActions>{formatDate(new Date(delivery.created_at))}</RowActions>
        </Row>
      ))}
    </Rows>
  );
};

const GENERIC_PING_SIGNING_ERROR = "Sorry, something went wrong. Please try again.";

// The secret IS the opt-in: the server has one or it does not, so this renders one state or the
// other rather than a checkbox that would need saving with the rest of the form. Enabling and
// rotating are the same request; only the label differs.
const PingSigningSecret = ({ secret: initialSecret }: { secret: string }) => {
  const [secret, setSecret] = React.useState(initialSecret);
  const [updating, setUpdating] = React.useState(false);
  const enabled = secret.length > 0;

  const writeSecret = asyncVoid(async (method: "POST" | "DELETE") => {
    setUpdating(true);
    try {
      const response = await request({
        url: Routes.ping_signing_secret_settings_advanced_path(),
        method,
        accept: "json",
      });
      const result = cast<{ success: boolean; ping_signing_secret?: string; error_message?: string }>(
        await response.json(),
      );
      if (!response.ok || !result.success) throw new ResponseError(result.error_message ?? GENERIC_PING_SIGNING_ERROR);

      setSecret(result.ping_signing_secret ?? "");
      showAlert(
        method === "DELETE" ? "Ping signing turned off." : enabled ? "Signing secret rotated." : "Ping signing enabled.",
        "success",
      );
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setUpdating(false);
    }
  });

  return (
    <Fieldset>
      <FieldsetTitle>
        <Label>Ping signing</Label>
      </FieldsetTitle>
      {enabled ? (
        <>
          <InputGroup>
            <Input readOnly className="font-mono" value={secret} aria-label="Ping signing secret" />
            <CopyToClipboard text={secret}>
              <Pill asChild>
                <Button type="button" className="rounded-full! px-3! py-2!">
                  Copy
                </Button>
              </Pill>
            </CopyToClipboard>
          </InputGroup>
          <FieldsetDescription>
            Every ping to your endpoint now carries an X-Gumroad-Signature header that signs the timestamp and the exact
            request body. Rotate the secret if it leaks: the new one takes effect on the next delivery, and anything still
            verifying the old one starts rejecting pings.
          </FieldsetDescription>
          <div className="mt-3 flex flex-wrap gap-2">
            <Button type="button" disabled={updating} onClick={() => writeSecret("POST")}>
              Rotate secret
            </Button>
            <Button type="button" outline color="danger" disabled={updating} onClick={() => writeSecret("DELETE")}>
              Turn off signing
            </Button>
          </div>
        </>
      ) : (
        <>
          <FieldsetDescription>
            Pings are currently unsigned, so your endpoint cannot tell a genuine Ping from a replayed or forged one. Turn on
            signing to get a secret only you and Gumroad hold, and a signature header on every ping that proves the body
            came from us. Your endpoint URL, credentials included, keeps working either way.
          </FieldsetDescription>
          <div className="mt-3">
            <Button type="button" disabled={updating} onClick={() => writeSecret("POST")}>
              Enable ping signing
            </Button>
          </div>
        </>
      )}
    </Fieldset>
  );
};

const NotificationEndpointSection = ({
  pingEndpoint,
  setPingEndpoint,
  userId,
  pingSigningSecret,
  recentDeliveries,
}: {
  pingEndpoint: string;
  setPingEndpoint: (val: string) => void;
  userId: string;
  pingSigningSecret: string;
  recentDeliveries: PingDelivery[];
}) => {
  const [isSendingPing, setIsSendingPing] = React.useState(false);
  const uid = React.useId();

  const sendTestPing = asyncVoid(async () => {
    if (pingEndpoint.trim().length === 0) {
      showAlert("Please provide a URL to send a test ping to.", "error");
      return;
    }

    setIsSendingPing(true);
    try {
      const response = await request({
        url: Routes.test_pings_path(),
        method: "POST",
        accept: "json",
        data: { url: pingEndpoint.trim() },
      });
      const responseData = cast<{ success: true; message: string } | { success: false; error_message: string }>(
        await response.json(),
      );
      if (!responseData.success) throw new ResponseError(responseData.error_message);
      showAlert(responseData.message, "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsSendingPing(false);
  });

  return (
    <FormSection
      header={
        <>
          <h2>Ping</h2>
          <a href={Routes.ping_path()} target="_blank" rel="noreferrer">
            Learn more
          </a>
        </>
      }
    >
      <Fieldset>
        <FieldsetTitle>
          <Label htmlFor={uid}>Ping endpoint</Label>
        </FieldsetTitle>
        <InputGroup>
          <Input type="url" id={uid} value={pingEndpoint} onChange={(e) => setPingEndpoint(e.target.value)} />
          <WithTooltip tip={isSendingPing ? null : "Send your most recent sale's JSON, with 'test' set to 'true'"}>
            <Pill asChild>
              <Button className="rounded-full! px-3! py-2!" onClick={sendTestPing} disabled={isSendingPing}>
                {isSendingPing ? "Sending test ping..." : "Send test ping to URL"}
              </Button>
            </Pill>
          </WithTooltip>
        </InputGroup>
        <FieldsetDescription>For external services, your `seller_id` is {userId}</FieldsetDescription>
      </Fieldset>
      <PingSigningSecret secret={pingSigningSecret} />
      <Fieldset>
        <FieldsetTitle>
          <Label>Recent ping deliveries</Label>
        </FieldsetTitle>
        <RecentDeliveries deliveries={recentDeliveries} />
      </Fieldset>
    </FormSection>
  );
};

export default NotificationEndpointSection;
