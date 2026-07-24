// Helpers for the "projected end-of-day total" overlay on the analytics sales chart.
//
// When the selected date range ends today, we extrapolate today's sales total to the
// end of the day. Preferred path: divide by the fraction of a typical day's revenue
// the seller has historically booked by this time of day (the backend computes it
// from the trailing weeks of sales). This corrects the
// systematic low bias of a uniform run rate for sellers whose buyers cluster in
// specific hours — e.g. a seller whose overnight hours produce almost nothing would
// otherwise see a projection that reads far too low until late in the day.
// Fallback path (no curve, or the curve says ~nothing should have sold yet): the
// simple run rate so far — if a seller has earned $7,200 by 6pm (75% of the day
// elapsed), the projection is $7,200 / 0.75 = $9,600.
// Either way the projection is presented as a faint overlay so it reads as an
// estimate rather than real revenue.

// Don't project during the first hour of the day: dividing by a tiny elapsed
// fraction produces wild, meaningless numbers (one $10 sale at 12:05am would
// "project" to almost $3,000).
export const MINIMUM_ELAPSED_DAY_FRACTION = 1 / 24;

// Reads the given instant's wall-clock date/time in the given time zone and re-encodes
// those components as if they were UTC. Comparing this number against the instant's real
// epoch time tells us the zone's UTC offset at that instant, which is what lets the
// midnight math below stay correct across daylight-saving transitions.
const wallClockAsUTC = (timeZone: string, date: Date): number => {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).formatToParts(date);
  const get = (type: Intl.DateTimeFormatPartTypes) => Number(parts.find((part) => part.type === type)?.value);
  return Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second"));
};

// Returns the epoch milliseconds of local midnight in the given time zone, for the
// local calendar day containing `date`, shifted by `dayOffset` days (0 = today's
// midnight, 1 = tomorrow's). Works by guessing an instant and correcting it until its
// wall-clock reading matches the target midnight — the correction loop is what handles
// days where the UTC offset changes between now and midnight (daylight-saving shifts).
const localMidnightInstant = (timeZone: string, date: Date, dayOffset: number): number => {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const get = (type: Intl.DateTimeFormatPartTypes) => Number(parts.find((part) => part.type === type)?.value);
  const targetWallClock = Date.UTC(get("year"), get("month") - 1, get("day") + dayOffset, 0, 0, 0);
  // Initial guess: the target wall-clock time adjusted by the zone's offset right now.
  let instant = targetWallClock - (wallClockAsUTC(timeZone, date) - date.getTime());
  // Refine twice: each pass corrects for any offset difference between the guessed
  // instant and the target. Two passes are enough because offsets change at most once
  // per day. (On days where midnight itself doesn't exist — some zones start
  // daylight-saving at 00:00 — this lands on the moment the clocks jump to, which is
  // the practical start of that day.)
  for (let i = 0; i < 2; i += 1) {
    instant -= wallClockAsUTC(timeZone, new Date(instant)) - targetWallClock;
  }
  return instant;
};

// Returns how much of the current calendar day has elapsed in the given IANA time
// zone, as a fraction between 0 and 1, or null if the time zone can't be resolved.
// The seller's time zone (not the viewer's) is used so "today" matches the day
// boundaries the analytics backend aggregates by. The fraction is real elapsed time
// over the day's real length — on daylight-saving transition days the day is 23 or
// 25 hours long, so local noon is not necessarily 50%.
export const fractionOfDayElapsed = (timeZone: string, now: Date = new Date()): number | null => {
  try {
    const dayStart = localMidnightInstant(timeZone, now, 0);
    const dayEnd = localMidnightInstant(timeZone, now, 1);
    if (!Number.isFinite(dayStart) || !Number.isFinite(dayEnd) || dayEnd <= dayStart) return null;
    return Math.min(Math.max((now.getTime() - dayStart) / (dayEnd - dayStart), 0), 1);
  } catch {
    return null;
  }
};

// Extrapolates today's sales total (in cents) to an end-of-day total. Returns null
// when a projection wouldn't be meaningful: no sales yet, too little of the day
// elapsed, or the day is already over.
//
// `expectedFraction` — the share of a typical day's revenue this seller has
// historically booked by now, computed by the backend from the trailing weeks of
// sales — is used as the divisor when available, weighting the projection by the
// seller's own hourly sales pattern. When it's null (thin history) or too small to
// divide by safely (a near-zero expected fraction would explode the estimate exactly
// like a tiny elapsed fraction does), we fall back to the uniform run rate. The
// MINIMUM_ELAPSED_DAY_FRACTION gate always applies to the clock fraction, keeping
// early-morning projections suppressed regardless of which divisor is used. The
// result is clamped to never fall below what's already booked.
export const projectedEndOfDayTotal = (
  totalSoFarCents: number,
  elapsedFraction: number | null,
  expectedFraction: number | null = null,
): number | null => {
  if (elapsedFraction === null || elapsedFraction < MINIMUM_ELAPSED_DAY_FRACTION || elapsedFraction >= 1) return null;
  if (totalSoFarCents <= 0) return null;
  // An expected fraction of 1 means the seller's sales for a typical day are already
  // fully booked — capping the divisor at 1 makes the projection equal today's total.
  const useExpected =
    expectedFraction !== null && Number.isFinite(expectedFraction) && expectedFraction >= MINIMUM_ELAPSED_DAY_FRACTION;
  const divisor = useExpected ? Math.min(expectedFraction, 1) : elapsedFraction;
  return Math.max(Math.round(totalSoFarCents / divisor), totalSoFarCents);
};
