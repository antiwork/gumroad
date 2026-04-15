import * as React from "react";
import { cast } from "ts-safe-cast";

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
import { WithTooltip } from "$app/components/WithTooltip";

const NotificationEndpointSection = ({
  pingEndpoint,
  setPingEndpoint,
  userId,
}: {
  pingEndpoint: string;
  setPingEndpoint: (val: string) => void;
  userId: string;
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
          <Input
            placeholder="Ping endpoint"
            type="url"
            id={uid}
            value={pingEndpoint}
            onChange={(e) => setPingEndpoint(e.target.value)}
          />
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
    </FormSection>
  );
};

export default NotificationEndpointSection;
