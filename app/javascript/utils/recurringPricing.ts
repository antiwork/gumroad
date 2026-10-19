// Should match BasePrice::Recurrence::ALLOWED_RECURRENCES
export const recurrenceIds = ["monthly", "quarterly", "biannually", "yearly", "every_two_years"] as const;
export const durationInMonthsToRecurrenceId: Record<number, RecurrenceId> = {
  1: "monthly",
  3: "quarterly",
  6: "biannually",
  12: "yearly",
  24: "every_two_years",
};
export type RecurrenceId = "biannually" | "every_two_years" | "monthly" | "quarterly" | "yearly";

// Keep in sync with BasePrice::Recurrence.number_of_months_in_recurrence
const recurrencesToMonths: Record<RecurrenceId, number> = {
  monthly: 1,
  quarterly: 3,
  biannually: 6,
  yearly: 12,
  every_two_years: 24,
};
export const numberOfMonthsInRecurrence = (recurrenceId: RecurrenceId): number => recurrencesToMonths[recurrenceId];

export const recurrenceLabels: Record<RecurrenceId, string> = {
  monthly: "a month",
  quarterly: "every 3 months",
  biannually: "every 6 months",
  yearly: "a year",
  every_two_years: "every 2 years",
};

export const perRecurrenceLabels: Record<RecurrenceId, string> = {
  monthly: `monthly`,
  quarterly: `quarterly`,
  biannually: `/ 6 months`,
  yearly: `yearly`,
  every_two_years: `/ 2 years`,
};

export const formatAmountPerRecurrence = (recurrenceId: RecurrenceId, formattedAmount: string): string =>
  `${formattedAmount} ${perRecurrenceLabels[recurrenceId]}`;

export const recurrenceNames = {
  monthly: "Monthly",
  quarterly: "Quarterly",
  biannually: "Every 6 months",
  yearly: "Yearly",
  every_two_years: "Every 2 years",
};

export const recurrenceDurationLabels: Record<RecurrenceId, string> = {
  monthly: `1 month`,
  quarterly: `3 months`,
  biannually: `6 months`,
  yearly: `1 year`,
  every_two_years: `2 years`,
};

// A membership whose fixed duration equals a single recurrence period (e.g. a
// 12-month membership billed yearly) only ever charges the buyer once, so
// recurring wording like "Yearly" or "a year" reads as an auto-renewing charge.
// Keep in sync with BasePrice::Recurrence.single_charge_duration?
export const isSingleChargeDuration = (recurrenceId: RecurrenceId, durationInMonths: null | number): boolean =>
  durationInMonths === numberOfMonthsInRecurrence(recurrenceId);

// Should match CurrencyHelper#recurrence_label
export const formatRecurrenceWithDuration = (recurrenceId: RecurrenceId, productDuration: null | number): string => {
  const numberOfMonths = numberOfMonthsInRecurrence(recurrenceId);
  const baseFormattedLabel = recurrenceLabels[recurrenceId];

  if (productDuration == null) {
    return baseFormattedLabel;
  }
  if (isSingleChargeDuration(recurrenceId, productDuration)) {
    return "once";
  }
  return `${baseFormattedLabel} x ${(productDuration / numberOfMonths).toFixed(0)}`;
};

const formatDays = (days: number) => `${days} ${days === 1 ? "day" : "days"}`;

// Lead times come from BasePrice::Recurrence via `recurrences.enabled[].renewal_reminder_days`. A free trial's
// first charge gets only the trial-ending email (`free_trial_reminder_days`). The trial is conditional because a
// line that restarts a lapsed membership is charged at once with no trial, and the cart can't tell before checkout.
export const renewalReminderNotice = (
  recurrences: {
    enabled: { recurrence: RecurrenceId; renewal_reminder_days?: number[] }[];
    free_trial_reminder_days?: number | null;
  } | null,
  recurrence: RecurrenceId | null,
  { freeTrial = false }: { freeTrial?: boolean } = {},
): string | null => {
  const days = recurrences?.enabled.find((price) => price.recurrence === recurrence)?.renewal_reminder_days;
  if (!days || days.length === 0) return null;
  const leadTimes = days.map(formatDays).join(" and ");
  if (!freeTrial) return `We'll email you a reminder ${leadTimes} before each renewal.`;

  const trialDays = recurrences.free_trial_reminder_days;
  if (!trialDays) return null;
  return `If this purchase starts your free trial, we'll email you a reminder ${formatDays(trialDays)} before it ends. We'll also email you ${leadTimes} before each renewal after your first payment.`;
};
