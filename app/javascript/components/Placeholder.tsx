import * as React from "react";

import { classNames } from "$app/utils/classNames";

type PlaceholderProps = {
  className?: string;
  children?: React.ReactNode;
};

export function Placeholder({ children, className }: PlaceholderProps) {
  const enhancedChildren = React.Children.map(children, (child) => {
    if (!React.isValidElement(child)) return child;

    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions
    const typedChild = child as React.ReactElement<{ className?: string }>;

    const existingClassName = typedChild.props.className ?? "";
    return React.cloneElement(typedChild, {
      className: classNames(existingClassName.includes("icon") ? "text-xl leading-[1.3]" : "", existingClassName),
    });
  });

  return (
    <div
      className={classNames(
        "override placeholder grid justify-items-center gap-3 rounded border border-dashed border-[rgb(var(--parent-color)/var(--border-alpha))] bg-background p-8 text-center",
        className,
      )}
    >
      {enhancedChildren}
    </div>
  );
}

Placeholder.displayName = "Placeholder";
