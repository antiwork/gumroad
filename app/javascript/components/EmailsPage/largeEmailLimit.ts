import { type LargeEmailLimit } from "$app/data/installments";

// A large email sent while the day's slot is taken waits for the overnight window. The send time inside
// the window is drawn per email (so sends spread out), so the warning names the window, not one minute.
export const largeEmailLimitWarning = ({
  limit,
  recipients,
  sendAt,
  locale,
  timeZone,
}: {
  limit: LargeEmailLimit | null;
  recipients: number | null;
  sendAt: Date;
  locale?: string;
  timeZone: string;
}): string | null => {
  if (!limit?.reason || !limit.next_send_window) return null;
  if (recipients === null || recipients < limit.threshold) return null;
  // The slot is per UTC day: an email going out on another day meets a different slot.
  if (sendAt.toISOString().slice(0, 10) !== limit.date) return null;

  const start = new Date(limit.next_send_window.starts_at);
  const end = new Date(limit.next_send_window.ends_at);
  const day = start.toLocaleString(locale, { timeZone, dateStyle: "medium", timeStyle: "short" });
  const endTime = end.toLocaleTimeString(locale, { timeZone, timeStyle: "short" });
  const cause =
    limit.reason === "used"
      ? "You've already used your daily limit for large emails today."
      : "An earlier large email is still waiting for your daily limit for large emails and goes first.";

  return `${cause} This email will wait and send between ${day} and ${endTime} (${timeZone}), not right away. You can still go ahead.`;
};
