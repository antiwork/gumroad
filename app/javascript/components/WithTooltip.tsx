import cx from "classnames";
import * as React from "react";

export type Position = "top" | "left" | "bottom" | "right";

type Props = {
  children: React.ReactNode;
  tip: React.ReactNode | null;
  className?: string | undefined;
  position?: Position | undefined;
  fullWidth?: boolean | undefined;
};
export const WithTooltip = ({ tip, children, position, className }: Props) => {
  const id = React.useId();

  if (tip == null) return children;

  return (
    <span className={cx("has-tooltip", position, className)}>
      <span aria-describedby={id} style={{ display: "contents" }}>
        {children}
      </span>
      <span role="tooltip" id={id}>
        {tip}
      </span>
    </span>
  );
};
