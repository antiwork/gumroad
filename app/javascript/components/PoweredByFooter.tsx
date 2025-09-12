import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const PoweredByFooter = ({ className }: { className?: string }) => (
  <footer className={classNames("py-8 text-center lg:py-16", className)}>
    Powered by <span className="logo-full" />
  </footer>
);
