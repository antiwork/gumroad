import * as React from "react";

import { classNames } from "$app/utils/classNames";

type PillColor = "success" | "danger" | "warning" | "info" | "primary" | "black" | "accent" | "filled";
type PillKind = "dismissable" | "expandable" | undefined;
type PillSize = "default" | "small";

type PillProps = React.PropsWithChildren<{
  className?: string | undefined;
  as?: "div" | "span" | "button"| React.ElementType;
  color?: PillColor;
  size?: PillSize;
  kind?: PillKind;
  select?: boolean;
}> & React.HTMLAttributes<HTMLElement>;

export const Pill = React.forwardRef<HTMLElement, PillProps>(
  (
    { className, as: Component = "div", color, size = "default", kind, select = false, children, ...rest },
    ref
  ) => {
    const baseClasses = "inline-block align-middle px-3 py-2 bg-background text-foreground border border-border rounded-[10rem] truncate pill-component";
    const sizeClass = size === "small" ? "rounded p-1 text-sm" : "";
    const colorClasses = color==="primary"?"border bg-primary text-primary-foreground border-primary":"";
    const selectClass = select ? "relative cursor-pointer before:float-right before:ml-2 before:content-['\\00a0'] before:inline-block before:bg-current before:min-h-[max(1lh,1em)] before:w-[1em] before:[mask-position:50%_50%] before:[mask-size:120%] before:[mask-repeat:no-repeat] before:shrink-0 after:content-['\\00a0'] before:mask-(--icon-cheveron-down)" : "";
    const kindClasses = kind ==="dismissable"?"cursor-pointer before:float-right before:ml-2 before:content-['\\00a0'] before:inline-block before:bg-current before:min-h-[max(1lh,1em)] before:w-[1em] before:[mask-position:50%_50%] before:[mask-size:120%] before:[mask-repeat:no-repeat] before:shrink-0 after:content-['\\00a0'] before:mask-(--icon-x)" : "";

    return (
      <Component
        ref={ref as any}
        className={classNames(baseClasses,colorClasses, sizeClass, selectClass,kindClasses, className)}
        {...rest}
      >
        {children}
      </Component>
    );
  }
);

Pill.displayName = "Pill";


