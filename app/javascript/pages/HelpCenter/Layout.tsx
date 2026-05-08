import { Search } from "@boxicons/react";
import { Link } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { PageHeader } from "$app/components/ui/PageHeader";

const SUPPORT_EMAIL = "mailto:support@gumroad.com";

type HelpCenterLayoutProps = {
  children: React.ReactNode;
  showSearchButton?: boolean;
};

function HelpCenterHeader({ showSearchButton = false }: { showSearchButton?: boolean | undefined }) {
  const renderActions = () => {
    if (showSearchButton) {
      return (
        <Button asChild>
          <Link href={Routes.help_center_root_path()} aria-label="Search" title="Search">
            <Search className="size-5" />
          </Link>
        </Button>
      );
    }

    return (
      <Button color="accent" asChild>
        <a href={SUPPORT_EMAIL}>Email support</a>
      </Button>
    );
  };

  return <PageHeader title="Help Center" actions={renderActions()} />;
}

export function HelpCenterLayout({ children, showSearchButton }: HelpCenterLayoutProps) {
  return (
    <>
      <HelpCenterHeader showSearchButton={showSearchButton} />
      <section className="p-4 md:p-8">{children}</section>
    </>
  );
}
