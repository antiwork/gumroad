import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const ProductCardGrid = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement> & { narrow?: boolean }>(
  ({ narrow, className, ...props }, ref) => (
    <div className="@container">
      <div
        ref={ref}
        className={classNames(
          "grid grid-cols-2 gap-4 @xl:grid-cols-3 @3xl:grid-cols-4 @4xl:grid-cols-5",
          // Adding !important as the order of style rules Tailwind creates means these won't necessarily be higher precedence
          !narrow && "lg:grid-cols-2! lg:@3xl:grid-cols-3! lg:@5xl:grid-cols-4! lg:@7xl:grid-cols-5!",
          className,
        )}
        {...props}
      />
    </div>
  ),
);
ProductCardGrid.displayName = "ProductCardGrid";
