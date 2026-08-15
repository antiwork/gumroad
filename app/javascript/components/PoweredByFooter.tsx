import { usePage } from "@inertiajs/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { useDomains } from "$app/components/DomainSettings";
import { FooterCurrencySelector } from "$app/components/FooterCurrencySelector";
import { Logo } from "$app/components/Logo";

export const PoweredByFooter = ({ className }: { className?: string }) => {
  const { rootDomain } = useDomains();
  const detectedCurrency = usePage<{ detected_buyer_currency?: string | null }>().props.detected_buyer_currency;

  return (
    <footer className={classNames("flex flex-wrap items-center justify-between gap-4 px-4 py-8 lg:py-16", className)}>
      <div>
        Powered by{" "}
        <a href={Routes.root_url({ host: rootDomain })}>
          <Logo />
        </a>
      </div>
      <FooterCurrencySelector detectedCurrency={detectedCurrency} />
    </footer>
  );
};
