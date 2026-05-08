import { Search } from "@boxicons/react";
import { HelperClientProvider } from "@helperai/react";
import { Link, usePage } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { PageHeader } from "$app/components/ui/PageHeader";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

const SUPPORT_EMAIL = "mailto:support@gumroad.com";

type HelperSession = {
  email?: string | null;
  emailHash?: string | null;
  timestamp?: number | null;
};

type HelpCenterSharedProps = {
  helper_widget_host?: string | null;
  helper_session?: HelperSession | null;
};

type HelpCenterLayoutProps = {
  children: React.ReactNode;
  showSearchButton?: boolean;
};

function HelpCenterHeader({
  showSearchButton = false,
}: {
  showSearchButton?: boolean | undefined;
}) {
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
  const { helper_widget_host, helper_session } = usePage<HelpCenterSharedProps>().props;

  const hasHelperSession = !!(helper_widget_host && helper_session);

  if (hasHelperSession) {
    return (
      <HelperClientProvider host={helper_widget_host} session={helper_session}>
        <HelpCenterHeader showSearchButton={showSearchButton} />
        <section className="p-4 md:p-8">{children}</section>
      </HelperClientProvider>
    );
  }

  return (
    <>
      <HelpCenterHeader showSearchButton={showSearchButton} />
      <section className="p-4 md:p-8">{children}</section>
    </>
  );
}
