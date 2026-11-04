import * as React from "react";

import { cast } from "$app/utils/cast";
import { formatDate } from "$app/utils/date";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
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

const NotificationEndpointSection = ({
  pingEndpoint,
  setPingEndpoint,
  pingSigningSecret,
  userId,
  recentDeliveries,
}: {
  pingEndpoint: string;
  setPingEndpoint: (val: string) => void;
  pingSigningSecret: string | null;
  userId: string;
  recentDeliveries: PingDelivery[];
}) => {
  const [isSendingPing, setIsSendingPing] = React.useState(false);
  const [signingSecret, setSigningSecret] = React.useState(pingSigningSecret);
  const [isUpdatingSigning, setIsUpdatingSigning] = React.useState(false);
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

  const updateSigningSecret = asyncVoid(async (action: "rotate" | "disable") => {
    setIsUpdatingSigning(true);
    try {
      const response = await request({
        url:
          action === "rotate"
            ? Routes.settings_rotate_ping_signing_secret_path()
            : Routes.settings_disable_ping_signing_path(),
        method: action === "rotate" ? "POST" : "DELETE",
        accept: "json",
      });
      const responseData = cast<{ success: true; secret?: string } | { success: false; error_message: string }>(
        await response.json(),
      );
      if (!responseData.success) throw new ResponseError(responseData.error_message);

      if (action === "rotate") {
        setSigningSecret(responseData.secret ?? null);
        showAlert(
          signingSecret
            ? "Signing secret rotated. Your endpoint has to use the new secret to verify pings."
            : "Ping signing is on. Copy this secret into your endpoint, it is only shown here.",
          "success",
        );
      } else {
        setSigningSecret(null);
        showAlert("Ping signing is off. Your endpoint will receive unsigned pings again.", "success");
      }
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsUpdatingSigning(false);
  });

  // Both writes replace the secret a receiver is verifying against, so they are confirmed first.
  const [pendingSigningChange, setPendingSigningChange] = React.useState<"rotate" | "disable" | null>(null);

  const startSigning = () => {
    if (signingSecret) setPendingSigningChange("rotate");
    else updateSigningSecret("rotate");
  };

  const confirmSigningChange = () => {
    const change = pendingSigningChange;
    setPendingSigningChange(null);
    if (change) updateSigningSecret(change);
  };

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
      <Fieldset>
        <FieldsetTitle>
          <Label htmlFor={`${uid}-signing-secret`}>Sign pings</Label>
        </FieldsetTitle>
        {signingSecret ? (
          <>
            <InputGroup>
              <Input id={`${uid}-signing-secret`} readOnly type="text" value={signingSecret} />
              <Pill asChild>
                <Button className="rounded-full! px-3! py-2!" onClick={startSigning} disabled={isUpdatingSigning}>
                  Rotate
                </Button>
              </Pill>
            </InputGroup>
            <FieldsetDescription>
              Every ping carries an X-Gumroad-Signature header: a timestamp and an HMAC-SHA256 of that timestamp and the
              request body, so your endpoint can tell a real ping from a forged or replayed one. Rotating replaces the
              secret right away. Your endpoint rejects pings until it uses the new one, and rejected pings aren't
              retried.{" "}
              <a href={`${Routes.ping_path()}#verifying-pings`} target="_blank" rel="noreferrer">
                How to verify it
              </a>
            </FieldsetDescription>
            <Button
              outline
              color="danger"
              className="self-start text-danger"
              onClick={() => setPendingSigningChange("disable")}
              disabled={isUpdatingSigning}
            >
              Turn off signing
            </Button>
          </>
        ) : (
          <>
            <FieldsetDescription>
              Sign each ping with a secret only you and your endpoint know, so a forged or replayed request cannot pass
              for a real one.{" "}
              <a href={`${Routes.ping_path()}#verifying-pings`} target="_blank" rel="noreferrer">
                How to verify it
              </a>
            </FieldsetDescription>
            <Button onClick={startSigning} disabled={isUpdatingSigning}>
              Sign my pings
            </Button>
          </>
        )}
      </Fieldset>
      <Fieldset>
        <FieldsetTitle>
          <Label>Recent ping deliveries</Label>
        </FieldsetTitle>
        <RecentDeliveries deliveries={recentDeliveries} />
      </Fieldset>
      <Modal
        open={pendingSigningChange !== null}
        onClose={() => setPendingSigningChange(null)}
        title={pendingSigningChange === "rotate" ? "Rotate the signing secret?" : "Turn off ping signing?"}
        footer={
          <>
            <Button onClick={() => setPendingSigningChange(null)}>Cancel</Button>
            <Button color={pendingSigningChange === "rotate" ? "primary" : "danger"} onClick={confirmSigningChange}>
              Confirm
            </Button>
          </>
        }
      >
        <p>
          {pendingSigningChange === "rotate"
            ? "Your endpoint will reject pings until it uses the new secret."
            : "Your endpoint will receive unsigned pings again."}
        </p>
      </Modal>
    </FormSection>
  );
};

export default NotificationEndpointSection;
