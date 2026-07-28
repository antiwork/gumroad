import { intervalToDuration, Duration } from "date-fns";
import * as React from "react";

import Countdown from "$app/utils/countdown";

const formatDurationComponent = (component?: number) => (component ?? 0).toString().padStart(2, "0");
const formatDuration = (duration: Duration) => {
  const { days, hours, minutes, seconds } = duration;
  let durationString = "";
  if (days) durationString += `${formatDurationComponent(days)}:`;
  if (days || hours) durationString += `${formatDurationComponent(hours)}:`;
  durationString += `${formatDurationComponent(minutes)}:${formatDurationComponent(seconds)}`;
  return durationString;
};

export const DiscountExpirationCountdown = ({
  onExpiration,
  expiresAt,
}: {
  expiresAt: Date;
  onExpiration: () => void;
}) => {
  const [secondsUntilExpiration, setSecondsUntilExpiration] = React.useState(
    (expiresAt.getTime() - new Date().getTime()) / 1000,
  );

  // Deliberately a plain useEffect rather than useRunOnce: Countdown owns a 1-second setInterval
  // that has to be aborted on unmount, and useRunOnce cannot honour a returned cleanup.
  React.useEffect(() => {
    if (secondsUntilExpiration <= 0) {
      onExpiration();
      return;
    }
    const countdown = new Countdown(secondsUntilExpiration, setSecondsUntilExpiration, onExpiration);
    return () => countdown.abort();
    // Mount-once, matching the previous useRunOnce contract: secondsUntilExpiration and
    // onExpiration are read from the first render only, so the interval is never rebuilt.
  }, []);

  // Don't render the countdown if it's greater than 7 days
  if (secondsUntilExpiration > 60 * 60 * 24 * 7) return null;

  return (
    <div>
      This discount expires in{" "}
      <strong suppressHydrationWarning>
        {formatDuration(intervalToDuration({ start: 0, end: secondsUntilExpiration * 1000 }))}
      </strong>
    </div>
  );
};
