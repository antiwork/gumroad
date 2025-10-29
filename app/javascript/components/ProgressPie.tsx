import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";

export const ProgressPie = ({
  progress,
  className,
  ...props
}: { progress: number } & React.HTMLAttributes<HTMLDivElement>) => {
  const radius = 0.5;
  const angle = -Math.PI / 2 + 2 * Math.PI * progress;
  const arcEndX = radius * (1 + Math.cos(angle));
  const arcEndY = radius * (1 + Math.sin(angle));
  const pathString = `
  M ${radius} ${radius}
  V 0
  A ${radius} ${radius} 0 ${progress > 0.5 ? 1 : 0} 1 ${arcEndX} ${arcEndY}
  Z`;
  return (
    <div
      className={classNames("rounded-full border border-border", className)}
      role="progressbar"
      aria-valuenow={Math.round(progress * 10000) / 100}
      {...props}
    >
      {progress === 1 ? (
        <div className="rounded-full bg-accent p-1 text-2xl/none text-accent-foreground">
          <Icon name="outline-check" />
        </div>
      ) : (
        <svg viewBox="0 0 1 1" className="w-8">
          <path className="fill-accent" d={pathString} />
        </svg>
      )}
    </div>
  );
};
