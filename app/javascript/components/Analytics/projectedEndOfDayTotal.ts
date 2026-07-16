// Helpers for the "projected end-of-day total" overlay on the analytics sales chart.
//
// When the selected date range ends today, we extrapolate today's sales total to the
// end of the day using the simple run rate so far: if a seller has earned $7,200 by
// 6pm (75% of the day elapsed), the projection is $7,200 / 0.75 = $9,600.
// The projection is intentionally naive — no hourly seasonality — and is presented
// as a lighter, dashed overlay so it reads as an estimate rather than real revenue.

// Don't project during the first hour of the day: dividing by a tiny elapsed
// fraction produces wild, meaningless numbers (one $10 sale at 12:05am would
// "project" to almost $3,000).
export const MINIMUM_ELAPSED_DAY_FRACTION = 1 / 24;

// Returns how much of the current calendar day has elapsed in the given IANA time
// zone, as a fraction between 0 and 1, or null if the time zone can't be resolved.
// The seller's time zone (not the viewer's) is used so "today" matches the day
// boundaries the analytics backend aggregates by.
export const fractionOfDayElapsed = (timeZone: string, now: Date = new Date()): number | null => {
  try {
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      hour: "2-digit",
      minute: "2-digit",
    }).formatToParts(now);
    const hour = Number(parts.find((part) => part.type === "hour")?.value);
    const minute = Number(parts.find((part) => part.type === "minute")?.value);
    if (Number.isNaN(hour) || Number.isNaN(minute)) return null;
    return (hour * 60 + minute) / (24 * 60);
  } catch {
    return null;
  }
};

// Extrapolates today's sales total (in cents) to an end-of-day total using the run
// rate so far. Returns null when a projection wouldn't be meaningful: no sales yet,
// too little of the day elapsed, or the day is already over.
export const projectedEndOfDayTotal = (totalSoFarCents: number, elapsedFraction: number | null): number | null => {
  if (elapsedFraction === null || elapsedFraction < MINIMUM_ELAPSED_DAY_FRACTION || elapsedFraction >= 1) return null;
  if (totalSoFarCents <= 0) return null;
  return Math.round(totalSoFarCents / elapsedFraction);
};
