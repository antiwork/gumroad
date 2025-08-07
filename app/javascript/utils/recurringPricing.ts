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

// Should match CurrencyHelper#recurrence_label
export const formatRecurrenceWithDuration = (recurrenceId: RecurrenceId, productDuration: null | number): string => {
  const numberOfMonths = numberOfMonthsInRecurrence(recurrenceId);
  const baseFormattedLabel = recurrenceLabels[recurrenceId];

  if (productDuration == null) {
    return baseFormattedLabel;
  }
  return `${baseFormattedLabel} x ${(productDuration / numberOfMonths).toFixed(0)}`;
};
