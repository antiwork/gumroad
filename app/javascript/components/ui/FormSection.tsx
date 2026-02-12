import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const FormSection = ({
  header,
  children,
  className,
}: {
  header?: React.ReactNode;
  children?: React.ReactNode;
  className?: string;
}) => (
  <section
    className={classNames(
      "grid gap-8 border-t border-border p-4! first:border-t-0 md:p-8! lg:grid-cols-[25%_1fr] lg:gap-x-16 lg:gap-y-0",
      className,
    )}
  >
    {header ? <header className="grid content-start gap-3 lg:col-span-1">{header}</header> : null}
    <div className="grid gap-8 lg:col-start-2 lg:mb-8">{children}</div>
  </section>
);
