import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";

type PlaceholderProps = {
  className?: string;
  children?: React.ReactNode;
};

export function Placeholder({ children, className }: PlaceholderProps) {
  return (
    <div
      className={classNames(
        "override placeholder grid justify-items-center gap-3 rounded border border-dashed border-[rgb(var(--parent-color)/var(--border-alpha))] bg-background p-8 text-center",
        className,
      )}
    >
      {children}
    </div>
  );
}
Placeholder.displayName = "Placeholder";

const PlaceholderIcon = ({ className, ...rest }: React.ComponentProps<typeof Icon>) => (
  <Icon {...rest} className={classNames("text-xl leading-[1.3]", className)} />
);
PlaceholderIcon.displayName = "PlaceholderIcon";

Placeholder.Icon = PlaceholderIcon;
