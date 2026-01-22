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
  monthly: "mỗi tháng",
  quarterly: "mỗi 3 tháng",
  biannually: "mỗi 6 tháng",
  yearly: "mỗi năm",
  every_two_years: "mỗi 2 năm",
};

export const perRecurrenceLabels: Record<RecurrenceId, string> = {
  monthly: `hàng tháng`,
  quarterly: `hàng quý`,
  biannually: `/ 6 tháng`,
  yearly: `hàng năm`,
  every_two_years: `/ 2 năm`,
};

export const formatAmountPerRecurrence = (recurrenceId: RecurrenceId, formattedAmount: string): string =>
  `${formattedAmount} ${perRecurrenceLabels[recurrenceId]}`;

export const recurrenceNames = {
  monthly: "Hàng tháng",
  quarterly: "Hàng quý",
  biannually: "Mỗi 6 tháng",
  yearly: "Hàng năm",
  every_two_years: "Mỗi 2 năm",
};

export const recurrenceDurationLabels: Record<RecurrenceId, string> = {
  monthly: `1 tháng`,
  quarterly: `3 tháng`,
  biannually: `6 tháng`,
  yearly: `1 năm`,
  every_two_years: `2 năm`,
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
