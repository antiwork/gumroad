import * as React from "react";

import { cast } from "$app/utils/cast";
import { assertResponseError, request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Input } from "$app/components/ui/Input";

export type PublishSchedule = {
  status: string;
  publish_at: string;
  local_time: string;
  time_zone: string;
  label: string;
  failure_message: string | null;
};

type Response = { success: true; publish_schedule?: PublishSchedule } | { success: false; error_message: string };

const send = async (url: string, method: "POST" | "DELETE", data?: Record<string, string>) => {
  const response = await request({ url, method, accept: "json", ...(data ? { data } : {}) });
  return cast<Response>(await response.json());
};

export const PublishScheduleCard = ({
  permalink,
  schedule: initialSchedule,
  canCreate,
}: {
  permalink: string;
  schedule: PublishSchedule | null;
  canCreate: boolean;
}) => {
  const [schedule, setSchedule] = React.useState(initialSchedule);
  const [localTime, setLocalTime] = React.useState(initialSchedule?.local_time ?? "");
  const [busy, setBusy] = React.useState(false);
  const pending = schedule && (schedule.status === "scheduled" || schedule.status === "publishing") ? schedule : null;
  const failure = schedule?.status === "failed" && schedule.failure_message ? schedule : null;

  if (!pending && !failure && !canCreate) return null;

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
      if (!result.success) return showAlert(result.error_message, "error");
      setSchedule(result.publish_schedule ?? null);
      showAlert("Publish scheduled.", "success");
    });

  const cancel = () =>
    run(async () => {
      const result = await send(Routes.link_publish_schedule_path(permalink), "DELETE");
      if (!result.success) return showAlert(result.error_message, "error");
      setSchedule(null);
      setLocalTime("");
      showAlert("Schedule cancelled.", "success");
    });

  const dismiss = () =>
    run(async () => {
      await send(Routes.dismiss_failure_link_publish_schedule_path(permalink), "POST");
      setSchedule(null);
    });

  return (
    <div className="flex flex-col gap-4 p-4 pb-0 md:p-8 md:pb-0">
      {failure ? (
        <Alert variant="danger">
          <div className="flex items-center justify-between gap-4">
            <span>Scheduled publish failed: {failure.failure_message}</span>
            <Button disabled={busy} onClick={() => void dismiss()}>
              Dismiss
            </Button>
          </div>
        </Alert>
      ) : null}
      {pending ? (
        <Alert variant="info">
          <div className="flex items-center justify-between gap-4">
            <span>Scheduled to publish on {pending.label}.</span>
            <Button disabled={busy || pending.status === "publishing"} onClick={() => void cancel()}>
              Cancel schedule
            </Button>
          </div>
        </Alert>
      ) : null}
      {canCreate && !pending ? (
        <div className="flex flex-wrap items-center gap-2">
          <label htmlFor="publish-schedule-time">Publish at</label>
          <Input
            id="publish-schedule-time"
            type="datetime-local"
            value={localTime}
            onChange={(e) => setLocalTime(e.target.value)}
          />
          <Button disabled={busy || !localTime} onClick={() => void save()}>
            Schedule publish
          </Button>
          <small>Times are in your account time zone. Publishing starts within 5 minutes of the chosen time.</small>
        </div>
      ) : null}
    </div>
  );
};
