import { formatInTimeZone, fromZonedTime } from "date-fns-tz";
import * as React from "react";

import { cast } from "$app/utils/cast";
import { assertResponseError, request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
import { Pill } from "$app/components/ui/Pill";

export type PublishSchedule = {
  status: string;
  label: string;
  failure_message: string | null;
};

// Authorization failures answer with `error`; this controller answers with `error_message`.
type Response =
  | { success: true; publish_schedule?: PublishSchedule }
  | { success: false; error_message?: string; error?: string };

const errorMessage = (result: { error_message?: string; error?: string }) =>
  result.error_message ?? result.error ?? "Something went wrong. Please try again.";

// The abbreviation for the chosen time, so a date across a DST change shows the zone it will publish in.
const zoneAbbreviation = (localTime: string, timeZone: string) => {
  const chosen = localTime ? fromZonedTime(localTime, timeZone) : new Date();
  return formatInTimeZone(isNaN(chosen.getTime()) ? new Date() : chosen, timeZone, "z");
};

const send = async (url: string, method: "POST" | "DELETE", data?: Record<string, string>) => {
  const response = await request({ url, method, accept: "json", ...(data ? { data } : {}) });
  return cast<Response>(await response.json());
};

// The schedule lives in the editor's state, so a manual publish there clears it here too.
export const PublishScheduleCard = ({
  permalink,
  schedule,
  onChange,
  canCreate,
  isPublished,
}: {
  permalink: string;
  schedule: PublishSchedule | null;
  onChange: (schedule: PublishSchedule | null) => void;
  canCreate: boolean;
  isPublished: boolean;
}) => {
  const seller = useCurrentSeller();
  const [localTime, setLocalTime] = React.useState("");
  const [busy, setBusy] = React.useState(false);
  const pending = schedule && (schedule.status === "scheduled" || schedule.status === "publishing") ? schedule : null;
  const failure = schedule?.status === "failed" && schedule.failure_message ? schedule : null;

  if (isPublished || (!pending && !failure && !canCreate)) return null;

  const run = async (action: () => Promise<void>) => {
    setBusy(true);
    try {
      await action();
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setBusy(false);
    }
  };

  const save = () =>
    run(async () => {
      const result = await send(Routes.link_publish_schedule_path(permalink), "POST", { local_time: localTime });
      if (!result.success) return showAlert(errorMessage(result), "error");
      onChange(result.publish_schedule ?? null);
      showAlert("Publish scheduled.", "success");
    });

  // Cancelling a pending schedule and dismissing a failure both delete the schedule.
  const remove = (notice?: string) =>
    run(async () => {
      const result = await send(Routes.link_publish_schedule_path(permalink), "DELETE");
      if (!result.success) return showAlert(errorMessage(result), "error");
      onChange(null);
      setLocalTime("");
      if (notice) showAlert(notice, "success");
    });

  return (
    <div className="flex flex-col gap-4 p-4 pb-0 md:p-8 md:pb-0">
      {failure ? (
        <Alert variant="danger">
          <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
            <span>Scheduled publish failed: {failure.failure_message}</span>
            <Button disabled={busy} onClick={() => void remove()}>
              Dismiss
            </Button>
          </div>
        </Alert>
      ) : null}
      {pending ? (
        <Alert role="status" variant="info">
          <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
            <span>Scheduled to publish on {pending.label}.</span>
            <Button
              disabled={busy || pending.status === "publishing"}
              onClick={() => void remove("Schedule cancelled.")}
            >
              Cancel schedule
            </Button>
          </div>
        </Alert>
      ) : null}
      {canCreate && !pending ? (
        <div className="flex flex-wrap items-center gap-2">
          <Label htmlFor="publish-schedule-time">Publish at</Label>
          <InputGroup>
            <Input
              id="publish-schedule-time"
              type="datetime-local"
              value={localTime}
              onChange={(e) => setLocalTime(e.target.value)}
            />
            {seller ? (
              <Pill className="-mr-2 shrink-0">{zoneAbbreviation(localTime, seller.timeZone.name)}</Pill>
            ) : null}
          </InputGroup>
          <Button disabled={busy || !localTime} onClick={() => void save()}>
            Schedule publish
          </Button>
          <small>Times are in your account time zone. Publishing starts within 5 minutes of the chosen time.</small>
        </div>
      ) : null}
    </div>
  );
};
