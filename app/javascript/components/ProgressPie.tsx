import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";

declare module "react" {
  export interface CSSProperties {
    "--progress"?: number | string;
  }
}

export const ProgressPie = ({
  progress,
  className,
  ...props
}: { progress: number } & React.HTMLAttributes<HTMLDivElement>) => {
  const radius = 0.5;
  const angle = -Math.PI / 2 + 2 * Math.PI * progress;
  const arcEndX = radius + radius * Math.cos(angle);
  const arcEndY = radius + radius * Math.sin(angle);
  const pathString = `
  M ${radius} ${radius}
  V 0
  A ${radius} ${radius} 0 ${progress > 0.5 ? 1 : 0} 1 ${arcEndX} ${arcEndY}
  Z`;
  return (
    <div className={classNames("w-8 rounded-full border", className)} {...props}>
      {progress === 1 ? (
        <div className="rounded-full bg-accent p-1 text-center">
          <Icon name="outline-check" />
        </div>
      ) : (
        <svg viewBox="0 0 1 1">
          <path className="fill-accent" d={pathString} />
        </svg>
      )}
    </div>
  );
};
