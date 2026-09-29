import * as React from "react";
import typia from "typia";

import { formatDate } from "$app/utils/date";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
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
            <div>
              <h4>{delivery.sale_id ? `Sale #${delivery.sale_id}` : delivery.resource_name}</h4>
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
  userId,
  recentDeliveries,
}: {
  pingEndpoint: string;
  setPingEndpoint: (val: string) => void;
  userId: string;
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
      const responseData = typia.assert<{ success: true; message: string } | { success: false; error_message: string }>(
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
