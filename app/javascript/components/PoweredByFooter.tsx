import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { useDomains } from "$app/components/DomainSettings";

export const PoweredByFooter = ({ className }: { className?: string }) => {
  const { rootDomain } = useDomains();

  return (
    <footer className={classNames("px-4 py-8 text-center lg:py-16", className)}>
      <div>
        Powered by <a href={Routes.root_url({ host: rootDomain })} className="logo-full" aria-label="Gumroad" />
      </div>
    </footer>
  );
};
