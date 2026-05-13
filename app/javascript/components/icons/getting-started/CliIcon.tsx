import * as React from "react";

import { GettingStartedIconProps } from "./GettingStartedIconProps";

export const CliIcon = ({ isChecked, ...props }: GettingStartedIconProps) => {
  const mainFillColor = isChecked ? "#FF90E8" : "rgb(var(--filled))";
  const strokeColor = isChecked ? "black" : "rgb(var(--primary))";
  const strokeWidthValue = "6";

  const { width = "80", height = "80", ...restProps } = props;

  return (
    <svg
      width={width}
      height={height}
      viewBox="0 0 370 370"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      {...restProps}
    >
      <rect
        x="45"
        y="65"
        width="280"
        height="240"
        rx="20"
        fill={mainFillColor}
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
      />
      <path
        d="M45 85 A20 20 0 0 1 65 65 H305 A20 20 0 0 1 325 85 V115 H45 Z"
        fill={mainFillColor}
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
      />
      <circle cx="80" cy="90" r="8" fill={strokeColor} />
      <circle cx="105" cy="90" r="8" fill={strokeColor} />
      <circle cx="130" cy="90" r="8" fill={strokeColor} />
      <path
        d="M95 170L135 200L95 230"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <line
        x1="155"
        y1="230"
        x2="220"
        y2="230"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
      />
    </svg>
  );
};
