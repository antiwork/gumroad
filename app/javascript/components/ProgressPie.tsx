import cx from "classnames";
import * as React from "react";

import { Progress } from "$app/components/Progress";

export const ProgressPie = ({ progress, className }: { progress: number; className?: string }) => {
  const radius = 0.5;
  const strokeWidth = 0.03;
  const innerRadius = radius - strokeWidth;
  const angle = -Math.PI / 2 + 2 * Math.PI * progress;
  const arcEndX = radius + innerRadius * Math.cos(angle);
  const arcEndY = radius + innerRadius * Math.sin(angle);
  const pathString = `
  M ${radius} ${radius}
  V ${strokeWidth}
  A ${innerRadius} ${innerRadius} 0 ${progress > 0.5 ? 1 : 0} 1 ${arcEndX} ${arcEndY}
  Z`;
  return (
    <>
      {progress === 1 ? (
        <span className={cx("progress-pie", "progress-pie--completed", "legacy-only", className)}>
          <i className="icn-check" />
        </span>
      ) : (
        <svg className={cx("progress-pie", "progress-pie--incomplete", "legacy-only", className)} viewBox="0 0 1 1">
          <circle
            className="progress-pie--incomplete__background"
            cx={radius}
            cy={radius}
            r={radius - strokeWidth / 2}
            strokeWidth={strokeWidth}
          />
          <path className="progress-pie--incomplete__pie" d={pathString} />
        </svg>
      )}
      <Progress progress={progress} width="2em" />
    </>
  );
};
