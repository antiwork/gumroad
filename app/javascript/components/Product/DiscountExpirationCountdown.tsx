import { intervalToDuration, Duration } from "date-fns";
import * as React from "react";

import Countdown from "$app/utils/countdown";

import { useRunOnce } from "$app/components/useRunOnce";

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

  useRunOnce(() => {
    if (secondsUntilExpiration <= 0) onExpiration();
    new Countdown(secondsUntilExpiration, setSecondsUntilExpiration, onExpiration);
  });

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
