import { HelperClientProvider } from "@helperai/react";
import { Link, router, usePage } from "@inertiajs/react";
import * as React from "react";

import { Button, NavigationButton } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { GitHubIcon } from "$app/components/icons/GitHubIcon";
import { NewTicketModal } from "$app/components/support/NewTicketModal";
import { UnauthenticatedNewTicketModal } from "$app/components/support/UnauthenticatedNewTicketModal";
import { UnreadTicketsBadge } from "$app/components/support/UnreadTicketsBadge";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tab, Tabs } from "$app/components/ui/Tabs";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

type SharedProps = {
  helper_widget_host?: string | null;
  helper_session?: {
    email?: string | null;
    emailHash?: string | null;
    timestamp?: number | null;
  } | null;
  recaptcha_site_key?: string | null;
};

type HelpCenterLayoutProps = {
  children: React.ReactNode;
  showSearchButton?: boolean;
};

function HelpCenterHeader({
  hasHelperSession,
  recaptchaSiteKey,
  showSearchButton = false,
  onOpenNewTicket,
}: {
  hasHelperSession: boolean;
  recaptchaSiteKey: string | null;
  showSearchButton?: boolean | undefined;
  onOpenNewTicket: () => void;
}) {
  const { pathname, searchParams } = new URL(useOriginalLocation());
  const isHelpCenterHome = pathname === Routes.help_center_root_path();
  const isAnonymousUserOnHelpCenter = !hasHelperSession && isHelpCenterHome;

  const [isUnauthenticatedNewTicketOpen, setIsUnauthenticatedNewTicketOpen] = React.useState(
    isAnonymousUserOnHelpCenter && !!searchParams.get("new_ticket"),
  );

  React.useEffect(() => {
    const url = new URL(location.href);
    if (!url.searchParams.get("new_ticket")) return;

    if (isAnonymousUserOnHelpCenter && !isUnauthenticatedNewTicketOpen) {
      url.searchParams.delete("new_ticket");
      history.replaceState(null, "", url.toString());
    } else if (hasHelperSession && isHelpCenterHome) {
      onOpenNewTicket();
      url.searchParams.delete("new_ticket");
      history.replaceState(null, "", url.toString());
    }
  }, [
    isUnauthenticatedNewTicketOpen,
    isAnonymousUserOnHelpCenter,
    hasHelperSession,
    isHelpCenterHome,
    onOpenNewTicket,
  ]);

  const renderActions = () => {
    if (showSearchButton) {
      return (
        <Link href={Routes.help_center_root_path()} className="button" aria-label="Search" title="Search">
          <Icon name="solid-search" />
        </Link>
      );
    }

    if (isAnonymousUserOnHelpCenter) {
      return (
        <>
          <NavigationButton
            color="accent"
            outline
            href="https://github.com/antiwork/gumroad/issues/new"
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center gap-2"
          >
            <GitHubIcon />
            Report a bug
          </NavigationButton>
          <Button color="accent" onClick={() => setIsUnauthenticatedNewTicketOpen(true)}>
            Contact support
          </Button>
        </>
      );
    }

    if (hasHelperSession) {
      return (
        <>
          <NavigationButton
            color="accent"
            outline
            href="https://github.com/antiwork/gumroad/issues/new"
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center gap-2"
          >
            <GitHubIcon />
            Report a bug
          </NavigationButton>
          <Button color="accent" onClick={onOpenNewTicket}>
            New ticket
          </Button>
        </>
      );
    }

    return null;
  };

  return (
    <>
      <PageHeader title="Help Center" actions={renderActions()}>
        {hasHelperSession ? (
          <Tabs>
            <Tab asChild isSelected>
              <Link href={Routes.help_center_root_path()}>Articles</Link>
            </Tab>
            <Tab href={Routes.support_index_path()} isSelected={false} className="flex items-center gap-2">
              Support tickets
              <UnreadTicketsBadge />
            </Tab>
          </Tabs>
        ) : null}
      </PageHeader>
      {isAnonymousUserOnHelpCenter ? (
        <UnauthenticatedNewTicketModal
          open={isUnauthenticatedNewTicketOpen}
          onClose={() => setIsUnauthenticatedNewTicketOpen(false)}
          onCreated={() => setIsUnauthenticatedNewTicketOpen(false)}
          recaptchaSiteKey={recaptchaSiteKey}
        />
      ) : null}
    </>
  );
}

function AuthenticatedHelpCenterContent({
  children,
  showSearchButton,
  recaptchaSiteKey,
}: {
  children: React.ReactNode;
  showSearchButton?: boolean | undefined;
  recaptchaSiteKey: string | null;
}) {
  const { pathname, searchParams } = new URL(useOriginalLocation());
  const isHelpCenterHome = pathname === Routes.help_center_root_path();
  const [isNewTicketOpen, setIsNewTicketOpen] = React.useState(isHelpCenterHome && !!searchParams.get("new_ticket"));

  const handleTicketCreated = (_slug: string) => {
    setIsNewTicketOpen(false);
    router.visit(Routes.support_index_path());
  };

  return (
    <>
      <HelpCenterHeader
        hasHelperSession
        recaptchaSiteKey={recaptchaSiteKey}
        showSearchButton={showSearchButton}
        onOpenNewTicket={() => setIsNewTicketOpen(true)}
      />
      <section className="p-4 md:p-8">{children}</section>
      <NewTicketModal
        open={isNewTicketOpen}
        onClose={() => setIsNewTicketOpen(false)}
        onCreated={handleTicketCreated}
      />
    </>
  );
}

export function HelpCenterLayout({ children, showSearchButton }: HelpCenterLayoutProps) {
  const { helper_widget_host, helper_session, recaptcha_site_key } = usePage<SharedProps>().props;

  const hasHelperSession = !!(helper_widget_host && helper_session);

  if (hasHelperSession) {
    return (
      <HelperClientProvider host={helper_widget_host} session={helper_session}>
        <AuthenticatedHelpCenterContent
          showSearchButton={showSearchButton}
          recaptchaSiteKey={recaptcha_site_key ?? null}
        >
          {children}
        </AuthenticatedHelpCenterContent>
      </HelperClientProvider>
    );
  }

  return (
    <>
      <HelpCenterHeader
        hasHelperSession={false}
        recaptchaSiteKey={recaptcha_site_key ?? null}
        showSearchButton={showSearchButton}
        onOpenNewTicket={() => {}}
      />
      <section className="p-4 md:p-8">{children}</section>
    </>
  );
}
