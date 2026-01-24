import { parseISO } from "date-fns";

const dateFormatOptions: Intl.DateTimeFormatOptions = { month: "long", day: "numeric", year: "numeric" };

export const formatPostDate = (date: string | null, locale: string): string =>
  (date ? parseISO(date) : new Date()).toLocaleDateString(locale, dateFormatOptions);
