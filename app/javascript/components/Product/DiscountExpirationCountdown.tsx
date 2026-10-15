import { intervalToDuration, Duration } from "date-fns";
import * as React from "react";

import Countdown from "$app/utils/countdown";
import { formatDate } from "$app/utils/date";

const MAX_COUNTDOWN_SECONDS = 60 * 60 * 24 * 7;

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
  showEndDate = false,
}: {
  expiresAt: Date;
  onExpiration: () => void;
  showEndDate?: boolean;
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

  if (secondsUntilExpiration > MAX_COUNTDOWN_SECONDS) {
    return showEndDate ? (
      <div>
        This sale ends on{" "}
        <time dateTime={expiresAt.toISOString()} suppressHydrationWarning>
          {formatDate(expiresAt)}
        </time>
        .
      </div>
    ) : null;
  }

  return (
    <div>
      This discount expires in{" "}
      <strong suppressHydrationWarning>
        {formatDuration(intervalToDuration({ start: 0, end: secondsUntilExpiration * 1000 }))}
      </strong>
    </div>
  );
};
