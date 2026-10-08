import { Link, useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import {
  formatPiracyReportDate,
  piracyReportStatus,
  PiracyReportOutcome,
  PiracyReportState,
} from "$app/data/piracy_reports";

import { Button } from "$app/components/Button";
import { Alert } from "$app/components/ui/Alert";
import { Checkbox } from "$app/components/ui/Checkbox";
import { DefinitionList } from "$app/components/ui/DefinitionList";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Pill } from "$app/components/ui/Pill";
import { useUserAgentInfo } from "$app/components/UserAgent";

type HistoryEvent =
  | "filed"
  | "confirmed"
  | "declined"
  | "signed"
  | "sent"
  | "delivered"
  | "counter_notice"
  | "resolved"
  | "closed";

type PiracyReportsShowProps = {
  report: {
    id: string;
    state: PiracyReportState;
    url: string;
    created_at: string;
    notice_text: string | null;
    notice_digest: string | null;
    signed_at: string | null;
    sent_at: string | null;
    recipient_name: string | null;
    counter_notice_received_on: string | null;
    restoration_window: [string, string] | null;
    waiting_on_person: boolean;
    outcome: PiracyReportOutcome | null;
    signed_by_name: string | null;
    history: { event: HistoryEvent; at: string }[];
  };
  product: { name: string; url: string };
  confirmations: { key: string; text: string }[];
  confirmations_version: string;
};

const OUTCOME_TEXT: Record<PiracyReportOutcome, string> = {
  removed: "The site removed the page.",
  no_response: "The site did not respond to the notice.",
  restored: "The site put the page back after the poster disputed the notice.",
  withdrawn: "This notice was withdrawn.",
};

const historyLabel = (event: HistoryEvent, report: PiracyReportsShowProps["report"]) => {
  switch (event) {
    case "filed":
      return "You reported the page";
    case "confirmed":
      return "We confirmed the page offers your work";
    case "declined":
      return "We decided not to send the notice";
    case "signed":
      return "You signed the notice";
    case "sent":
      return `We sent the notice to ${report.recipient_name ?? "the site"}`;
    case "delivered":
      return "The site received the notice";
    case "counter_notice":
      return "The person who posted the page disputed the notice";
    case "resolved":
      return report.outcome ? OUTCOME_TEXT[report.outcome] : "We closed the report";
    case "closed":
      return "We closed the report";
  }
};

const windowHasEnded = (lastDay: string) => new Date() > new Date(`${lastDay}T23:59:59Z`);

