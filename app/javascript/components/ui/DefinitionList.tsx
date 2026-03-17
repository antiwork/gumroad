import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const DefinitionList = React.forwardRef<HTMLDListElement, React.HTMLAttributes<HTMLDListElement>>(
  ({ className, ...props }, ref) => (
    <dl
      ref={ref}
      className={classNames(
        "grid grid-cols-[fit-content(40%)] gap-x-3 [&>dd]:col-start-2 [&>dt]:col-start-1 [&>dt]:after:content-[':']",
        className,
      )}
      {...props}
    />
  ),
);
DefinitionList.displayName = "DefinitionList";
