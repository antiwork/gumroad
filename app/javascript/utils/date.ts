export const formatDate = (date: Date) => date.toLocaleString([], { dateStyle: "long", timeStyle: "short" });

export const formatCallDate = (
  date: Date,
  displayOptions: {
    date?: { hidden?: boolean; hideYear?: boolean };
    time?: { hidden?: boolean };
    timeZone?: { hidden?: boolean; userTimeZone?: string | undefined };
  } = {},
) => {
  const localeStringOptions: Intl.DateTimeFormatOptions = {};

  if (!displayOptions.date?.hidden) {
    localeStringOptions.weekday = "long";
    localeStringOptions.month = "long";
    localeStringOptions.day = "numeric";

    if (!displayOptions.date?.hideYear) {
      localeStringOptions.year = "numeric";
    }
  }

  if (!displayOptions.time?.hidden) {
    localeStringOptions.hour = "2-digit";
    localeStringOptions.minute = "2-digit";
    localeStringOptions.hour12 = true;
  }

  if (!displayOptions.timeZone?.hidden) {
    localeStringOptions.timeZone = displayOptions.timeZone?.userTimeZone;
    localeStringOptions.timeZoneName = "short";
  }

  return date.toLocaleString("en-US", localeStringOptions);
};

export const getQuarter = (date: Date): number => {
  return Math.floor(date.getMonth() / 3) + 1;
};

export const startOfQuarter = (date: Date): Date => {
  const quarter = getQuarter(date);
  const startMonth = (quarter - 1) * 3;
  return new Date(date.getFullYear(), startMonth, 1);
};

export const endOfQuarter = (date: Date): Date => {
  const quarter = getQuarter(date);
  const endMonth = quarter * 3 - 1;
  return new Date(date.getFullYear(), endMonth + 1, 0);
};

export const subQuarters = (date: Date, quarters: number): Date => {
  const newDate = new Date(date);
  newDate.setMonth(newDate.getMonth() - quarters * 3);
  return newDate;
};
