import { Link, router, useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import {
  formatPiracyReportDate,
  withoutProtocol,
  piracyReportStatus,
  restorationDeadline,
  PiracyReportOutcome,
  PiracyReportState,
} from "$app/data/piracy_reports";
import { classNames } from "$app/utils/classNames";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { Checkbox } from "$app/components/ui/Checkbox";
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
    can_cancel: boolean;
    history: { event: HistoryEvent; at: string }[];
  };
  product: { name: string; url: string };
  confirmations: { key: string; text: string }[];
  confirmations_version: string;
};

const OUTCOME_TEXT: Record<PiracyReportOutcome, string> = {
  removed: "The site removed the page.",
  no_response: "The site did not respond to the notice.",
  restored: "The site put the page back after the person who posted it disputed the notice.",
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
      return "The report was cancelled";
  }
};

export default function PiracyReportsShow() {
  const { report, product, confirmations, confirmations_version } = usePage<PiracyReportsShowProps>().props;
  const status = piracyReportStatus(report.state, report.outcome);
  const userAgentInfo = useUserAgentInfo();
  const formatDate = (value: string) => formatPiracyReportDate(value, userAgentInfo.locale);
  const [confirmingCancel, setConfirmingCancel] = React.useState(false);
  const [cancelling, setCancelling] = React.useState(false);
  const cancelReport = () =>
    router.post(
      Routes.cancel_piracy_report_path(report.id),
      {},
      {
        onStart: () => setCancelling(true),
        onFinish: () => {
          setCancelling(false);
          setConfirmingCancel(false);
        },
      },
    );

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

  const deadline = report.restoration_window ? restorationDeadline(report.restoration_window, new Date()) : null;
  const statusAlert =
    report.state === "requested" || report.state === "screening" ? (
      <Alert role="status" variant="info">
        {report.waiting_on_person
          ? "A person on our team is checking the page. This can take a few days."
          : "We are checking the page. This usually takes less than a day."}{" "}
        We will email you when the notice is ready to sign.
      </Alert>
    ) : report.state === "declined" ? (
      <Alert role="status" variant="warning">
        We could not confirm that this page offers a copy of your work, so we did not send anything. If you have more
        evidence, <a href={Routes.help_center_root_path()}>contact support</a>.
      </Alert>
    ) : report.state === "signed" ? (
      <Alert role="status" variant="info">
        Signed by {report.signed_by_name}. We will send the notice soon and email you when we do.
      </Alert>
    ) : report.state === "sent" && report.sent_at !== null ? (
      <Alert role="status" variant="success">
        We sent the notice to {report.recipient_name ?? "the site"} on {formatDate(report.sent_at)}. You do not need to
        do anything. We will email you when the site responds.
      </Alert>
    ) : report.state === "counter_noticed" && report.restoration_window !== null && deadline !== null ? (
      <Alert role="status" variant="warning">
        {deadline.passed ? (
          <>
            Since about {formatDate(deadline.day)}, the site can put the page back. If you filed a court action, reply
            to our email to tell us.
          </>
        ) : (
          <>
            The site can put the page back between about {formatDate(report.restoration_window[0])} and{" "}
            {formatDate(report.restoration_window[1])}. To stop that, file a court action against the person who posted
            the page before {formatDate(deadline.day)}, and reply to our email to tell us.
          </>
        )}
      </Alert>
    ) : report.state === "resolved" && report.outcome !== null ? (
      <Alert
        role="status"
        variant={report.outcome === "removed" ? "success" : report.outcome === "restored" ? "danger" : "info"}
      >
        {OUTCOME_TEXT[report.outcome]}
      </Alert>
    ) : report.state === "cancelled" ? (
      <Alert role="status" variant="info">
        This report was cancelled before it was sent. Nothing was sent.
      </Alert>
    ) : null;

  return (
    <div>
      <PageHeader
        showTitleOnMobile
        title={
          <div className="flex flex-wrap items-center gap-2">
            <Link href={Routes.piracy_reports_path()} aria-label="Back to piracy reports" className="mr-4 no-underline">
              ←
            </Link>
            <span dir="auto">{product.name}</span>
            <Pill size="small" color={status.color}>
              {status.label}
            </Pill>
          </div>
        }
      />
      <div className="flex flex-col gap-8 p-4 md:p-8">
        <p>
          Reported page:{" "}
          <a href={report.url} target="_blank" rel="noreferrer nofollow" className="break-all">
            {withoutProtocol(report.url)}
          </a>
        </p>
        {statusAlert}
        {report.can_cancel ? (
          <div>
            <Button onClick={() => setConfirmingCancel(true)}>Cancel report</Button>
          </div>
        ) : null}
        <div className={classNames("grid items-start gap-8", report.notice_text !== null && "lg:grid-cols-2")}>
          {report.notice_text === null ? null : (
            <div className="flex flex-col gap-8">
              <Card asChild>
                <section>
                  <CardContent asChild>
                    <header>
                      <h3 id="notice-title" className="grow">
                        Notice
                      </h3>
                    </header>
                  </CardContent>
                  <CardContent details>
                    <pre id="notice" aria-labelledby="notice-title" className="font-[inherit] whitespace-pre-wrap">
                      {report.notice_text}
                    </pre>
                  </CardContent>
                </section>
              </Card>
              {canSign ? (
                <Card asChild>
                  <form onSubmit={submit}>
                    <CardContent asChild>
                      <header>
                        <h3 className="grow">Sign the notice</h3>
                      </header>
                    </CardContent>
                    <CardContent details>
                      <Fieldset>
                        <FieldsetTitle>Confirm each statement</FieldsetTitle>
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
                    </CardContent>
                    <CardContent details>
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
                        <FieldsetDescription>
                          We add your typed name and the date to the notice as your signature.
                        </FieldsetDescription>
                        {form.errors.signed_by_name ? (
                          <Alert variant="danger">{form.errors.signed_by_name}</Alert>
                        ) : null}
                      </Fieldset>
                    </CardContent>
                    <CardContent>
                      <Button type="submit" color="primary" disabled={form.processing}>
                        {form.processing ? "Signing..." : "Sign notice"}
                      </Button>
                    </CardContent>
                  </form>
                </Card>
              ) : null}
            </div>
          )}
          <Card asChild>
            <section>
              <CardContent asChild>
                <header>
                  <h3 className="grow">History</h3>
                </header>
              </CardContent>
              {report.history.map(({ event, at }) => (
                <CardContent asChild key={event}>
                  <section>
                    <div className="grow">
                      <h5>{historyLabel(event, report)}</h5>
                      <small className="block text-muted">{formatDate(at)}</small>
                    </div>
                  </section>
                </CardContent>
              ))}
            </section>
          </Card>
        </div>
      </div>
      {confirmingCancel ? (
        <Modal
          open
          onClose={() => setConfirmingCancel(false)}
          title="Cancel this report?"
          footer={
            <>
              <Button onClick={() => setConfirmingCancel(false)} disabled={cancelling}>
                Keep report
              </Button>
              <Button color="danger" onClick={cancelReport} disabled={cancelling}>
                {cancelling ? "Cancelling..." : "Cancel report"}
              </Button>
            </>
          }
        >
          <p>
            We will not send the notice. You cannot undo this, and the report still counts toward your monthly limit.
          </p>
        </Modal>
      ) : null}
    </div>
  );
}
