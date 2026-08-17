import { usePage } from "@inertiajs/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { useDomains } from "$app/components/DomainSettings";
import { FooterCurrencySelector } from "$app/components/FooterCurrencySelector";
import { Logo } from "$app/components/Logo";

// `currencySelector` defaults off because this footer is shared by pages that show no price at all
// — invoices, follow confirmations, secure redirects, the product editor's preview. A currency
// control on those is a control that cannot do anything. Opt in from the pages that render prices.
export const PoweredByFooter = ({
  className,
  currencySelector = false,
  shownCurrency,
}: {
  className?: string | undefined;
  currencySelector?: boolean | undefined;
  shownCurrency?: string | null | undefined;
}) => {
  const { rootDomain } = useDomains();
  const detectedCurrency = usePage<{ detected_buyer_currency?: string | null }>().props.detected_buyer_currency;

  return (
    <footer
      className={classNames(
        "px-4 py-8 lg:py-16",
        currencySelector
          ? "flex flex-col items-center gap-4 text-center sm:flex-row sm:justify-between sm:text-left"
          : "text-center",
        className,
      )}
    >
      <div>
        Powered by{" "}
        <a href={Routes.root_url({ host: rootDomain })}>
          <Logo />
        </a>
      </div>
      {currencySelector ? (
        <FooterCurrencySelector detectedCurrency={detectedCurrency ?? null} shownCurrency={shownCurrency} />
      ) : null}
    </footer>
  );
};
