import * as React from "react";

import { classNames } from "$app/utils/classNames";

type PlaceholderProps = React.PropsWithChildren<{
  className?: string;
  role?: string;
  "aria-label"?: string;
  style?: React.CSSProperties;
  noBackground?: boolean;
}>;

const Placeholder: React.FC<PlaceholderProps> = ({ className, children, noBackground, ...rest }) => (
  <div
    className={classNames(
      "grid justify-items-center gap-3 rounded border border-dashed border-border p-6 text-center",
      !noBackground && "bg-filled",
      "[&>.icon]:text-xl",
      className,
    )}
    {...rest}
  >
    {children}
  </div>
);

export default Placeholder;