export default function PiracyReportsShow() {
  const { report, product, confirmations, confirmations_version } = usePage<PiracyReportsShowProps>().props;
  const status = piracyReportStatus(report.state, report.outcome);
  const userAgentInfo = useUserAgentInfo();
  const formatDate = (value: string) => formatPiracyReportDate(value, userAgentInfo.locale);

  const form = useForm<{ signed_by_name: string; confirmations: string[]; confirmations_version: string }>({
    signed_by_name: "",
    confirmations: [],
    confirmations_version,
  });
  const toggleConfirmation = (key: string, checked: boolean) =>
    form.setData(
      "confirmations",
      checked ? [...form.data.confirmations, key] : form.data.confirmations.filter((confirmed) => confirmed !== key),
    );
  const canSign = report.state === "awaiting_signature" && report.notice_text !== null;

  const submit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    form.post(Routes.sign_piracy_report_path(report.id));
  };

  return (
    <>
      <PageHeader
        title="Piracy report"
        showTitleOnMobile
        actions={
          <Button asChild>
            <Link href={Routes.piracy_reports_path()}>All piracy reports</Link>
          </Button>
        }
      >
        <div className="grid gap-1">
          <div className="flex flex-wrap items-center gap-2">
            <Pill size="small" color={status.color}>
              {status.label}
            </Pill>
            <strong dir="auto">{product.name}</strong>
          </div>
          <small className="break-all text-muted">Reported page: {report.url}</small>
        </div>
      </PageHeader>
      <div className="grid gap-4 p-4 md:p-8">
        {report.state === "requested" || report.state === "screening" ? (
          <Alert variant="info">
            {report.waiting_on_person
              ? "A person on our team is checking the page. This can take a few days."
              : "We are checking the page. This usually takes less than a day."}{" "}
            We will email you when the notice is ready to sign.
          </Alert>
        ) : null}
        {report.state === "awaiting_signature" ? (
          <Alert variant="info">Read the notice below. If it is correct, confirm each statement and sign it.</Alert>
        ) : null}
        {report.state === "declined" ? (
          <Alert variant="warning">
            We could not confirm that this page offers a copy of your work, so we did not send anything. If you have
            more evidence, <a href={Routes.help_center_root_path()}>contact support</a>.
          </Alert>
        ) : null}
        {report.state === "signed" ? (
          <Alert variant="info">
            Signed by {report.signed_by_name}. We will send the notice soon and email you when we do.
          </Alert>
        ) : null}
        {report.state === "sent" && report.sent_at !== null ? (
          <Alert variant="success">
            We sent the notice to {report.recipient_name ?? "the site"} on {formatDate(report.sent_at)}. You do not need
            to do anything. We will email you when the site responds.
          </Alert>
        ) : null}
        {report.state === "counter_noticed" && report.restoration_window !== null ? (
          <Alert variant="warning">
            The person who posted the page disputed the notice.{" "}
            {windowHasEnded(report.restoration_window[1]) ? (
              <>
                Since about {formatDate(report.restoration_window[1])}, the site can put the page back. If you filed a
                court action, reply to our email to tell us.
              </>
            ) : (
              <>
                The site can put the page back between about {formatDate(report.restoration_window[0])} and{" "}
                {formatDate(report.restoration_window[1])}. To stop that, file a court action against them before then,
                and reply to our email to tell us.
              </>
            )}
          </Alert>
        ) : null}
        {report.state === "resolved" && report.outcome !== null ? (
          <Alert variant={report.outcome === "removed" ? "success" : report.outcome === "restored" ? "danger" : "info"}>
            {OUTCOME_TEXT[report.outcome]}
          </Alert>
        ) : null}
        {report.state === "cancelled" ? (
          <Alert variant="warning">
            We closed this report because your account was closed, so nothing was sent. We keep the record.
          </Alert>
        ) : null}
        <Fieldset>
          <FieldsetTitle>History</FieldsetTitle>
          <DefinitionList className="gap-y-1">
            {report.history.map(({ event, at }) => (
              <React.Fragment key={event}>
                <dt className="text-muted">{formatDate(at)}</dt>
                <dd>{historyLabel(event, report)}</dd>
              </React.Fragment>
            ))}
          </DefinitionList>
        </Fieldset>
        {report.notice_text === null ? null : (
          <Fieldset>
            <FieldsetTitle id="notice-title">The notice</FieldsetTitle>
            <FieldsetDescription>
              {canSign
                ? "This is the notice we send. When you sign, we add your typed name and the date as the signature."
                : "This is the notice we send."}
            </FieldsetDescription>
            <pre
              id="notice"
              aria-labelledby="notice-title"
              className="max-h-96 overflow-auto rounded border border-border p-4 whitespace-pre-wrap"
            >
              {report.notice_text}
            </pre>
          </Fieldset>
        )}
        {canSign ? (
          <form onSubmit={submit} className="grid gap-4">
            <Fieldset>
              <FieldsetTitle>Before you sign, confirm each statement</FieldsetTitle>
              {confirmations.map(({ key, text }) => (
                <Label key={key} className="items-start">
                  <Checkbox
                    checked={form.data.confirmations.includes(key)}
                    onChange={(event) => toggleConfirmation(key, event.target.checked)}
                    required
                  />
                  {text}
                </Label>
              ))}
            </Fieldset>
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor="signed_by_name">Type your full legal name to sign</Label>
              </FieldsetTitle>
              <Input
                id="signed_by_name"
                value={form.data.signed_by_name}
                onChange={(event) => form.setData("signed_by_name", event.target.value)}
                required
              />
              {form.errors.signed_by_name ? <Alert variant="danger">{form.errors.signed_by_name}</Alert> : null}
            </Fieldset>
            <div>
              <Button type="submit" color="primary" disabled={form.processing}>
                {form.processing ? "Signing..." : "Sign notice"}
              </Button>
            </div>
          </form>
        ) : null}
      </div>
    </>
  );
}
