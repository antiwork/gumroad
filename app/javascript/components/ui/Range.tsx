import * as React from "react";

import { classNames } from "$app/utils/classNames";

declare module "react" {
  export interface CSSProperties {
    "--progress"?: number | string;
  }
}

const rangeStyles = classNames(
  "appearance-none bg-none h-[0.3125rem]",
  "[&::-webkit-slider-runnable-track]:h-[0.3125rem] [&::-webkit-slider-runnable-track]:w-full [&::-webkit-slider-runnable-track]:cursor-pointer [&::-webkit-slider-runnable-track]:rounded-[0.25rem] [&::-webkit-slider-runnable-track]:[background:var(--progress)]",
  "[&::-moz-range-track]:h-[0.3125rem] [&::-moz-range-track]:w-full [&::-moz-range-track]:cursor-pointer [&::-moz-range-track]:rounded-[0.25rem] [&::-moz-range-track]:[background:var(--progress)]",
  "[&::-webkit-slider-thumb]:appearance-none [&::-webkit-slider-thumb]:border-0 [&::-webkit-slider-thumb]:size-[1em] [&::-webkit-slider-thumb]:[background:rgb(var(--color))] [&::-webkit-slider-thumb]:rounded-full [&::-webkit-slider-thumb]:cursor-pointer [&::-webkit-slider-thumb]:[margin-top:calc(0.5*(0.3125rem-1em))]",
  "[&::-moz-range-thumb]:appearance-none [&::-moz-range-thumb]:border-0 [&::-moz-range-thumb]:size-[1em] [&::-moz-range-thumb]:[background:rgb(var(--color))] [&::-moz-range-thumb]:rounded-full [&::-moz-range-thumb]:cursor-pointer",
);

export const Range = React.forwardRef<
  HTMLInputElement,
  { progress?: number } & Omit<React.InputHTMLAttributes<HTMLInputElement>, "type">
>(({ className, progress = 0, style, ...props }, ref) => (
  <input
    ref={ref}
    type="range"
    className={classNames(rangeStyles, className)}
    style={{
      "--progress": `linear-gradient(to right, currentColor ${progress}%, rgb(var(--color) / 0.2) ${progress}%)`,
      ...style,
    }}
    {...props}
  />
));
Range.displayName = "Range";
