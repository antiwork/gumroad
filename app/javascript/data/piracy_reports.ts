export type PiracyReportState =
  | "requested"
  | "screening"
  | "awaiting_signature"
  | "signed"
  | "sent"
  | "counter_noticed"
  | "resolved"
  | "declined"
  | "cancelled";

export type PiracyReportOutcome = "removed" | "no_response" | "restored" | "withdrawn";

type StatusColor = "success" | "warning" | "danger" | undefined;

const OUTCOME_STATUS: Record<PiracyReportOutcome, { label: string; color: StatusColor }> = {
  removed: { label: "Page removed", color: "success" },
  no_response: { label: "No response from the site", color: undefined },
  restored: { label: "Page put back", color: "warning" },
  withdrawn: { label: "Withdrawn", color: undefined },
};

const STATE_STATUS: Record<Exclude<PiracyReportState, "resolved">, { label: string; color: StatusColor }> = {
  requested: { label: "Checking the page", color: undefined },
  screening: { label: "Checking the page", color: undefined },
  awaiting_signature: { label: "Ready for you to sign", color: "warning" },
  signed: { label: "Signed, sending soon", color: undefined },
  sent: { label: "Sent, waiting for the site", color: undefined },
  counter_noticed: { label: "Disputed", color: "danger" },
  declined: { label: "Not sent", color: undefined },
  cancelled: { label: "Closed", color: undefined },
};

// One status vocabulary for the list and the report page, in the words a seller uses.
export const piracyReportStatus = (state: PiracyReportState, outcome: PiracyReportOutcome | null) =>
  state === "resolved"
    ? outcome
      ? OUTCOME_STATUS[outcome]
      : { label: "Closed", color: undefined }
    : STATE_STATUS[state];

// UTC, so the page shows the same dates as the emails and the signature line in the notice.
export const formatPiracyReportDate = (value: string) =>
  new Date(value.length === 10 ? `${value}T00:00:00Z` : value).toLocaleDateString(undefined, {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  });
