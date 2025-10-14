import * as React from "react";

import { classNames } from "$app/utils/classNames";

type PlaceholderProps = React.PropsWithChildren<{
  className?: string;
  role?: string;
  "aria-label"?: string;
  style?: React.CSSProperties;
}>;

export const Placeholder: React.FC<PlaceholderProps> = ({ className, children, ...rest }) => {
  return (
    <div
      className={classNames(
        "grid gap-3 rounded border border-dashed border-border p-6 text-center justify-items-center bg-filled",
        className,
      )}
      {...rest}
    >
      {children}
    </div>
  );
};

export default Placeholder;


