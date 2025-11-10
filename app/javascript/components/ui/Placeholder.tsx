import * as React from "react";

import { classNames } from "$app/utils/classNames";

type PlaceholderProps = React.PropsWithChildren<{
  className?: string;
  role?: string;
  "aria-label"?: string;
  style?: React.CSSProperties;
}>;

const Placeholder: React.FC<PlaceholderProps> = ({ className, children, ...rest }) => (
  <div
    className={classNames(
      "grid justify-items-center gap-3 rounded border border-dashed border-border bg-background p-6 text-center",
      "[&>.icon]:text-xl",
      className,
    )}
    {...rest}
  >
    {children}
  </div>
);

export default Placeholder;
