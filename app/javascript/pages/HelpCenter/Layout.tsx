import { Search } from "@boxicons/react";
import { Link } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { ContactSupportModal, SUPPORT_EMAIL } from "$app/components/Support/ContactSupportModal";
import { PageHeader } from "$app/components/ui/PageHeader";

type HelpCenterLayoutProps = {
  children: React.ReactNode;
  showSearchButton?: boolean;
};

function HelpCenterHeader({ showSearchButton = false }: { showSearchButton?: boolean | undefined }) {
  const [contactOpen, setContactOpen] = React.useState(false);

  const renderActions = () => (
    <div className="flex gap-2">
      {showSearchButton ? (
        <Button asChild>
          <Link href={Routes.help_center_root_path()} aria-label="Search" title="Search">
            <Search className="size-5" />
          </Link>
        </Button>
      ) : (
        <Button asChild>
          <a href={`mailto:${SUPPORT_EMAIL}`}>Email support</a>
        </Button>
      )}
      <Button color="accent" onClick={() => setContactOpen(true)}>
        Contact support
      </Button>
    </div>
  );

  return (
    <>
      <PageHeader title="Help Center" actions={renderActions()} />
      <ContactSupportModal open={contactOpen} onClose={() => setContactOpen(false)} />
    </>
  );
}

export function HelpCenterLayout({ children, showSearchButton }: HelpCenterLayoutProps) {
  return (
    <>
      <HelpCenterHeader showSearchButton={showSearchButton} />
      <section className="p-4 md:p-8">{children}</section>
    </>
  );
}
